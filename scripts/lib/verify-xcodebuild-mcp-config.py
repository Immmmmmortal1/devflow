#!/usr/bin/env python3
"""Verify XcodeBuildMCP is present in MCP client config with dev-flow required workflows."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REQUIRED_WORKFLOWS = frozenset({"session-management", "project-discovery", "device"})
SERVER_KEY = "XcodeBuildMCP"


def parse_workflows(raw: str) -> set[str]:
    return {part.strip() for part in raw.split(",") if part.strip()}


def workflows_from_project_yaml(project_root: Path | None) -> set[str] | None:
    if project_root is None:
        return None
    config_path = project_root / ".xcodebuildmcp" / "config.yaml"
    if not config_path.is_file():
        return None
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:
        text = config_path.read_text(encoding="utf-8")
        workflows: set[str] = set()
        in_workflows = False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("enabledWorkflows:"):
                inline = stripped.split(":", 1)[1].strip()
                if inline.startswith("["):
                    workflows.update(parse_workflows(inline.strip("[]").replace('"', "").replace("'", "")))
                in_workflows = inline == "" or inline == "["
                continue
            if in_workflows and stripped.startswith("- "):
                workflows.add(stripped[2:].strip().strip('"').strip("'"))
                continue
            if in_workflows and stripped and not stripped.startswith("#"):
                in_workflows = False
        return workflows or None

    payload = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
    enabled = payload.get("enabledWorkflows") or []
    if isinstance(enabled, list):
        return {str(item).strip() for item in enabled if str(item).strip()}
    return None


def inspect_cursor(config_path: Path) -> tuple[bool, set[str], str]:
    if not config_path.is_file():
        return False, set(), f"missing config: {config_path}"
    data = json.loads(config_path.read_text(encoding="utf-8"))
    entry = (data.get("mcpServers") or {}).get(SERVER_KEY)
    if not entry:
        return False, set(), f"{SERVER_KEY} not configured in {config_path}"
    env = entry.get("env") or {}
    workflows = parse_workflows(str(env.get("XCODEBUILDMCP_ENABLED_WORKFLOWS", "")))
    return True, workflows, str(config_path)


def inspect_codex(config_path: Path) -> tuple[bool, set[str], str]:
    if not config_path.is_file():
        return False, set(), f"missing config: {config_path}"
    import tomllib

    data = tomllib.loads(config_path.read_text(encoding="utf-8"))
    entry = (data.get("mcp_servers") or {}).get(SERVER_KEY)
    if not entry:
        return False, set(), f"{SERVER_KEY} not configured in {config_path}"
    env = entry.get("env") or {}
    workflows = parse_workflows(str(env.get("XCODEBUILDMCP_ENABLED_WORKFLOWS", "")))
    return True, workflows, str(config_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("cursor", "codex", "auto"), default="auto")
    parser.add_argument("--config-path")
    parser.add_argument("--project-root")
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser() if args.project_root else None
    project_workflows = workflows_from_project_yaml(project_root)

    candidates: list[tuple[str, Path]] = []
    if args.config_path:
        platform = args.platform if args.platform != "auto" else "codex"
        candidates.append((platform, Path(args.config_path).expanduser()))
    elif args.platform == "cursor":
        candidates.append(("cursor", Path.home() / ".cursor" / "mcp.json"))
    elif args.platform == "codex":
        codex_home = Path.home() / ".codex"
        candidates.append(("codex", codex_home / "config.toml"))
    else:
        candidates.append(("cursor", Path.home() / ".cursor" / "mcp.json"))
        candidates.append(("codex", Path.home() / ".codex" / "config.toml"))

    present = False
    # 每个平台的 workflows 独立记录，禁止跨平台合并（实际运行的 MCP host 只用一个配置）
    platform_workflows: dict[str, set[str]] = {}
    details: list[str] = []
    for platform, config_path in candidates:
        if platform == "cursor":
            ok, found, detail = inspect_cursor(config_path)
        else:
            ok, found, detail = inspect_codex(config_path)
        details.append(detail)
        if ok:
            present = True
            platform_workflows[platform] = found

    # 项目级配置是辅助补充，只叠加到每个已配置的平台，不参与跨平台合并
    if project_workflows:
        for platform in list(platform_workflows):
            platform_workflows[platform] |= project_workflows

    if not present:
        print("status=missing")
        for detail in details:
            print(f"detail={detail}")
        return 1

    # 任一平台单独满足全部必需 workflow 才算通过
    best = max(platform_workflows.values(), key=len, default=set())
    missing = sorted(REQUIRED_WORKFLOWS - best)
    if missing:
        print("status=incomplete")
        print(f"workflows={','.join(sorted(best))}")
        print(f"missing={','.join(missing)}")
        return 1

    print("status=ok")
    print(f"workflows={','.join(sorted(best))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
