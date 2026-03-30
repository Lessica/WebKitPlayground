#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

from scriptlib import (
    default_release_build_root,
    default_split_root,
    latest_matching_file,
    path_from_json_field,
    repo_root_from_script,
)


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


def parse_args() -> argparse.Namespace:
    repo_root = repo_root_from_script(__file__)

    parser = argparse.ArgumentParser(
        description="Analyze provider symbol gaps and map them to likely feature/config categories.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=repo_root,
        help="Project root used for resolving default paths.",
    )
    parser.add_argument(
        "--abi-report",
        type=Path,
        default=None,
        help="JSON report emitted by check_dsc_abi.py.",
    )
    parser.add_argument(
        "--built-root",
        type=Path,
        default=None,
        help="WebKit build root. Defaults to the report's build_root or an auto-detected Release-iphoneos directory.",
    )
    parser.add_argument(
        "--split-root",
        type=Path,
        default=None,
        help="Root of the split DSC filesystem tree. Defaults to the report's split_root or <repo-root>/samples/device-dsc-split.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output JSON path. Defaults to config_gap_analysis.json next to --abi-report.",
    )
    args = parser.parse_args()
    if args.abi_report is None:
        args.abi_report = latest_matching_file(args.repo_root / "samples", "abi-report-*/full_report.json")
    if args.abi_report is None:
        parser.error("Unable to infer --abi-report. Pass it explicitly.")
    return args


def main() -> int:
    args = parse_args()

    report = json.loads(args.abi_report.read_text(encoding="utf-8"))
    built_root = args.built_root or path_from_json_field(report, "build_root") or default_release_build_root(args.repo_root)
    split_root = args.split_root or path_from_json_field(report, "split_root") or default_split_root(args.repo_root)
    out_path = args.out or args.abi_report.with_name("config_gap_analysis.json")

    if built_root is None:
        raise SystemExit("Unable to infer --built-root. Pass it explicitly.")
    if not args.abi_report.is_file():
        raise SystemExit(f"ABI report does not exist: {args.abi_report}")
    if not built_root.is_dir():
        raise SystemExit(f"Build root does not exist: {built_root}")
    if not split_root.is_dir():
        raise SystemExit(f"Split root does not exist: {split_root}")

    missing_wc = report["providers"]["WebCore"]["missing_required_symbols"]
    missing_jsc = report["providers"]["JavaScriptCore"]["missing_required_symbols"]
    missing = {"WebCore": missing_wc, "JavaScriptCore": missing_jsc}

    bins = {
        "built_webcore": built_root / "WebCore.framework/WebCore",
        "stock_webcore": split_root / "System/Library/PrivateFrameworks/WebCore.framework/WebCore",
        "built_jsc": built_root / "JavaScriptCore.framework/JavaScriptCore",
        "stock_jsc": split_root / "System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
    }
    symtab = {k: run_nm_symbols(v) for k, v in bins.items()}

    platform_enable = (built_root / "usr/local/include/wtf/PlatformEnable.h").read_text(encoding="utf-8")
    platform_use = (built_root / "usr/local/include/wtf/PlatformUse.h").read_text(encoding="utf-8")
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
            "abi_report": str(args.abi_report),
            "built_root": str(built_root),
            "split_root": str(split_root),
        },
        "macro_snapshot": macros,
        "summary": {
            "total_missing_symbols": len(details),
            "by_category": {k: len(v) for k, v in grouped.items()},
        },
        "details": details,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
