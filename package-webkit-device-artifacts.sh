#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEFAULT_SOURCE_DIR="${SCRIPT_DIR}/WebKitBuild/Debug-iphoneos"
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"
OUTPUT_TAR=""
PUSH_TO_DEVICE=0
SSH_TARGET="iproxy"
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
REMOTE_DIR="/var/root"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--source <Debug-iphoneos-dir>] [--output <tar.gz-path>] [--push-device]
          [--ssh-target <ssh-config-host>] [--ssh-host <host>] [--ssh-port <port>]
          [--ssh-user <user>] [--remote-dir <dir>]

Default source:
  ${DEFAULT_SOURCE_DIR}

Default SSH (iproxy style):
  --ssh-target ${SSH_TARGET}
  --remote-dir ${REMOTE_DIR}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SOURCE_DIR="${2:?missing value for --source}"
            shift 2
            ;;
        --output)
            OUTPUT_TAR="${2:?missing value for --output}"
            shift 2
            ;;
        --push-device)
            PUSH_TO_DEVICE=1
            shift
            ;;
        --ssh-target)
            SSH_TARGET="${2:?missing value for --ssh-target}"
            shift 2
            ;;
        --ssh-host)
            SSH_HOST="${2:?missing value for --ssh-host}"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="${2:?missing value for --ssh-port}"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="${2:?missing value for --ssh-user}"
            shift 2
            ;;
        --remote-dir)
            REMOTE_DIR="${2:?missing value for --remote-dir}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "Source directory does not exist: ${SOURCE_DIR}" >&2
    exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUTPUT_TAR}" ]]; then
    OUTPUT_TAR="${SCRIPT_DIR}/webkit-device-package-${timestamp}.tar.gz"
fi

WORK_BASE_DIR="$(cd "$(dirname "${SOURCE_DIR}")" && pwd)"
WORK_DIR="$(mktemp -d "${WORK_BASE_DIR}/.webkit-device-package.XXXXXX")"
SOURCE_COPY_DIR="${WORK_DIR}/source-copy"
PACKAGE_STAGE_DIR="${WORK_DIR}/package-stage"
PAYLOAD_DIR="${PACKAGE_STAGE_DIR}/payload"
SOURCE_COPY_REALPATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${SOURCE_COPY_DIR}")"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "[1/5] Copying build products to temporary workspace..."
mkdir -p "${SOURCE_COPY_DIR}" "${PAYLOAD_DIR}"
rsync -a "${SOURCE_DIR}/" "${SOURCE_COPY_DIR}/"

echo "[2/5] Resolving all symbolic links in copied tree..."
targets_to_remove_file="${WORK_DIR}/targets-to-remove.txt"
: > "${targets_to_remove_file}"
while IFS= read -r -d '' link_path; do
    target_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${link_path}")"
    if [[ ! -e "${target_path}" ]]; then
        echo "Warning: removing broken symlink in copy: ${link_path} -> ${target_path}" >&2
        rm "${link_path}"
        continue
    fi
    rm "${link_path}"
    ditto "${target_path}" "${link_path}"

    case "${target_path}" in
        "${SOURCE_COPY_REALPATH}"/*)
            echo "${target_path}" >> "${targets_to_remove_file}"
            ;;
    esac
done < <(find "${SOURCE_COPY_DIR}" -type l -print0)

if [[ -s "${targets_to_remove_file}" ]]; then
    # Remove original in-copy targets after links are materialized to avoid duplicate payload content.
    sort -u "${targets_to_remove_file}" | while IFS= read -r original_target; do
        [[ -e "${original_target}" ]] || continue
        rm -rf "${original_target}"
    done
fi
rm -f "${targets_to_remove_file}"
echo "Resolved symlinks and removed original in-copy targets."

echo "[3/5] Collecting required/recommended/on-demand artifacts..."
typeset -a required_items=(
    "WebKit.framework"
    "WebCore.framework"
    "WebKitLegacy.framework"
    "JavaScriptCore.framework"
    "libwebrtc.dylib"
)

typeset -a recommended_items=(
    "libANGLE-shared.dylib"
    "WebGPU.framework"
    "com.apple.WebKit.WebContent.xpc"
    "com.apple.WebKit.Networking.xpc"
    "com.apple.WebKit.GPU.xpc"
    "com.apple.WebKit.WebContent.CaptivePortal.xpc"
    "com.apple.WebKit.WebContent.Crashy.xpc"
    "com.apple.WebKit.WebContent.Development.xpc"
)

typeset -a ondemand_items=(
    "webpushd"
    "adattributiond"
    "com.apple.WebKit.WebAuthn.xpc"
)

copy_item_if_exists() {
    local item="$1"
    local src="${SOURCE_COPY_DIR}/${item}"
    local dst="${PAYLOAD_DIR}/${item}"
    if [[ -e "${src}" ]]; then
        ditto "${src}" "${dst}"
        return 0
    fi
    return 1
}

item_is_already_covered_in_framework() {
    local item="$1"
    if [[ -e "${PAYLOAD_DIR}/WebKit.framework/XPCServices/${item}" ]]; then
        return 0
    fi
    if [[ -e "${PAYLOAD_DIR}/WebKit.framework/Daemons/${item}" ]]; then
        return 0
    fi
    return 1
}

for item in "${required_items[@]}"; do
    if ! copy_item_if_exists "${item}"; then
        echo "Missing required artifact: ${item}" >&2
        exit 1
    fi
done

for item in "${recommended_items[@]}"; do
    if ! copy_item_if_exists "${item}"; then
        if item_is_already_covered_in_framework "${item}"; then
            echo "Info: ${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        echo "Warning: recommended artifact not found: ${item}" >&2
    fi
done

for item in "${ondemand_items[@]}"; do
    if ! copy_item_if_exists "${item}"; then
        if item_is_already_covered_in_framework "${item}"; then
            echo "Info: ${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        echo "Note: on-demand artifact not found: ${item}" >&2
    fi
done

echo "[3.5/5] Pruning non-runtime files..."
# 1) Exclude DerivedSources from package payload.
rm -rf "${PAYLOAD_DIR}/DerivedSources"

# 2) Exclude headers from frameworks.
find "${PAYLOAD_DIR}" -type d \( -name Headers -o -name PrivateHeaders \) -prune -exec rm -rf {} +

# 3) Exclude .tbd files.
find "${PAYLOAD_DIR}" -type f -name '*.tbd' -delete

# 4) Final fallback: move any top-level .xpc into WebKit.framework/XPCServices.
XPC_FALLBACK_DIR="${PAYLOAD_DIR}/WebKit.framework/XPCServices"
mkdir -p "${XPC_FALLBACK_DIR}"
while IFS= read -r -d '' top_level_xpc; do
    xpc_name="$(basename "${top_level_xpc}")"
    dst="${XPC_FALLBACK_DIR}/${xpc_name}"
    if [[ -e "${dst}" ]]; then
        rm -rf "${top_level_xpc}"
        continue
    fi
    mv "${top_level_xpc}" "${dst}"
done < <(find "${PAYLOAD_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.xpc' -print0)

echo "[4/6] Signing Mach-O binaries with ldid..."
if ! command -v ldid >/dev/null 2>&1; then
    echo "ldid not found in PATH." >&2
    exit 1
fi

WEBKIT_PROCESS_ENTITLEMENTS="${SCRIPT_DIR}/WebKit/Source/WebKit/Scripts/process-entitlements.sh"
JSC_PROCESS_ENTITLEMENTS="${SCRIPT_DIR}/WebKit/Source/JavaScriptCore/Scripts/process-entitlements.sh"
ENTITLEMENTS_WORK_DIR="${WORK_DIR}/entitlements"
mkdir -p "${ENTITLEMENTS_WORK_DIR}"

entitlements_script_for_binary() {
    local rel="$1"
    case "${rel}" in
        JavaScriptCore.framework/Helpers/jsc)
            echo "${JSC_PROCESS_ENTITLEMENTS}"
            ;;
        WebKit.framework/XPCServices/*.xpc/*|WebKit.framework/Daemons/webpushd|WebKit.framework/Daemons/adattributiond)
            echo "${WEBKIT_PROCESS_ENTITLEMENTS}"
            ;;
        *)
            echo ""
            ;;
    esac
}

product_name_for_binary() {
    local binary="$1"
    local rel="$2"
    case "${rel}" in
        JavaScriptCore.framework/Helpers/jsc)
            echo "jsc"
            ;;
        WebKit.framework/XPCServices/*.xpc/*)
            basename "$(dirname "${binary}")" .xpc
            ;;
        WebKit.framework/Daemons/*)
            basename "${binary}"
            ;;
        *)
            echo ""
            ;;
    esac
}

sign_macho() {
    local binary="$1"
    local rel="${binary#${PAYLOAD_DIR}/}"
    local entitlements_script
    local product_name
    local entitlements_path

    entitlements_script="$(entitlements_script_for_binary "${rel}")"
    product_name="$(product_name_for_binary "${binary}" "${rel}")"
    entitlements_path=""

    if [[ -n "${entitlements_script}" && -n "${product_name}" && -x "${entitlements_script}" ]]; then
        entitlements_path="${ENTITLEMENTS_WORK_DIR}/${rel//\//_}.entitlements"
        if ! WK_PLATFORM_NAME=iphoneos PRODUCT_NAME="${product_name}" WK_PROCESSED_XCENT_FILE="${entitlements_path}" "${entitlements_script}" >/dev/null 2>&1; then
            echo "Warning: failed to generate entitlements for ${rel}; signing without explicit entitlements." >&2
            entitlements_path=""
        fi
    fi

    if [[ -n "${entitlements_path}" && -f "${entitlements_path}" ]]; then
        ldid "-S${entitlements_path}" "${binary}"
    else
        ldid -S "${binary}"
    fi
}

while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "${candidate}" | grep -q 'Mach-O'; then
        sign_macho "${candidate}"
    fi
done < <(find "${PAYLOAD_DIR}" -type f -print0)

echo "[5/6] Creating tarball..."
mkdir -p "$(dirname "${OUTPUT_TAR}")"
COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "${OUTPUT_TAR}" \
    --exclude='._*' \
    -C "${PACKAGE_STAGE_DIR}" payload

if [[ "${PUSH_TO_DEVICE}" == "1" ]]; then
    PUSH_SCRIPT="${SCRIPT_DIR}/push-webkit-device-artifacts.sh"
    if [[ ! -f "${PUSH_SCRIPT}" ]]; then
        echo "Push script not found: ${PUSH_SCRIPT}" >&2
        exit 1
    fi

    echo "[6/6] Delegating push to ${PUSH_SCRIPT} ..."
    typeset -a push_args=("--package" "${OUTPUT_TAR}" "--ssh-target" "${SSH_TARGET}" "--remote-dir" "${REMOTE_DIR}")
    if [[ -n "${SSH_HOST}" ]]; then
        push_args+=("--ssh-host" "${SSH_HOST}")
    fi
    if [[ -n "${SSH_PORT}" ]]; then
        push_args+=("--ssh-port" "${SSH_PORT}")
    fi
    if [[ -n "${SSH_USER}" ]]; then
        push_args+=("--ssh-user" "${SSH_USER}")
    fi

    zsh "${PUSH_SCRIPT}" "${push_args[@]}"
else
    echo "[6/6] Done."
fi

echo "Package created: ${OUTPUT_TAR}"
