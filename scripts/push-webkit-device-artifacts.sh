#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
PACKAGE_PATH=""
SSH_TARGET="iproxy"
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
REMOTE_DIR="/var/root"
KEEP_REMOTE_PACKAGE=0
INCLUDE_JSC=0
SKIP_ABI_CHECK=0
STOCK_JSC="${ROOT_DIR}/samples/device-dsc-split/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"
STOCK_WEBCORE="${ROOT_DIR}/samples/device-dsc-split/System/Library/PrivateFrameworks/WebCore.framework/WebCore"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--package <tar.gz-path>]
          [--ssh-target <ssh-config-host>] [--ssh-host <host>] [--ssh-port <port>]
          [--ssh-user <user>] [--remote-dir <dir>] [--keep-remote-package]
          [--include-jsc] [--skip-abi-check] [--stock-jsc <path>] [--stock-webcore <path>]

Default behavior:
  If --package is not provided, use the newest:
  ${ROOT_DIR}/webkit-device-package-*.tar.gz

Default SSH (iproxy style):
  --ssh-target ${SSH_TARGET}
  --remote-dir ${REMOTE_DIR}

Notes:
  JavaScriptCore.framework is excluded on push by default.
  Pass --include-jsc to push JavaScriptCore.framework too.
  ABI + layout checks run by default when JSC is excluded.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package)
            PACKAGE_PATH="${2:?missing value for --package}"
            shift 2
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
        --keep-remote-package)
            KEEP_REMOTE_PACKAGE=1
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

if [[ -z "${PACKAGE_PATH}" ]]; then
    PACKAGE_PATH="$(ls -1t "${ROOT_DIR}"/webkit-device-package-*.tar.gz 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${PACKAGE_PATH}" ]]; then
    echo "No package file found. Provide --package <tar.gz-path>." >&2
    exit 1
fi

if [[ ! -f "${PACKAGE_PATH}" ]]; then
    echo "Package file does not exist: ${PACKAGE_PATH}" >&2
    exit 1
fi

if [[ "${INCLUDE_JSC}" != "1" && "${SKIP_ABI_CHECK}" != "1" ]]; then
    ABI_CHECK_SCRIPT="${SCRIPT_DIR}/check-jsc-abi-compat.sh"
    if [[ ! -f "${ABI_CHECK_SCRIPT}" ]]; then
        echo "ABI check script not found: ${ABI_CHECK_SCRIPT}" >&2
        exit 1
    fi
    echo "[1/4] Running ABI gate against stock JSC..."
    zsh "${ABI_CHECK_SCRIPT}" --package "${PACKAGE_PATH}" --stock-jsc "${STOCK_JSC}"

    LAYOUT_CHECK_SCRIPT="${SCRIPT_DIR}/check-webcore-layout-compat.sh"
    if [[ ! -f "${LAYOUT_CHECK_SCRIPT}" ]]; then
        echo "Layout check script not found: ${LAYOUT_CHECK_SCRIPT}" >&2
        exit 1
    fi
    echo "[2/4] Running WebCore mixed-mode layout gate..."
    zsh "${LAYOUT_CHECK_SCRIPT}" --package "${PACKAGE_PATH}" --stock-webcore "${STOCK_WEBCORE}"
fi

remote="${SSH_TARGET}"
if [[ -n "${SSH_HOST}" ]]; then
    if [[ -n "${SSH_USER}" ]]; then
        remote="${SSH_USER}@${SSH_HOST}"
    else
        remote="${SSH_HOST}"
    fi
fi

typeset -a ssh_extra_args=()
typeset -a scp_extra_args=()
if [[ -n "${SSH_PORT}" ]]; then
    ssh_extra_args+=("-p" "${SSH_PORT}")
    scp_extra_args+=("-P" "${SSH_PORT}")
fi

remote_tar="${REMOTE_DIR}/$(basename "${PACKAGE_PATH}")"

echo "[3/4] Uploading package to device..."
ssh "${ssh_extra_args[@]}" "${remote}" "mkdir -p '${REMOTE_DIR}'"
scp "${scp_extra_args[@]}" "${PACKAGE_PATH}" "${remote}:${remote_tar}"
echo "Uploaded to: ${remote}:${remote_tar}"

echo "[4/4] Extracting package on device..."
ssh "${ssh_extra_args[@]}" "${remote}" '
set -e
INCLUDE_JSC='"${INCLUDE_JSC}"'
TARGET_FRAMEWORKS_DIR="/Library/Frameworks"
if [ -d "/var/jb/Library/Frameworks" ]; then
    TARGET_FRAMEWORKS_DIR="/var/jb/Library/Frameworks"
fi
TARGET_USRLIB_DIR="/usr/lib"
if [ -d "/var/jb/usr/lib" ]; then
    TARGET_USRLIB_DIR="/var/jb/usr/lib"
fi

TMP_DIR="/tmp/webkit-device-package.$$"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
tar -xzf "'"${remote_tar}"'" -C "${TMP_DIR}"

if [ ! -d "${TMP_DIR}/payload" ]; then
    echo "Remote extract failed: payload directory missing." >&2
    exit 1
fi

if [ "${INCLUDE_JSC}" != "1" ]; then
    rm -rf "${TMP_DIR}/payload/JavaScriptCore.framework"
fi

mkdir -p "${TARGET_FRAMEWORKS_DIR}"
cp -R "${TMP_DIR}/payload/." "${TARGET_FRAMEWORKS_DIR}/"

# Move dylibs into usr/lib (jailbreak path preferred), then remove duplicates from Frameworks.
mkdir -p "${TARGET_USRLIB_DIR}"
find "${TMP_DIR}/payload" -mindepth 1 -maxdepth 1 -type f -name "*.dylib" | while IFS= read -r dylib; do
    base="$(basename "${dylib}")"
    cp -f "${dylib}" "${TARGET_USRLIB_DIR}/${base}"
    rm -f "${TARGET_FRAMEWORKS_DIR}/${base}"
done

rm -rf "${TMP_DIR}"
echo "Extracted to: ${TARGET_FRAMEWORKS_DIR}"
echo "Moved dylibs to: ${TARGET_USRLIB_DIR}"
'

if [[ "${KEEP_REMOTE_PACKAGE}" != "1" ]]; then
    ssh "${ssh_extra_args[@]}" "${remote}" "rm -f '${remote_tar}'"
fi

echo "[4/4] Done."
