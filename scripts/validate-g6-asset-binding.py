#!/usr/bin/env python3
"""Mechanical G6 collapsed-asset binding checks for figma-ui-gates."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ALLOWED_RUNTIME_CLASSES = frozenset(
    {
        "UIImageView",
        "UIButton",
        "UIControl",
        "vvcatCustomButtom",
    }
)

ASSET_REF_RE = re.compile(
    r'(UIImage\s*\(\s*named:\s*["\']{name}["\']'
    r'|Image\s*\(\s*["\']{name}["\']'
    r'|ImageResource\s*\(\s*name:\s*["\']{name}["\']'
    r'|["\']{name}["\'])',
    re.IGNORECASE,
)

DRAW_OVERRIDE_RE = re.compile(r"override\s+func\s+draw\s*\(")
ANCHOR_RE = re.compile(r'accessibilityIdentifier\s*=\s*["\']([^"\']+)["\']')
CUSTOM_VIEW_RE = re.compile(r"(?:final\s+)?(?:private\s+)?class\s+(\w+)\s*:\s*UIView\b")


def figma_id_to_anchor(figma_id: str) -> str:
    base = figma_id.split("-", 1)[0].strip()
    sanitized = []
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    for ch in base:
        sanitized.append(ch if ch in allowed else "_")
    return "figma." + "".join(sanitized)


def load_g6(workspace: Path) -> dict:
    path = workspace / "gates" / "G6-assets.json"
    if not path.is_file():
        raise ValueError(f"Missing G6 artifact: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def collect_swift_files(source_root: Path) -> list[Path]:
    ignored = {
        ".build",
        "build",
        "DerivedData",
        "Pods",
        ".dev-flow",
    }
    files: list[Path] = []
    for path in source_root.rglob("*.swift"):
        if any(part in ignored for part in path.parts):
            continue
        files.append(path)
    return files


def source_references_asset(swift_files: list[Path], asset_name: str) -> bool:
    pattern = ASSET_REF_RE.pattern.format(name=re.escape(asset_name))
    compiled = re.compile(pattern)
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if compiled.search(text):
            return True
    return False


def custom_draw_classes(swift_files: list[Path]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if not DRAW_OVERRIDE_RE.search(text):
            continue
        for match in CUSTOM_VIEW_RE.finditer(text):
            result[match.group(1)] = path
    return result


def anchors_in_source(swift_files: list[Path]) -> dict[str, list[Path]]:
    mapping: dict[str, list[Path]] = {}
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in ANCHOR_RE.finditer(text):
            mapping.setdefault(match.group(1), []).append(path)
    return mapping


def find_runtime_detail(runtime_dir: Path, anchor: str) -> dict | None:
    if not runtime_dir.is_dir():
        return None
    best: dict | None = None
    for path in sorted(runtime_dir.glob("*runtime-detail.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if payload.get("anchor") == anchor:
            best = payload
    return best


def runtime_class_ok(runtime_detail: dict | None) -> tuple[bool, str]:
    if runtime_detail is None:
        return False, "missing runtime detail JSON for collapsed parent anchor"
    node = runtime_detail.get("node") or {}
    class_name = node.get("className") or runtime_detail.get("className")
    if not class_name:
        matches = runtime_detail.get("matches") or []
        if matches:
            class_name = matches[0].get("className")
    if not class_name:
        return False, "runtime detail lacks className"
    if class_name in ALLOWED_RUNTIME_CLASSES:
        return True, class_name
    if class_name.endswith("ImageView") or class_name.endswith("Button"):
        return True, class_name
    return False, class_name


def expand_local_assets(asset_row: dict) -> list[str]:
    names: list[str] = []
    single = asset_row.get("local_asset")
    if isinstance(single, str) and single.strip():
        names.append(single.strip())
    plural = asset_row.get("local_assets")
    if isinstance(plural, str) and plural.strip():
        token = plural.strip()
        match = re.match(r"^(.+)\.\.(.+)$", token)
        if match:
            prefix, suffix = match.groups()
            start_match = re.search(r"(\d+)$", prefix)
            end_match = re.search(r"(\d+)$", suffix)
            if start_match and end_match:
                stem = prefix[: start_match.start()]
                start = int(start_match.group(1))
                end = int(end_match.group(1))
                width = len(start_match.group(1))
                for index in range(start, end + 1):
                    names.append(f"{stem}{index:0{width}d}")
            else:
                names.append(token)
        else:
            names.append(token)
    if isinstance(plural, list):
        names.extend(str(item).strip() for item in plural if str(item).strip())
    return names


def validate(workspace: Path, source_root: Path) -> tuple[list[str], dict]:
    errors: list[str] = []
    g6 = load_g6(workspace)
    if g6.get("status") != "pass":
        errors.append("G6-assets.json status must be pass before binding validation")

    rules = g6.get("rules") or []
    for rule in rules:
        if isinstance(rule, str) and "may use exported assets" in rule.lower():
            errors.append(
                'G6 rules must not use permissive "may use exported assets"; '
                'use "must use exported assets" for collapsed units'
            )

    swift_files = collect_swift_files(source_root)
    draw_classes = custom_draw_classes(swift_files)
    anchor_files = anchors_in_source(swift_files)
    runtime_dir = workspace / "runtime"

    collapsed_rows = []
    for row in g6.get("assets") or []:
        if not isinstance(row, dict):
            errors.append("G6 assets entries must be objects")
            continue
        if row.get("collapse") is True:
            collapsed_rows.append(row)

    for row in collapsed_rows:
        figma_id = row.get("figma_id")
        name = row.get("name") or figma_id or "<unknown>"
        asset_names = expand_local_assets(row)
        if not asset_names:
            errors.append(f"{name}: collapse=true requires local_asset or local_assets")
            continue

        for asset_name in asset_names:
            if not source_references_asset(swift_files, asset_name):
                errors.append(
                    f"{name}: source does not reference exported asset '{asset_name}'"
                )

        if isinstance(figma_id, str) and figma_id.strip():
            anchor = figma_id_to_anchor(figma_id)
            runtime_detail = find_runtime_detail(runtime_dir, anchor)
            ok, detail = runtime_class_ok(runtime_detail)
            if not ok:
                errors.append(
                    f"{name}: collapsed parent anchor {anchor} runtime invalid ({detail})"
                )
            elif runtime_detail and not (runtime_detail.get("node") or {}).get("imageSize"):
                # UIImageView/UIButton should expose imageSize when using exported assets
                if detail == "UIImageView":
                    errors.append(
                        f"{name}: {anchor} is UIImageView but runtime lacks imageSize evidence"
                    )

            for path in anchor_files.get(anchor, []):
                text = path.read_text(encoding="utf-8", errors="replace")
                for class_name, class_path in draw_classes.items():
                    if class_name in text and DRAW_OVERRIDE_RE.search(
                        class_path.read_text(encoding="utf-8", errors="replace")
                    ):
                        errors.append(
                            f"{name}: anchor {anchor} binds custom draw view {class_name} "
                            f"in {path}; collapsed units must use exported assets"
                        )

            # Child instance anchors must not be the primary binding for collapsed parents
            if isinstance(figma_id, str):
                parent_token = figma_id.replace(":", "_")
                for bound_anchor, paths in anchor_files.items():
                    if bound_anchor == anchor:
                        continue
                    if parent_token in bound_anchor and bound_anchor.startswith("figma.I"):
                        for path in paths:
                            text = path.read_text(encoding="utf-8", errors="replace")
                            for class_name in draw_classes:
                                if class_name in text:
                                    errors.append(
                                        f"{name}: collapsed unit uses child anchor "
                                        f"{bound_anchor} with custom draw view {class_name} "
                                        f"in {path}; bind parent {anchor} with exported asset"
                                    )

    report = {
        "workspace": str(workspace),
        "source_root": str(source_root),
        "collapsed_count": len(collapsed_rows),
        "status": "pass" if not errors else "failed",
        "errors": errors,
    }
    return errors, report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate G6 collapsed asset binding")
    parser.add_argument("--workspace", required=True, help="Artifact workspace path")
    parser.add_argument("--source-root", required=True, help="Target project source root")
    parser.add_argument("--report", help="Optional JSON report output path")
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser().resolve()
    source_root = Path(args.source_root).expanduser().resolve()

    if not workspace.is_dir():
        print(f"workspace does not exist: {workspace}", file=sys.stderr)
        return 2
    if not source_root.is_dir():
        print(f"source_root does not exist: {source_root}", file=sys.stderr)
        return 2

    try:
        errors, report = validate(workspace, source_root)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.report:
        report_path = Path(args.report).expanduser().resolve()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if errors:
        for item in errors:
            print(item, file=sys.stderr)
        return 1

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
