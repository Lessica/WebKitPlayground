#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from scriptlib import latest_matching_file, repo_root_from_script


DEFAULT_SETTINGS = [
    "ENABLE_DFG_JIT=ENABLE_DFG_JIT",
    "ENABLE_FTL_JIT=ENABLE_FTL_JIT",
    "ENABLE_IOS_TOUCH_EVENTS=ENABLE_IOS_TOUCH_EVENTS",
    "ENABLE_JIT=ENABLE_JIT",
    "ENABLE_TOUCH_EVENTS=ENABLE_TOUCH_EVENTS",
]


def load_settings_file(path: Path) -> list[str]:
    settings: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        settings.append(line)
    return settings


def parse_settings(values: list[str]) -> list[str]:
    parsed: list[str] = []
    for line in values:
        if "=" not in line:
            raise SystemExit(f"Invalid setting (missing '='): {line}")
        key, value = line.split("=", 1)
        if not key:
            raise SystemExit(f"Invalid setting (empty key): {line}")
        parsed.append(f"{key}={value}")
    return parsed


def parse_args() -> argparse.Namespace:
    repo_root = repo_root_from_script(__file__)

    parser = argparse.ArgumentParser(
        description="Highlight suspicious self-referential feature flag values from a config-gap analysis snapshot.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=repo_root,
        help="Project root used for resolving default paths.",
    )
    parser.add_argument(
        "--analysis",
        type=Path,
        default=None,
        help="JSON file emitted by analyze_config_gaps.py.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output JSON path. Defaults to build_flag_anomaly_report.json next to --analysis.",
    )
    parser.add_argument(
        "--settings-file",
        type=Path,
        default=None,
        help="Optional text file containing KEY=VALUE lines to analyze.",
    )
    parser.add_argument(
        "--setting",
        action="append",
        default=[],
        help="Build setting in KEY=VALUE form. Can be passed multiple times.",
    )
    args = parser.parse_args()
    if args.analysis is None:
        args.analysis = latest_matching_file(args.repo_root / "samples", "abi-report-*/config_gap_analysis.json")
    if args.analysis is None:
        parser.error("Unable to infer --analysis. Pass it explicitly.")
    return args


def main() -> int:
    args = parse_args()
    if not args.analysis.is_file():
        raise SystemExit(f"Analysis file does not exist: {args.analysis}")

    settings = []
    if args.settings_file:
        if not args.settings_file.is_file():
            raise SystemExit(f"Settings file does not exist: {args.settings_file}")
        settings.extend(load_settings_file(args.settings_file))
    settings.extend(args.setting)
    if not settings:
        settings = list(DEFAULT_SETTINGS)
    settings = parse_settings(settings)

    cfg = json.loads(args.analysis.read_text(encoding="utf-8"))
    macro = cfg.get("macro_snapshot", {})
    anomalies = []
    for line in settings:
        k, v = line.split("=", 1)
        if k == v:
            anomalies.append(
                {
                    "setting": k,
                    "passed_value": v,
                    "issue": "self-referential value instead of concrete 0/1/YES/NO",
                }
            )

    result = {
        "inputs": {
            "config_gap_analysis": str(args.analysis),
        },
        "observed_macro_snapshot_in_built_headers": macro,
        "xcodebuild_commandline_feature_settings": settings,
        "anomalies": anomalies,
        "inference": [
            "Feature flags passed via current build-webkit invocation are not concretely resolved.",
            "This can explain why symbol gaps remain in feature-gated code paths.",
        ],
    }
    out_path = args.out or args.analysis.with_name("build_flag_anomaly_report.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
