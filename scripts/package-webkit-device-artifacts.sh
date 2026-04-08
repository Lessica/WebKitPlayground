#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEFAULT_SOURCE_DIR="${ROOT_DIR}/WebKitBuild/Debug-iphoneos"
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"
OUTPUT_TAR=""
PUSH_TO_DEVICE=0
INCLUDE_JSC=0
SKIP_ABI_CHECK=0
SSH_TARGET="iproxy"
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
REMOTE_DIR="/var/root"
STOCK_JSC="${ROOT_DIR}/samples/device-dsc-split/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"
STOCK_WEBCORE="${ROOT_DIR}/samples/device-dsc-split/System/Library/PrivateFrameworks/WebCore.framework/WebCore"
STEP_INDEX=0
TOTAL_STEPS=0

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
else
    C_RESET=""
    C_BOLD=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
fi

log_step() {
    STEP_INDEX=$((STEP_INDEX + 1))
    printf "%s%s[%d/%d]%s %s\n" "${C_BOLD}" "${C_CYAN}" "${STEP_INDEX}" "${TOTAL_STEPS}" "${C_RESET}" "$1"
}

log_info() {
    printf "%sInfo:%s %s\n" "${C_CYAN}" "${C_RESET}" "$1"
}

log_note() {
    printf "%sNote:%s %s\n" "${C_CYAN}" "${C_RESET}" "$1"
}

log_warn() {
    printf "%sWarning:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2
}

log_error() {
    printf "%sError:%s %s\n" "${C_RED}" "${C_RESET}" "$1" >&2
}

log_success() {
    printf "%s%s%s\n" "${C_GREEN}" "$1" "${C_RESET}"
}

log_phase() {
    printf "%s%s== %s ==%s\n" "${C_BOLD}" "${C_CYAN}" "$1" "${C_RESET}"
}

pick_tar_bin() {
    if command -v gtar >/dev/null 2>&1; then
        print -- "gtar"
        return
    fi
    print -- "tar"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--source <Debug-iphoneos-dir>] [--output <tar.gz-path>] [--push-device]
          [--ssh-target <ssh-config-host>] [--ssh-host <host>] [--ssh-port <port>]
          [--ssh-user <user>] [--remote-dir <dir>] [--include-jsc]
          [--skip-abi-check] [--stock-jsc <path>] [--stock-webcore <path>]

Default source:
  ${DEFAULT_SOURCE_DIR}

Default SSH (iproxy style):
  --ssh-target ${SSH_TARGET}
  --remote-dir ${REMOTE_DIR}

Default gates (when JSC is excluded):
  --stock-jsc ${STOCK_JSC}
  --stock-webcore ${STOCK_WEBCORE}
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
        --include-jsc)
            INCLUDE_JSC=1
            shift
            ;;
        --skip-abi-check)
            SKIP_ABI_CHECK=1
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
        --stock-jsc)
            STOCK_JSC="${2:?missing value for --stock-jsc}"
            shift 2
            ;;
        --stock-webcore)
            STOCK_WEBCORE="${2:?missing value for --stock-webcore}"
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
    log_error "Source directory does not exist: ${SOURCE_DIR}"
    exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUTPUT_TAR}" ]]; then
    OUTPUT_TAR="${ROOT_DIR}/webkit-device-package-${timestamp}.tar.gz"
fi

TOTAL_STEPS=5
if [[ "${INCLUDE_JSC}" != "1" && "${SKIP_ABI_CHECK}" != "1" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 2))
fi

TAR_BIN="$(pick_tar_bin)"
if [[ "${TAR_BIN}" == "gtar" ]]; then
    log_info "Using GNU tar for packaging: ${TAR_BIN}"
else
    log_warn "gtar not found; falling back to tar. Extended-header warnings may still appear when extracting."
fi

WORK_BASE_DIR="$(cd "$(dirname "${SOURCE_DIR}")" && pwd)"
WORK_DIR="$(mktemp -d "${WORK_BASE_DIR}/.webkit-device-package.XXXXXX")"
PACKAGE_STAGE_DIR="${WORK_DIR}/package-stage"
PAYLOAD_DIR="${PACKAGE_STAGE_DIR}/payload"
PAYLOAD_REALPATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${PAYLOAD_DIR}")"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log_step "Collecting required/recommended/on-demand artifacts into staging payload..."
mkdir -p "${PAYLOAD_DIR}"
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
    local src="${SOURCE_DIR}/${item}"
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
        log_error "Missing required artifact: ${item}"
        exit 1
    fi
done

for item in "${recommended_items[@]}"; do
    if ! copy_item_if_exists "${item}"; then
        if item_is_already_covered_in_framework "${item}"; then
            log_info "${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        log_warn "recommended artifact not found: ${item}"
    fi
done

for item in "${ondemand_items[@]}"; do
    if ! copy_item_if_exists "${item}"; then
        if item_is_already_covered_in_framework "${item}"; then
            log_info "${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        log_note "on-demand artifact not found: ${item}"
    fi
done

log_step "Resolving external/broken symlinks inside payload..."
while IFS= read -r -d '' link_path; do
    target_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${link_path}")"
    if [[ ! -e "${target_path}" ]]; then
        log_warn "removing broken symlink in payload: ${link_path} -> ${target_path}"
        rm "${link_path}"
        continue
    fi

    case "${target_path}" in
        "${PAYLOAD_REALPATH}"/*)
            # Internal link remains valid after packaging.
            continue
            ;;
    esac

    rm "${link_path}"
    ditto "${target_path}" "${link_path}"
done < <(find "${PAYLOAD_DIR}" -type l -print0)

log_step "Pruning non-runtime files..."
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

if [[ "${INCLUDE_JSC}" != "1" && "${SKIP_ABI_CHECK}" != "1" ]]; then
    ABI_CHECK_SCRIPT="${SCRIPT_DIR}/check-jsc-abi-compat.sh"
    if [[ ! -f "${ABI_CHECK_SCRIPT}" ]]; then
        log_error "ABI check script not found: ${ABI_CHECK_SCRIPT}"
        exit 1
    fi
    if [[ ! -f "${STOCK_JSC}" ]]; then
        log_error "Stock JSC binary does not exist: ${STOCK_JSC}"
        exit 1
    fi
    log_step "Running ABI gate against stock JSC..."
    zsh "${ABI_CHECK_SCRIPT}" --build-dir "${PAYLOAD_DIR}" --stock-jsc "${STOCK_JSC}"

    LAYOUT_CHECK_SCRIPT="${SCRIPT_DIR}/check-webcore-layout-compat.sh"
    if [[ ! -f "${LAYOUT_CHECK_SCRIPT}" ]]; then
        log_error "Layout check script not found: ${LAYOUT_CHECK_SCRIPT}"
        exit 1
    fi
    if [[ ! -f "${STOCK_WEBCORE}" ]]; then
        log_error "Stock WebCore binary does not exist: ${STOCK_WEBCORE}"
        exit 1
    fi
    log_step "Running WebCore mixed-mode layout gate..."
    zsh "${LAYOUT_CHECK_SCRIPT}" --build-dir "${PAYLOAD_DIR}" --stock-webcore "${STOCK_WEBCORE}"
fi

log_step "Signing Mach-O binaries with ldid..."
if ! command -v ldid >/dev/null 2>&1; then
    log_error "ldid not found in PATH."
    exit 1
fi

WEBKIT_PROCESS_ENTITLEMENTS="${ROOT_DIR}/WebKit/Source/WebKit/Scripts/process-entitlements.sh"
JSC_PROCESS_ENTITLEMENTS="${ROOT_DIR}/WebKit/Source/JavaScriptCore/Scripts/process-entitlements.sh"
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
            log_warn "failed to generate entitlements for ${rel}; signing without explicit entitlements."
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

log_step "Creating tarball..."
mkdir -p "$(dirname "${OUTPUT_TAR}")"
COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 "${TAR_BIN}" -czf "${OUTPUT_TAR}" \
    --exclude='._*' \
    -C "${PACKAGE_STAGE_DIR}" payload

if [[ "${PUSH_TO_DEVICE}" == "1" ]]; then
    PUSH_SCRIPT="${SCRIPT_DIR}/push-webkit-device-artifacts.sh"
    if [[ ! -f "${PUSH_SCRIPT}" ]]; then
        log_error "Push script not found: ${PUSH_SCRIPT}"
        exit 1
    fi

    log_phase "Packaging completed, switching to push phase"
    log_info "Delegating to ${PUSH_SCRIPT}"
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
    if [[ "${INCLUDE_JSC}" == "1" ]]; then
        push_args+=("--include-jsc")
    fi

    zsh "${PUSH_SCRIPT}" "${push_args[@]}"
else
    log_success "Done."
fi

log_success "Package created: ${OUTPUT_TAR}"
