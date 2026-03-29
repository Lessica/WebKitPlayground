#!/usr/bin/env python3
import json
import re
import subprocess
from pathlib import Path


ROOT = Path("/Volumes/OPTANE/WebKitPlayground")
REPORT = ROOT / "samples/abi-report-20260328/full_report.json"
BUILT = ROOT / "WebKit/WebKitBuild/Release-iphoneos"
SPLIT = ROOT / "samples/device-dsc-split"
OUT = ROOT / "samples/abi-report-20260328/config_gap_analysis.json"


def run_nm_symbols(binary: Path) -> set[str]:
    p = subprocess.run(
        ["xcrun", "nm", "-gjU", str(binary)],
        capture_output=True,
        text=True,
        check=True,
    )
    return {line.strip() for line in p.stdout.splitlines() if line.strip()}


def classify(sym: str) -> str:
    if "WebEventRegion" in sym or "touchEvent" in sym or "getTouchRects" in sym:
        return "IOS_TOUCH_EVENTS path"
    if "JITOperationList" in sym or "jitOperationListE" in sym or "populateJITOperations" in sym:
        return "JIT_OPERATION_VALIDATION / JIT_OPERATION_DISASSEMBLY path"
    if "VTRestrictVideoDecoders" in sym or "createAV1VTBDecoder" in sym:
        return "VideoToolbox/AV1 related path"
    if "SignpostLogHandle" in sym:
        return "WTF signpost / os_signpost path"
    return "Unclassified"


def read_macro(name: str, text: str) -> str | None:
    m = re.search(rf"#define\s+{re.escape(name)}\s+([0-9A-Za-z_]+)", text)
    return m.group(1) if m else None


def main() -> None:
    report = json.loads(REPORT.read_text())
    missing_wc = report["providers"]["WebCore"]["missing_required_symbols"]
    missing_jsc = report["providers"]["JavaScriptCore"]["missing_required_symbols"]
    missing = {"WebCore": missing_wc, "JavaScriptCore": missing_jsc}

    bins = {
        "built_webcore": BUILT / "WebCore.framework/WebCore",
        "stock_webcore": SPLIT / "System/Library/PrivateFrameworks/WebCore.framework/WebCore",
        "built_jsc": BUILT / "JavaScriptCore.framework/JavaScriptCore",
        "stock_jsc": SPLIT / "System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
    }
    symtab = {k: run_nm_symbols(v) for k, v in bins.items()}

    platform_enable = (BUILT / "usr/local/include/wtf/PlatformEnable.h").read_text()
    platform_use = (BUILT / "usr/local/include/wtf/PlatformUse.h").read_text()
    macros = {
        "ENABLE_IOS_TOUCH_EVENTS": read_macro("ENABLE_IOS_TOUCH_EVENTS", platform_enable),
        "ENABLE_JIT_OPERATION_VALIDATION": read_macro("ENABLE_JIT_OPERATION_VALIDATION", platform_enable),
        "ENABLE_JIT_OPERATION_DISASSEMBLY": read_macro("ENABLE_JIT_OPERATION_DISASSEMBLY", platform_enable),
        "USE_APPLE_INTERNAL_SDK": read_macro("USE_APPLE_INTERNAL_SDK", platform_use),
    }

    details = []
    for provider, syms in missing.items():
        for sym in syms:
            if provider == "WebCore":
                built_has = sym in symtab["built_webcore"]
                stock_has = sym in symtab["stock_webcore"]
            else:
                built_has = sym in symtab["built_jsc"]
                stock_has = sym in symtab["stock_jsc"]
            details.append(
                {
                    "provider": provider,
                    "symbol": sym,
                    "built_has": built_has,
                    "stock_has": stock_has,
                    "category": classify(sym),
                }
            )

    grouped = {}
    for item in details:
        grouped.setdefault(item["category"], []).append(item)

    out = {
        "inputs": {
            "abi_report": str(REPORT),
            "built_root": str(BUILT),
            "split_root": str(SPLIT),
        },
        "macro_snapshot": macros,
        "summary": {
            "total_missing_symbols": len(details),
            "by_category": {k: len(v) for k, v in grouped.items()},
        },
        "details": details,
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2))
    print(str(OUT))


if __name__ == "__main__":
    main()
