#!/usr/bin/env python3
"""Merge orchestrator_mcp MCP server config for Cursor (JSON) or Codex (TOML)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from merge_mcp_codex_common import append_mcp_block, strip_mcp_server_sections


def merge_cursor(config_path: Path, wrapper_path: str, pythonpath: str) -> bool:
    data: dict = {}
    if config_path.is_file() and config_path.read_text(encoding="utf-8").strip():
        data = json.loads(config_path.read_text(encoding="utf-8"))
    servers = data.setdefault("mcpServers", {})
    entry = {
        "command": str(Path(wrapper_path).expanduser()),
        "args": [],
        "env": {
            "ORCHESTRATOR_MCP_TRANSPORT": "stdio",
            "PYTHONPATH": str(Path(pythonpath).expanduser()),
        },
    }
    existing = servers.get("orchestrator_mcp")
    if existing == entry:
        return False
    servers["orchestrator_mcp"] = entry
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True


def merge_codex(config_path: Path, wrapper_path: str, pythonpath: str) -> bool:
    block_lines = [
        "[mcp_servers.orchestrator_mcp]",
        f'command = "{Path(wrapper_path).expanduser()}"',
        "args = []",
        "startup_timeout_sec = 120.0",
        "",
        "[mcp_servers.orchestrator_mcp.env]",
        'ORCHESTRATOR_MCP_TRANSPORT = "stdio"',
        f'PYTHONPATH = "{Path(pythonpath).expanduser()}"',
    ]
    block = "\n".join(block_lines) + "\n"

    if not config_path.is_file():
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(block, encoding="utf-8")
        return True

    text = config_path.read_text(encoding="utf-8")
    updated = append_mcp_block(strip_mcp_server_sections(text, "orchestrator_mcp"), block)
    changed = updated != text
    if changed:
        config_path.write_text(updated, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("cursor", "codex"), required=True)
    parser.add_argument("--wrapper-path", required=True)
    parser.add_argument("--pythonpath", required=True)
    parser.add_argument("--config-path", required=True)
    args = parser.parse_args()

    config_path = Path(args.config_path).expanduser()
    if args.platform == "cursor":
        changed = merge_cursor(config_path, args.wrapper_path, args.pythonpath)
    else:
        changed = merge_codex(config_path, args.wrapper_path, args.pythonpath)

    print(f"config={config_path}")
    print(f"changed={'yes' if changed else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
