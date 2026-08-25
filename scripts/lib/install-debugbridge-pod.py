#!/usr/bin/env python3
"""Add LookDebugBridge pod to an iOS Podfile when missing."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

POD_LINE = (
    "  pod 'LookDebugBridge',\n"
    "      :git => 'https://github.com/Immmmmmortal1/LookDebugBridgeService.git',\n"
    "      :tag => '{tag}',\n"
    "      :configurations => ['Debug']"
)
MARKER = "# dev-flow: LookDebugBridge"
POD_DECL_RE = re.compile(r"pod\s+['\"]LookDebugBridge['\"]")


def find_podfile(project_root: Path) -> Path | None:
    direct = project_root / "Podfile"
    if direct.is_file():
        return direct
    for candidate in sorted(project_root.glob("*/Podfile")):
        if candidate.is_file():
            return candidate
    return None


def is_comment_line(line: str) -> bool:
    return line.lstrip().startswith("#")


def active_pod_decl_line(line: str) -> bool:
    code = line.split("#", 1)[0]
    return bool(POD_DECL_RE.search(code))


def pod_present(content: str) -> bool:
    return any(active_pod_decl_line(line) for line in content.splitlines())


def canonical_pod_block(tag: str) -> str:
    return f"{MARKER}\n{POD_LINE.format(tag=tag)}\n"


def find_existing_pod_blocks(lines: list[str]) -> list[tuple[int, int]]:
    ranges = []
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if not active_pod_decl_line(line):
            idx += 1
            continue

        start = idx
        if idx > 0 and lines[idx - 1].strip() == MARKER:
            start = idx - 1

        end = idx + 1
        while end < len(lines):
            stripped = lines[end].strip()
            if not stripped:
                break
            if re.match(r"^\s*(pod|target\s+['\"]|end\b)", lines[end]):
                break
            if re.match(r"^\s*:", lines[end]) or lines[end - 1].rstrip().endswith(","):
                end += 1
                continue
            break
        ranges.append((start, end))
        idx = end
    return ranges


def normalize_existing_pod(content: str, tag: str) -> tuple[str, bool]:
    lines = content.splitlines(keepends=True)
    ranges = find_existing_pod_blocks(lines)
    if not ranges:
        return content, False

    expected = canonical_pod_block(tag)
    changed = False
    keep_start = ranges[0][0]
    for start, end in reversed(ranges):
        original = "".join(lines[start:end])
        if start == keep_start:
            if original != expected:
                lines[start:end] = [expected]
                changed = True
        else:
            del lines[start:end]
            changed = True
    return "".join(lines), changed


def inject_pod(content: str, tag: str) -> tuple[str, bool]:
    if pod_present(content):
        return normalize_existing_pod(content, tag)

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

    lines.insert(insert_at, canonical_pod_block(tag))
    return "".join(lines), True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("project_root", type=Path)
    parser.add_argument("--tag", default="0.1.14")
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
