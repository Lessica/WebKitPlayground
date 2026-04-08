#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"

DEFAULT_BUILD_DIR="${ROOT_DIR}/WebKit/WebKitBuild/Release-iphoneos"
if [[ ! -d "${DEFAULT_BUILD_DIR}" ]]; then
    DEFAULT_BUILD_DIR="${ROOT_DIR}/WebKitBuild/Release-iphoneos"
fi
DEFAULT_STOCK_JSC="${ROOT_DIR}/samples/device-dsc-split/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"

BUILD_DIR="${DEFAULT_BUILD_DIR}"
PACKAGE_PATH=""
STOCK_JSC="${DEFAULT_STOCK_JSC}"
WARN_ONLY=0
REPORT_PATH=""
BUILD_DIR_SET=0
PACKAGE_SET=0

typeset -a TARGET_BINARIES=(
    "WebKit.framework/WebKit"
    "WebCore.framework/WebCore"
    "WebKitLegacy.framework/WebKitLegacy"
)

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

print_report() {
    local report_file="$1"
    if [[ ! -t 1 ]]; then
        cat "${report_file}"
        return
    fi

    while IFS= read -r line; do
        case "${line}" in
            "== "*)
                printf "%s%s%s\n" "${C_BOLD}${C_CYAN}" "${line}" "${C_RESET}"
                ;;
            "Hints:")
                printf "%s%s%s\n" "${C_BOLD}${C_YELLOW}" "${line}" "${C_RESET}"
                ;;
            "Result: PASS"*)
                printf "%s%s%s\n" "${C_BOLD}${C_GREEN}" "${line}" "${C_RESET}"
                ;;
            "Result: FAILED"*)
                printf "%s%s%s\n" "${C_BOLD}${C_RED}" "${line}" "${C_RESET}"
                ;;
            "Skip: "*|"Warning: "*)
                printf "%s%s%s\n" "${C_YELLOW}" "${line}" "${C_RESET}"
                ;;
            "Error: "*)
                printf "%s%s%s\n" "${C_RED}" "${line}" "${C_RESET}"
                ;;
            "[["*"]")
                printf "%s%s%s\n" "${C_CYAN}" "${line}" "${C_RESET}"
                ;;
            *)
                print -- "${line}"
                ;;
        esac
    done < "${report_file}"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--build-dir <dir> | --package <tar.gz>]
          [--stock-jsc <path>] [--binary <relative-path>] [--report <path>]
          [--warn-only]

Default build dir:
  ${DEFAULT_BUILD_DIR}

Default stock JSC:
  ${DEFAULT_STOCK_JSC}

Notes:
  - --binary can be passed multiple times. When used, it replaces defaults.
  - Missing symbols cause exit 2 unless --warn-only is set.
EOF
}

binary_set_by_user=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)
            BUILD_DIR="${2:?missing value for --build-dir}"
            BUILD_DIR_SET=1
            shift 2
            ;;
        --package)
            PACKAGE_PATH="${2:?missing value for --package}"
            PACKAGE_SET=1
            shift 2
            ;;
        --stock-jsc)
            STOCK_JSC="${2:?missing value for --stock-jsc}"
            shift 2
            ;;
        --binary)
            if [[ "${binary_set_by_user}" == "0" ]]; then
                TARGET_BINARIES=()
                binary_set_by_user=1
            fi
            TARGET_BINARIES+=("${2:?missing value for --binary}")
            shift 2
            ;;
        --report)
            REPORT_PATH="${2:?missing value for --report}"
            shift 2
            ;;
        --warn-only)
            WARN_ONLY=1
            shift
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

if [[ "${BUILD_DIR_SET}" == "1" && "${PACKAGE_SET}" == "1" ]]; then
    echo "Use either --build-dir or --package, not both." >&2
    exit 1
fi

if [[ -z "${PACKAGE_PATH}" && ! -d "${BUILD_DIR}" ]]; then
    echo "Build directory does not exist: ${BUILD_DIR}" >&2
    exit 1
fi

if [[ -n "${PACKAGE_PATH}" && ! -f "${PACKAGE_PATH}" ]]; then
    echo "Package file does not exist: ${PACKAGE_PATH}" >&2
    exit 1
fi

if [[ ! -f "${STOCK_JSC}" ]]; then
    echo "Stock JSC binary does not exist: ${STOCK_JSC}" >&2
    exit 1
fi

if [[ "${#TARGET_BINARIES[@]}" -eq 0 ]]; then
    echo "No target binaries to check. Provide --binary at least once." >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found in PATH." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "/tmp/.check-jsc-abi.XXXXXX")"
ROOT_DIR="${BUILD_DIR}"
REPORT_TARGET="${REPORT_PATH}"
if [[ -z "${REPORT_TARGET}" ]]; then
    REPORT_TARGET="${TMP_DIR}/report.txt"
fi

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if [[ -n "${PACKAGE_PATH}" ]]; then
    ROOT_DIR="${TMP_DIR}/extracted/payload"
    mkdir -p "${ROOT_DIR}"
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -xzf "${PACKAGE_PATH}" -C "${TMP_DIR}/extracted"
    if [[ ! -d "${ROOT_DIR}" ]]; then
        echo "Invalid package: payload directory missing." >&2
        exit 1
    fi
fi

exports_file="${TMP_DIR}/stock_jsc_exports.txt"
xcrun nm -gU "${STOCK_JSC}" | awk '{print $3}' | sort -u > "${exports_file}"

missing_total=0
checked_total=0
missing_bins=0
missing_all_file="${TMP_DIR}/missing_all.txt"
: > "${missing_all_file}"

{
    echo "== JSC ABI Compatibility Report =="
    echo "Root: ${ROOT_DIR}"
    if [[ -n "${PACKAGE_PATH}" ]]; then
        echo "Package: ${PACKAGE_PATH}"
    fi
    echo "Stock JSC: ${STOCK_JSC}"
    echo
} > "${REPORT_TARGET}"

for rel in "${TARGET_BINARIES[@]}"; do
    bin="${ROOT_DIR}/${rel}"
    if [[ ! -f "${bin}" ]]; then
        echo "Skip: missing binary ${bin}" | tee -a "${REPORT_TARGET}" >&2
        continue
    fi

    checked_total=$((checked_total + 1))
    safe_rel="${rel//\//_}"
    undef_file="${TMP_DIR}/${safe_rel}.undef.txt"
    missing_file="${TMP_DIR}/${safe_rel}.missing.txt"

    xcrun nm -gm "${bin}" | awk '/\(from JavaScriptCore\)/ {print $3}' | sort -u > "${undef_file}"
    comm -23 "${undef_file}" "${exports_file}" > "${missing_file}"

    undef_count="$(wc -l < "${undef_file}" | tr -d ' ')"
    missing_count="$(wc -l < "${missing_file}" | tr -d ' ')"
    missing_total=$((missing_total + missing_count))

    {
        echo "[${rel}]"
        echo "  Undefined(from JavaScriptCore): ${undef_count}"
        echo "  Missing in stock JSC: ${missing_count}"
    } >> "${REPORT_TARGET}"

    if [[ "${missing_count}" -gt 0 ]]; then
        missing_bins=$((missing_bins + 1))
        sed "s/^/    - /" "${missing_file}" >> "${REPORT_TARGET}"
        cat "${missing_file}" >> "${missing_all_file}"
    fi

    echo >> "${REPORT_TARGET}"
done

if [[ "${checked_total}" -eq 0 ]]; then
    echo "No target binaries were checked." >&2
    cat "${REPORT_TARGET}"
    exit 1
fi

sort -u -o "${missing_all_file}" "${missing_all_file}" || true

if [[ -s "${missing_all_file}" ]]; then
    {
        echo "Hints:"
        if rg -q "DisallowGC19s_scopeReentryCountE|CatchScope|ThrowScope|DoesGCCheck|reportBadTag" "${missing_all_file}"; then
            echo "  - ASSERT/Debug-only symbols detected; avoid mixing Debug WebKit with stock Release JSC."
        fi
        if rg -q "Thread5s_keyE" "${missing_all_file}"; then
            echo "  - FAST_TLS mismatch suspected; build-time HAVE(FAST_TLS) path differs from stock JSC ABI."
        fi
        if rg -q "PtrTagE[0-9]+E" "${missing_all_file}"; then
            echo "  - PtrTag discriminator mismatch detected; private C++ mangling differs across builds."
        fi
        echo
    } >> "${REPORT_TARGET}"
fi

print_report "${REPORT_TARGET}"

if [[ "${missing_total}" -gt 0 ]]; then
    printf "%sResult: FAILED (%d missing symbols across %d binaries).%s\n" "${C_BOLD}${C_RED}" "${missing_total}" "${missing_bins}" "${C_RESET}" >&2
    if [[ "${WARN_ONLY}" == "1" ]]; then
        exit 0
    fi
    exit 2
fi

printf "%sResult: PASS (no missing symbols).%s\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
