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
STEP_INDEX=0
TOTAL_STEPS=3

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

log_warn() {
    printf "%sWarning:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2
}

log_error() {
    printf "%sError:%s %s\n" "${C_RED}" "${C_RESET}" "$1" >&2
}

log_success() {
    printf "%s%s%s\n" "${C_GREEN}" "$1" "${C_RESET}"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--package <tar.gz-path>]
          [--ssh-target <ssh-config-host>] [--ssh-host <host>] [--ssh-port <port>]
          [--ssh-user <user>] [--remote-dir <dir>] [--keep-remote-package]

Default behavior:
  If --package is not provided, use the newest:
  ${ROOT_DIR}/webkit-device-package-*.tar.gz

Default SSH (iproxy style):
  --ssh-target ${SSH_TARGET}
  --remote-dir ${REMOTE_DIR}
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${PACKAGE_PATH}" ]]; then
    PACKAGE_PATH="$(ls -1t "${ROOT_DIR}"/webkit-device-package-*.tar.gz 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${PACKAGE_PATH}" ]]; then
    log_error "No package file found. Provide --package <tar.gz-path>."
    exit 1
fi

if [[ ! -f "${PACKAGE_PATH}" ]]; then
    log_error "Package file does not exist: ${PACKAGE_PATH}"
    exit 1
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

log_step "Uploading package to device..."
ssh "${ssh_extra_args[@]}" "${remote}" "mkdir -p '${REMOTE_DIR}'"
scp "${scp_extra_args[@]}" "${PACKAGE_PATH}" "${remote}:${remote_tar}"
log_info "Uploaded to: ${remote}:${remote_tar}"

log_step "Extracting package on device..."
ssh "${ssh_extra_args[@]}" "${remote}" '
set -e
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

mkdir -p "${TARGET_FRAMEWORKS_DIR}"
# Replace top-level payload entries one by one to avoid
# "cannot overwrite directory ... with non-directory" conflicts.
find "${TMP_DIR}/payload" -mindepth 1 -maxdepth 1 | while IFS= read -r src; do
    base="$(basename "${src}")"
    dst="${TARGET_FRAMEWORKS_DIR}/${base}"
    rm -rf "${dst}"
    cp -R "${src}" "${dst}"
done

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
else
    log_warn "Keeping remote package: ${remote_tar}"
fi

log_step "Done."
log_success "Push completed."
