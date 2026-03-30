#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Iterable


def repo_root_from_script(script_file: str | Path) -> Path:
    return Path(script_file).resolve().parent.parent


def first_existing_path(candidates: Iterable[Path]) -> Path | None:
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def default_release_build_root(repo_root: Path) -> Path | None:
    return first_existing_path(
        [
            repo_root / "WebKitBuild/Release-iphoneos",
            repo_root / "WebKit/WebKitBuild/Release-iphoneos",
            repo_root / "WebKit_iOS_16.4.1/WebKitBuild/Release-iphoneos",
        ]
    )


def default_split_root(repo_root: Path) -> Path:
    return repo_root / "samples" / "device-dsc-split"


def latest_matching_file(base_dir: Path, pattern: str) -> Path | None:
    matches = [path for path in base_dir.glob(pattern) if path.is_file()]
    if not matches:
        return None
    return max(matches, key=lambda path: path.stat().st_mtime)


def path_from_json_field(data: dict, key: str) -> Path | None:
    value = data.get(key)
    if not value:
        return None
    return Path(value)
