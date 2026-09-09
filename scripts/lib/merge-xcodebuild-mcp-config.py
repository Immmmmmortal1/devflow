#!/usr/bin/env python3
"""Merge XcodeBuildMCP server config for Cursor (JSON) or Codex (TOML)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from merge_mcp_codex_common import append_mcp_block, strip_mcp_server_sections

# 延迟导入 atomic_json_write（只在需要写入时 import）
def _import_safe_write():
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from atomic_json_write import safe_write_external
    return safe_write_external

def _get_trusted_external_root():
    """从环境变量获取 trusted_external_root（测试用），默认 None（safe_write_external 内部回退到 HOME）。"""
    import os
    return os.environ.get("DEV_FLOW_TRUSTED_EXTERNAL_ROOT") or None

SERVER_KEY = "XcodeBuildMCP"
DEFAULT_WORKFLOWS = "session-management,project-discovery,device"
DEFAULT_TOOL_TIMEOUT_SEC = 600


def merge_cursor(config_path: Path, npx_path: str, workflows: str, tool_timeout_sec: int) -> bool:
    safe_write_external = _import_safe_write()
    ter = _get_trusted_external_root()
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
    safe_write_external(config_path, json.dumps(data, indent=2) + "\n", mode=0o644, trusted_external_root=ter)
    return True


def toml_quote(value: str) -> str:
    """TOML 双引号字符串转义，防止路径中的引号/反斜杠破坏配置结构"""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def merge_codex(config_path: Path, npx_path: str, workflows: str, tool_timeout_sec: int) -> bool:
    safe_write_external = _import_safe_write()
    ter = _get_trusted_external_root()
    block_lines = [
        f"[mcp_servers.{SERVER_KEY}]",
        f'command = "{toml_quote(npx_path)}"',
        'args = ["-y", "xcodebuildmcp@latest", "mcp"]',
        f"tool_timeout_sec = {tool_timeout_sec}.0",
        "",
        f"[mcp_servers.{SERVER_KEY}.env]",
        f'XCODEBUILDMCP_ENABLED_WORKFLOWS = "{toml_quote(workflows)}"',
    ]
    block = "\n".join(block_lines) + "\n"

    if not config_path.is_file():
        safe_write_external(config_path, block, mode=0o644, trusted_external_root=ter)
        return True

    text = config_path.read_text(encoding="utf-8")
    updated = append_mcp_block(strip_mcp_server_sections(text, SERVER_KEY), block)
    changed = updated != text
    if changed:
        safe_write_external(config_path, updated, mode=0o644, trusted_external_root=ter)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("cursor", "codex", "opencode"), required=True)
    parser.add_argument("--npx-path", required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--workflows", default=DEFAULT_WORKFLOWS)
    parser.add_argument("--tool-timeout-sec", type=int, default=DEFAULT_TOOL_TIMEOUT_SEC)
    args = parser.parse_args()

    if args.platform == "opencode":
        # opencode: 不合并 host MCP config（opencode 自行管理）
        print(f"config=opencode-managed")
        print(f"changed=skipped")
        print(f"workflows={args.workflows}")
        return 0

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
