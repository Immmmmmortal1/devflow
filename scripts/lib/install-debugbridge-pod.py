#!/usr/bin/env python3
"""Add LookDebugBridge pod to an iOS Podfile when missing."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

POD_LINE = (
    "  pod 'LookDebugBridge',\n"
    "      :git => 'https://github.com/Immmmmmortal1/UI-dbugbridge-mcp.git',\n"
    "      :tag => '{tag}',\n"
    "      :configurations => ['Debug']"
)
MARKER = "# dev-flow: LookDebugBridge"


def find_podfile(project_root: Path) -> Path | None:
    direct = project_root / "Podfile"
    if direct.is_file():
        return direct
    for candidate in sorted(project_root.glob("*/Podfile")):
        if candidate.is_file():
            return candidate
    return None


def pod_present(content: str) -> bool:
    return bool(re.search(r"pod\s+['\"]LookDebugBridge['\"]", content))


def inject_pod(content: str, tag: str) -> tuple[str, bool]:
    if pod_present(content):
        return content, False

    lines = content.splitlines(keepends=True)
    target_idx = None
    for idx, line in enumerate(lines):
        if re.match(r"^\s*target\s+['\"]", line):
            target_idx = idx
            break

    if target_idx is None:
        raise RuntimeError("Podfile has no target block; add LookDebugBridge manually.")

    insert_at = target_idx + 1
    while insert_at < len(lines) and re.match(r"^\s*(use_frameworks!|#|platform\s)", lines[insert_at]):
        insert_at += 1

    block = f"{MARKER}\n{POD_LINE.format(tag=tag)}\n"
    lines.insert(insert_at, block)
    return "".join(lines), True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("project_root", type=Path)
    parser.add_argument("--tag", default="0.1.7")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    podfile = find_podfile(project_root)
    if podfile is None:
        print("no_podfile")
        return 0

    original = podfile.read_text(encoding="utf-8")
    updated, changed = inject_pod(original, args.tag)
    if changed and not args.dry_run:
        podfile.write_text(updated, encoding="utf-8")

    print(f"podfile={podfile}")
    print(f"changed={'yes' if changed else 'no'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error={exc}", file=sys.stderr)
        raise SystemExit(1) from exc
