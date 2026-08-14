#!/usr/bin/env python3
"""Merge XcodeBuildMCP server config for Cursor (JSON) or Codex (TOML)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from merge_mcp_codex_common import append_mcp_block, strip_mcp_server_sections

SERVER_KEY = "XcodeBuildMCP"
DEFAULT_WORKFLOWS = "session-management,project-discovery,device"
DEFAULT_TOOL_TIMEOUT_SEC = 600


def merge_cursor(config_path: Path, npx_path: str, workflows: str, tool_timeout_sec: int) -> bool:
    data: dict = {}
    if config_path.is_file() and config_path.read_text(encoding="utf-8").strip():
        data = json.loads(config_path.read_text(encoding="utf-8"))
    servers = data.setdefault("mcpServers", {})
    entry = {
        "command": npx_path,
        "args": ["-y", "xcodebuildmcp@latest", "mcp"],
        "env": {"XCODEBUILDMCP_ENABLED_WORKFLOWS": workflows},
    }
    existing = servers.get(SERVER_KEY)
    if existing == entry:
        return False
    servers[SERVER_KEY] = entry
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True


def merge_codex(config_path: Path, npx_path: str, workflows: str, tool_timeout_sec: int) -> bool:
    block_lines = [
        f"[mcp_servers.{SERVER_KEY}]",
        f'command = "{npx_path}"',
        'args = ["-y", "xcodebuildmcp@latest", "mcp"]',
        f"tool_timeout_sec = {tool_timeout_sec}.0",
        "",
        f"[mcp_servers.{SERVER_KEY}.env]",
        f'XCODEBUILDMCP_ENABLED_WORKFLOWS = "{workflows}"',
    ]
    block = "\n".join(block_lines) + "\n"

    if not config_path.is_file():
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(block, encoding="utf-8")
        return True

    text = config_path.read_text(encoding="utf-8")
    updated = append_mcp_block(strip_mcp_server_sections(text, SERVER_KEY), block)
    changed = updated != text
    if changed:
        config_path.write_text(updated, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("cursor", "codex"), required=True)
    parser.add_argument("--npx-path", required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--workflows", default=DEFAULT_WORKFLOWS)
    parser.add_argument("--tool-timeout-sec", type=int, default=DEFAULT_TOOL_TIMEOUT_SEC)
    args = parser.parse_args()

    config_path = Path(args.config_path).expanduser()
    if args.platform == "cursor":
        changed = merge_cursor(config_path, args.npx_path, args.workflows, args.tool_timeout_sec)
    else:
        changed = merge_codex(config_path, args.npx_path, args.workflows, args.tool_timeout_sec)

    print(f"config={config_path}")
    print(f"changed={'yes' if changed else 'no'}")
    print(f"workflows={args.workflows}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
