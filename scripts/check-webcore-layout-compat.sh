#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"

DEFAULT_BUILD_DIR="${ROOT_DIR}/WebKit/WebKitBuild/Release-iphoneos"
if [[ ! -d "${DEFAULT_BUILD_DIR}" ]]; then
    DEFAULT_BUILD_DIR="${ROOT_DIR}/WebKitBuild/Release-iphoneos"
fi
DEFAULT_STOCK_WEBCORE="${ROOT_DIR}/samples/device-dsc-split/System/Library/PrivateFrameworks/WebCore.framework/WebCore"
TARGET_RELATIVE="WebCore.framework/WebCore"
TARGET_SYMBOL="__ZNK7WebCore21ContentSecurityPolicy20didCreateWindowProxyERNS_13JSWindowProxyE:"

BUILD_DIR="${DEFAULT_BUILD_DIR}"
PACKAGE_PATH=""
STOCK_WEBCORE="${DEFAULT_STOCK_WEBCORE}"
REPORT_PATH=""
WARN_ONLY=0
BUILD_DIR_SET=0
PACKAGE_SET=0

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
            "Result: PASS"*)
                printf "%s%s%s\n" "${C_BOLD}${C_GREEN}" "${line}" "${C_RESET}"
                ;;
            "Result: FAILED"*)
                printf "%s%s%s\n" "${C_BOLD}${C_RED}" "${line}" "${C_RESET}"
                ;;
            "Reason: "*)
                printf "%s%s%s\n" "${C_YELLOW}" "${line}" "${C_RESET}"
                ;;
            "[Built offsets via x20]"|"[Stock offsets via x20]")
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
          [--stock-webcore <path>] [--report <path>] [--warn-only]

Default build dir:
  ${DEFAULT_BUILD_DIR}

Default stock WebCore:
  ${DEFAULT_STOCK_WEBCORE}

Notes:
  - Compares x20-relative field offsets used by:
    ContentSecurityPolicy::didCreateWindowProxy(JSWindowProxy&)
  - Mismatch implies JSGlobalObject/JSDOMGlobalObject layout drift.
EOF
}

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
        --stock-webcore)
            STOCK_WEBCORE="${2:?missing value for --stock-webcore}"
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

if [[ ! -f "${STOCK_WEBCORE}" ]]; then
    echo "Stock WebCore binary does not exist: ${STOCK_WEBCORE}" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found in PATH." >&2
    exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
    echo "rg not found in PATH." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "/tmp/.check-webcore-layout.XXXXXX")"
ROOT_DIR="${BUILD_DIR}"
REPORT_TARGET="${REPORT_PATH:-${TMP_DIR}/report.txt}"

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

BUILT_WEBCORE="${ROOT_DIR}/${TARGET_RELATIVE}"
if [[ ! -f "${BUILT_WEBCORE}" ]]; then
    echo "Built WebCore binary not found: ${BUILT_WEBCORE}" >&2
    exit 1
fi

extract_symbol_block() {
    local binary="$1"
    xcrun otool -arch arm64e -tvV "${binary}" \
        | awk -v target="${TARGET_SYMBOL}" '
            $0 ~ target { in_target = 1 }
            in_target {
                if (printed && $0 ~ /:$/ && $0 !~ /^[[:space:]]*[0-9a-fA-F]+[[:space:]]/)
                    exit
                print
                printed = 1
            }
        ' || true
}

extract_x20_offsets() {
    local binary="$1"
    local block
    block="$(extract_symbol_block "${binary}")"
    [[ -n "${block}" ]] || return 0
    print -- "${block}" \
        | rg -o '\[x20, #0x[0-9a-fA-F]+\]' \
        | sed -E 's/.*#(0x[0-9a-fA-F]+).*/\1/' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u || true
}

extract_x20_lines() {
    local binary="$1"
    local block
    block="$(extract_symbol_block "${binary}")"
    [[ -n "${block}" ]] || return 0
    print -- "${block}" \
        | rg '\[x20, #0x[0-9a-fA-F]+\]' || true
}

built_offsets_file="${TMP_DIR}/built_offsets.txt"
stock_offsets_file="${TMP_DIR}/stock_offsets.txt"

extract_x20_offsets "${BUILT_WEBCORE}" > "${built_offsets_file}"
extract_x20_offsets "${STOCK_WEBCORE}" > "${stock_offsets_file}"

built_count="$(wc -l < "${built_offsets_file}" | tr -d ' ')"
stock_count="$(wc -l < "${stock_offsets_file}" | tr -d ' ')"

{
    echo "== WebCore Mixed-Mode Layout Compatibility Report =="
    echo "Root: ${ROOT_DIR}"
    if [[ -n "${PACKAGE_PATH}" ]]; then
        echo "Package: ${PACKAGE_PATH}"
    fi
    echo "Built WebCore: ${BUILT_WEBCORE}"
    echo "Stock WebCore: ${STOCK_WEBCORE}"
    echo "Function: WebCore::ContentSecurityPolicy::didCreateWindowProxy(WebCore::JSWindowProxy&) const"
    echo
    echo "[Built offsets via x20]"
    if [[ "${built_count}" -gt 0 ]]; then
        sed 's/^/  - /' "${built_offsets_file}"
    else
        echo "  (none)"
    fi
    echo
    echo "[Stock offsets via x20]"
    if [[ "${stock_count}" -gt 0 ]]; then
        sed 's/^/  - /' "${stock_offsets_file}"
    else
        echo "  (none)"
    fi
    echo
} > "${REPORT_TARGET}"

fail=0

if [[ "${built_count}" -eq 0 || "${stock_count}" -eq 0 ]]; then
    fail=1
    {
        echo "Result: FAILED"
        echo "Reason: unable to extract comparison offsets from disassembly."
    } >> "${REPORT_TARGET}"
else
    only_in_built="${TMP_DIR}/only_in_built.txt"
    only_in_stock="${TMP_DIR}/only_in_stock.txt"
    comm -23 "${built_offsets_file}" "${stock_offsets_file}" > "${only_in_built}"
    comm -13 "${built_offsets_file}" "${stock_offsets_file}" > "${only_in_stock}"

    if [[ -s "${only_in_built}" || -s "${only_in_stock}" ]]; then
        fail=1
        {
            echo "Result: FAILED"
            echo "Reason: x20 field offsets differ between built and stock WebCore."
            if [[ -s "${only_in_built}" ]]; then
                echo
                echo "Only in built:"
                sed 's/^/  - /' "${only_in_built}"
            fi
            if [[ -s "${only_in_stock}" ]]; then
                echo
                echo "Only in stock:"
                sed 's/^/  - /' "${only_in_stock}"
            fi
            echo
            echo "Built instruction lines:"
            extract_x20_lines "${BUILT_WEBCORE}" | sed 's/^/  /'
            echo
            echo "Stock instruction lines:"
            extract_x20_lines "${STOCK_WEBCORE}" | sed 's/^/  /'
        } >> "${REPORT_TARGET}"
    else
        {
            echo "Result: PASS"
            echo "x20 field offsets match stock WebCore for the checked function."
        } >> "${REPORT_TARGET}"
    fi
fi

print_report "${REPORT_TARGET}"

if [[ "${fail}" -eq 1 ]]; then
    if [[ "${WARN_ONLY}" == "1" ]]; then
        exit 0
    fi
    exit 2
fi
