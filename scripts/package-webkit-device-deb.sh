#!/bin/zsh
# ──────────────────────────────────────────────────────────────
# package-webkit-device-deb.sh
#
# Package WebKit device build artifacts into a .deb for
# jailbroken iOS devices.  Installation effect mirrors
# push-webkit-device-artifacts.sh:
#   Frameworks -> /Library/Frameworks  (rootful)
#              -> /var/jb/Library/Frameworks  (rootless)
#   Dylibs    -> /usr/lib              (rootful)
#              -> /var/jb/usr/lib       (rootless)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
SOURCE_DIR="${ROOT_DIR}/WebKit"
PRODUCT_DIR="${SOURCE_DIR}/WebKitBuild/Debug-iphoneos"
OUTPUT_DEB=""
ROOTLESS=0
ROOTHIDE=0
PACKAGE_ID="com.82flex.custom-webkit"
PACKAGE_NAME="Custom WebKit"
PACKAGE_VERSION=""
PACKAGE_AUTHOR="WebKitPlayground Builder"
PACKAGE_DESCRIPTION="Custom-built WebKit frameworks for iOS device injection."
STEP_INDEX=0
TOTAL_STEPS=0

# ── colours ──────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=""; C_BOLD=""
    C_CYAN=""; C_GREEN=""
    C_YELLOW=""; C_RED=""
fi

# ── logging helpers ──────────────────────────────────────────
log_step()    { STEP_INDEX=$((STEP_INDEX + 1)); printf "%s%s[%d/%d]%s %s\n" "${C_BOLD}" "${C_CYAN}" "${STEP_INDEX}" "${TOTAL_STEPS}" "${C_RESET}" "$1"; }
log_info()    { printf "%sInfo:%s %s\n"    "${C_CYAN}"   "${C_RESET}" "$1"; }
log_note()    { printf "%sNote:%s %s\n"    "${C_CYAN}"   "${C_RESET}" "$1"; }
log_warn()    { printf "%sWarning:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2; }
log_error()   { printf "%sError:%s %s\n"   "${C_RED}"    "${C_RESET}" "$1" >&2; }
log_success() { printf "%s%s%s\n"          "${C_GREEN}"  "$1" "${C_RESET}"; }

# ── usage ────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  --product <dir>         Build product directory (default: WebKit/WebKitBuild/Debug-iphoneos)
  --output  <deb-path>    Output .deb file path (auto-generated if omitted)
  --rootless              Target rootless jailbreak (e.g. Dopamine/palera1n rootless)
                          Install prefix becomes /var/jb; Architecture: iphoneos-arm64
  --roothide              Target roothide jailbreak (arm64e devices, e.g. Dopamine roothide)
                          No prefix change; Architecture: iphoneos-arm64e
  --id      <bundle-id>   Debian package identifier  (default: ${PACKAGE_ID})
  --name    <name>        Debian package display name (default: ${PACKAGE_NAME})
  --version <ver>         Debian package version      (default: auto from WebKit Version.xcconfig)
  --author  <author>      Maintainer field            (default: ${PACKAGE_AUTHOR})
  -h, --help              Show this help

Notes:
  Requires 'ldid' in PATH for ad-hoc signing.
  Requires 'dpkg-deb' in PATH (install via: "brew install dpkg").
EOF
}

# ── argument parsing ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --product)   PRODUCT_DIR="${2:?missing value for --product}"; SOURCE_DIR="$(dirname "$(dirname "${PRODUCT_DIR}")")"; shift 2 ;;
        --output)    OUTPUT_DEB="${2:?missing value for --output}"; shift 2 ;;
        --rootless)  ROOTLESS=1; shift ;;
        --roothide)  ROOTHIDE=1; shift ;;
        --id)        PACKAGE_ID="${2:?missing value for --id}"; shift 2 ;;
        --name)      PACKAGE_NAME="${2:?missing value for --name}"; shift 2 ;;
        --version)   PACKAGE_VERSION="${2:?missing value for --version}"; shift 2 ;;
        --author)    PACKAGE_AUTHOR="${2:?missing value for --author}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           log_error "Unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

# ── validate prerequisites ───────────────────────────────────
if [[ ! -d "${PRODUCT_DIR}" ]]; then
    log_error "Product directory does not exist: ${PRODUCT_DIR}"
    exit 1
fi

if ! command -v ldid >/dev/null 2>&1; then
    log_error "ldid not found in PATH. Install it first (brew install ldid)."
    exit 1
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    log_error "dpkg-deb not found in PATH. Install it first (brew install dpkg)."
    exit 1
fi

# ── auto-detect version ─────────────────────────────────────
if [[ -z "${PACKAGE_VERSION}" ]]; then
    # Probe candidate paths in priority order:
    #   1. top-level Configurations/ (e.g. open-source main branch)
    #   2. Source/WebKit/Configurations/ (e.g. iOS 16.3.x drop)
    #   3. Source/JavaScriptCore/Configurations/
    VERSION_XCCONFIG=""
    for _candidate in \
        "${SOURCE_DIR}/Configurations/Version.xcconfig" \
        "${SOURCE_DIR}/Source/WebKit/Configurations/Version.xcconfig" \
        "${SOURCE_DIR}/Source/JavaScriptCore/Configurations/Version.xcconfig"
    do
        if [[ -f "${_candidate}" ]]; then
            VERSION_XCCONFIG="${_candidate}"
            break
        fi
    done

    if [[ -n "${VERSION_XCCONFIG}" ]]; then
        major="$(grep '^MAJOR_VERSION' "${VERSION_XCCONFIG}" | head -1 | sed 's/.*= *//;s/[;[:space:]]*$//')"
        minor="$(grep '^MINOR_VERSION' "${VERSION_XCCONFIG}" | head -1 | sed 's/.*= *//;s/[;[:space:]]*$//')"
        tiny="$(grep  '^TINY_VERSION'  "${VERSION_XCCONFIG}" | head -1 | sed 's/.*= *//;s/[;[:space:]]*$//')"
        PACKAGE_VERSION="${major:-0}.${minor:-0}.${tiny:-0}"
        log_info "Version detected from: ${VERSION_XCCONFIG} -> ${PACKAGE_VERSION}"
    else
        PACKAGE_VERSION="0.0.1"
        log_warn "Version.xcconfig not found; falling back to ${PACKAGE_VERSION}"
    fi
    # Append a timestamp suffix to distinguish rebuild iterations.
    PACKAGE_VERSION="${PACKAGE_VERSION}-$(date +%Y%m%d%H%M%S)"
fi

# ── determine install prefixes ───────────────────────────────
if [[ "${ROOTHIDE}" == "1" && "${ROOTLESS}" == "1" ]]; then
    log_error "--rootless and --roothide are mutually exclusive."
    exit 1
fi

if [[ "${ROOTLESS}" == "1" ]]; then
    PREFIX="/var/jb"
    PACKAGE_ARCH="iphoneos-arm64"
    log_info "Rootless mode: install prefix = ${PREFIX}, arch = ${PACKAGE_ARCH}"
elif [[ "${ROOTHIDE}" == "1" ]]; then
    PREFIX=""
    PACKAGE_ARCH="iphoneos-arm64e"
    log_info "Roothide mode: install prefix = /, arch = ${PACKAGE_ARCH}"
else
    PREFIX=""
    PACKAGE_ARCH="iphoneos-arm"
    log_info "Rootful mode: install prefix = /, arch = ${PACKAGE_ARCH}"
fi

INSTALL_FRAMEWORKS_DIR="${PREFIX}/Library/Frameworks"
INSTALL_USRLIB_DIR="${PREFIX}/usr/lib"

# ── output path ──────────────────────────────────────────────
timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUTPUT_DEB}" ]]; then
    OUTPUT_PKG_DIR="${ROOT_DIR}/packages"
    mkdir -p "${OUTPUT_PKG_DIR}"
    OUTPUT_DEB="${OUTPUT_PKG_DIR}/${PACKAGE_ID}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"
fi

TOTAL_STEPS=7

# ── working directory ────────────────────────────────────────
WORK_BASE_DIR="$(cd "$(dirname "${PRODUCT_DIR}")" && pwd)"
WORK_DIR="$(mktemp -d "${WORK_BASE_DIR}/.webkit-deb-package.XXXXXX")"
DEB_ROOT="${WORK_DIR}/deb-root"
PAYLOAD_DIR="${DEB_ROOT}${INSTALL_FRAMEWORKS_DIR}"
USRLIB_DIR="${DEB_ROOT}${INSTALL_USRLIB_DIR}"
PAYLOAD_REALPATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${PAYLOAD_DIR}" 2>/dev/null || echo "${PAYLOAD_DIR}")"

cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════
# STEP 1 — Collect artifacts
# ══════════════════════════════════════════════════════════════
log_step "Collecting required/recommended/on-demand artifacts..."
mkdir -p "${PAYLOAD_DIR}" "${USRLIB_DIR}"

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
    local item="$1" dst_dir="$2"
    local src="${PRODUCT_DIR}/${item}"
    local dst="${dst_dir}/${item}"
    if [[ -e "${src}" ]]; then
        ditto "${src}" "${dst}"
        return 0
    fi
    return 1
}

item_is_already_covered_in_framework() {
    local item="$1"
    [[ -e "${PAYLOAD_DIR}/WebKit.framework/XPCServices/${item}" ]] && return 0
    [[ -e "${PAYLOAD_DIR}/WebKit.framework/Daemons/${item}" ]]    && return 0
    return 1
}

for item in "${required_items[@]}"; do
    if ! copy_item_if_exists "${item}" "${PAYLOAD_DIR}"; then
        log_error "Missing required artifact: ${item}"
        exit 1
    fi
done

for item in "${recommended_items[@]}"; do
    if ! copy_item_if_exists "${item}" "${PAYLOAD_DIR}"; then
        if item_is_already_covered_in_framework "${item}"; then
            log_info "${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        log_warn "recommended artifact not found: ${item}"
    fi
done

for item in "${ondemand_items[@]}"; do
    if ! copy_item_if_exists "${item}" "${PAYLOAD_DIR}"; then
        if item_is_already_covered_in_framework "${item}"; then
            log_info "${item} already covered via WebKit.framework subdirectory."
            continue
        fi
        log_note "on-demand artifact not found: ${item}"
    fi
done

# ══════════════════════════════════════════════════════════════
# STEP 2 — Resolve external/broken symlinks
# ══════════════════════════════════════════════════════════════
log_step "Resolving external/broken symlinks inside payload..."
while IFS= read -r -d '' link_path; do
    target_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${link_path}")"
    if [[ ! -e "${target_path}" ]]; then
        log_warn "removing broken symlink: ${link_path} -> ${target_path}"
        rm "${link_path}"
        continue
    fi
    case "${target_path}" in
        "${PAYLOAD_REALPATH}"/*) continue ;;
    esac
    rm "${link_path}"
    ditto "${target_path}" "${link_path}"
done < <(find "${PAYLOAD_DIR}" -type l -print0)

# ══════════════════════════════════════════════════════════════
# STEP 3 — Prune non-runtime files
# ══════════════════════════════════════════════════════════════
log_step "Pruning non-runtime files..."
rm -rf "${PAYLOAD_DIR}/DerivedSources"
find "${PAYLOAD_DIR}" -type d \( -name Headers -o -name PrivateHeaders \) -prune -exec rm -rf {} +
find "${PAYLOAD_DIR}" -type f -name '*.tbd' -delete

# Move top-level .xpc bundles into WebKit.framework/XPCServices.
XPC_FALLBACK_DIR="${PAYLOAD_DIR}/WebKit.framework/XPCServices"
mkdir -p "${XPC_FALLBACK_DIR}"
while IFS= read -r -d '' top_level_xpc; do
    xpc_name="$(basename "${top_level_xpc}")"
    dst="${XPC_FALLBACK_DIR}/${xpc_name}"
    if [[ -L "${dst}" ]]; then
        rm -f "${dst}"; mv "${top_level_xpc}" "${dst}"; continue
    fi
    if [[ -e "${dst}" ]]; then
        rm -rf "${top_level_xpc}"; continue
    fi
    mv "${top_level_xpc}" "${dst}"
done < <(find "${PAYLOAD_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.xpc' -print0)

# ══════════════════════════════════════════════════════════════
# STEP 4 — Move dylibs to usr/lib
# ══════════════════════════════════════════════════════════════
log_step "Moving dylibs to ${INSTALL_USRLIB_DIR}..."
while IFS= read -r -d '' dylib; do
    base="$(basename "${dylib}")"
    cp -f "${dylib}" "${USRLIB_DIR}/${base}"
    rm -f "${dylib}"
done < <(find "${PAYLOAD_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.dylib' -print0)

# ══════════════════════════════════════════════════════════════
# STEP 5 — Sign Mach-O binaries with ldid
# ══════════════════════════════════════════════════════════════
log_step "Signing Mach-O binaries with ldid..."

WEBKIT_PROCESS_ENTITLEMENTS="${SOURCE_DIR}/Source/WebKit/Scripts/process-entitlements.sh"
JSC_PROCESS_ENTITLEMENTS="${SOURCE_DIR}/Source/JavaScriptCore/Scripts/process-entitlements.sh"
ENTITLEMENTS_WORK_DIR="${WORK_DIR}/entitlements"
mkdir -p "${ENTITLEMENTS_WORK_DIR}"

entitlements_script_for_binary() {
    local rel="$1"
    case "${rel}" in
        JavaScriptCore.framework/Helpers/jsc) echo "${JSC_PROCESS_ENTITLEMENTS}" ;;
        WebKit.framework/XPCServices/*.xpc/*|WebKit.framework/Daemons/webpushd|WebKit.framework/Daemons/adattributiond)
            echo "${WEBKIT_PROCESS_ENTITLEMENTS}" ;;
        *) echo "" ;;
    esac
}

product_name_for_binary() {
    local binary="$1" rel="$2"
    case "${rel}" in
        JavaScriptCore.framework/Helpers/jsc) echo "jsc" ;;
        WebKit.framework/XPCServices/*.xpc/*) basename "$(dirname "${binary}")" .xpc ;;
        WebKit.framework/Daemons/*)           basename "${binary}" ;;
        *) echo "" ;;
    esac
}

sign_macho() {
    local binary="$1"
    local rel="${binary#${PAYLOAD_DIR}/}"
    # Also handle binaries living under USRLIB_DIR.
    if [[ "${rel}" == "${binary}" ]]; then
        rel="${binary#${DEB_ROOT}/}"
    fi

    local entitlements_script product_name entitlements_path
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
done < <(find "${DEB_ROOT}" -type f -print0)

# ══════════════════════════════════════════════════════════════
# STEP 6 — Generate DEBIAN metadata
# ══════════════════════════════════════════════════════════════
log_step "Generating DEBIAN control files..."
DEBIAN_DIR="${DEB_ROOT}/DEBIAN"
mkdir -p "${DEBIAN_DIR}"

# Calculate installed size (in KiB).
INSTALLED_SIZE="$(du -sk "${DEB_ROOT}" | awk '{print $1}')"

cat > "${DEBIAN_DIR}/control" <<CTRL
Package: ${PACKAGE_ID}
Name: ${PACKAGE_NAME}
Version: ${PACKAGE_VERSION}
Architecture: ${PACKAGE_ARCH}
Maintainer: ${PACKAGE_AUTHOR}
Depends: firmware (>= 14.0)
Section: System
Priority: optional
Installed-Size: ${INSTALLED_SIZE}
Description: ${PACKAGE_DESCRIPTION}
CTRL

# ── postinst: ensure proper permissions & refresh caches ─────
cat > "${DEBIAN_DIR}/postinst" <<'POSTINST'
#!/bin/sh
set -e

FRAMEWORKS_DIR="/Library/Frameworks"
USRLIB_DIR="/usr/lib"
if [ -d "/var/jb/Library/Frameworks" ]; then
    FRAMEWORKS_DIR="/var/jb/Library/Frameworks"
    USRLIB_DIR="/var/jb/usr/lib"
fi

# Fix ownership (root:wheel).
chown -R 0:0 "${FRAMEWORKS_DIR}/WebKit.framework" 2>/dev/null || true
chown -R 0:0 "${FRAMEWORKS_DIR}/WebCore.framework" 2>/dev/null || true
chown -R 0:0 "${FRAMEWORKS_DIR}/WebKitLegacy.framework" 2>/dev/null || true
chown -R 0:0 "${FRAMEWORKS_DIR}/JavaScriptCore.framework" 2>/dev/null || true

# Trigger uicache refresh if available.
if command -v uicache >/dev/null 2>&1; then
    uicache --all 2>/dev/null || true
fi

exit 0
POSTINST
chmod 0755 "${DEBIAN_DIR}/postinst"

# ── prerm: inform user; no automatic rollback ────────────────
cat > "${DEBIAN_DIR}/prerm" <<'PRERM'
#!/bin/sh
# Uninstalling custom WebKit.  The stock system dyld shared cache
# will resume providing the original frameworks automatically.
exit 0
PRERM
chmod 0755 "${DEBIAN_DIR}/prerm"

# ── Ensure directory permissions are correct for dpkg-deb ────
find "${DEB_ROOT}" -type d -exec chmod 0755 {} +
# Binaries need 0755; other files 0644.
find "${DEB_ROOT}" -type f -print0 | while IFS= read -r -d '' f; do
    if /usr/bin/file -b "${f}" | grep -q 'Mach-O'; then
        chmod 0755 "${f}"
    else
        chmod 0644 "${f}"
    fi
done
# Maintainer scripts must be executable.
chmod 0755 "${DEBIAN_DIR}/postinst" "${DEBIAN_DIR}/prerm"

# ══════════════════════════════════════════════════════════════
# STEP 7 — Build .deb
# ══════════════════════════════════════════════════════════════
log_step "Building .deb package..."
mkdir -p "$(dirname "${OUTPUT_DEB}")"

# Use DEBIAN_BINARY env to silence dpkg-deb warnings on macOS.
COPYFILE_DISABLE=1 dpkg-deb --build --root-owner-group -Zgzip "${DEB_ROOT}" "${OUTPUT_DEB}" 2>&1 \
    | grep -v 'root-owner-group' || true

if [[ ! -f "${OUTPUT_DEB}" ]]; then
    log_error "dpkg-deb failed to produce: ${OUTPUT_DEB}"
    exit 1
fi

DEB_SIZE="$(du -sh "${OUTPUT_DEB}" | awk '{print $1}')"
log_success "Done.  Package created (${DEB_SIZE}): ${OUTPUT_DEB}"
log_info "Install on device:  dpkg -i $(basename "${OUTPUT_DEB}")"
log_info "Remove from device: dpkg -r ${PACKAGE_ID}"
