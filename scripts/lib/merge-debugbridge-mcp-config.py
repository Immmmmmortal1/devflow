#!/usr/bin/env python3
"""Merge ui_dbugbridge_mcp MCP server config for Cursor (JSON) or Codex (TOML)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def detect_device_udid() -> str:
    try:
        import subprocess

        proc = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", "-"],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            payload = json.loads(proc.stdout)
            for device in payload.get("result", {}).get("devices", []):
                if device.get("connectionProperties", {}).get("transportType") == "wired":
                    udid = device.get("hardwareProperties", {}).get("udid") or device.get("identifier")
                    if udid:
                        return udid
            for device in payload.get("result", {}).get("devices", []):
                udid = device.get("hardwareProperties", {}).get("udid") or device.get("identifier")
                if udid:
                    return udid
    except Exception:  # noqa: BLE001
        pass
    return ""


def merge_cursor(config_path: Path, server_path: str, node_path: str, udid: str) -> bool:
    data: dict = {}
    if config_path.is_file() and config_path.read_text(encoding="utf-8").strip():
        data = json.loads(config_path.read_text(encoding="utf-8"))
    servers = data.setdefault("mcpServers", {})
    entry = {
        "command": node_path,
        "args": [str(Path(server_path).expanduser())],
        "env": {"IPROXY_PATH": "iproxy"},
    }
    if udid:
        entry["env"]["LOOKDEBUG_DEVICE_UDID"] = udid
    existing = servers.get("ui_dbugbridge_mcp")
    if existing == entry:
        return False
    servers["ui_dbugbridge_mcp"] = entry
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True


def merge_codex(config_path: Path, server_path: str, node_path: str, udid: str) -> bool:
    block_lines = [
        "[mcp_servers.ui_dbugbridge_mcp]",
        f'command = "{node_path}"',
        f'args = ["{Path(server_path).expanduser()}"]',
        "startup_timeout_sec = 30.0",
        "",
        "[mcp_servers.ui_dbugbridge_mcp.env]",
        'IPROXY_PATH = "iproxy"',
    ]
    if udid:
        block_lines.append(f'LOOKDEBUG_DEVICE_UDID = "{udid}"')
    block = "\n".join(block_lines) + "\n"

    if not config_path.is_file():
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(block, encoding="utf-8")
        return True

    text = config_path.read_text(encoding="utf-8")
    pattern = re.compile(
        r"\[mcp_servers\.ui_dbugbridge_mcp\][\s\S]*?(?=\n\[|\Z)",
        re.MULTILINE,
    )
    if pattern.search(text):
        updated = pattern.sub(block.rstrip() + "\n\n", text, count=1)
        changed = updated != text
        if changed:
            config_path.write_text(updated, encoding="utf-8")
        return changed

    if not text.endswith("\n"):
        text += "\n"
    config_path.write_text(text + "\n" + block, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("cursor", "codex"), required=True)
    parser.add_argument("--server-path", required=True)
    parser.add_argument("--node-path", required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--device-udid", default="")
    args = parser.parse_args()

    udid = args.device_udid or detect_device_udid()
    config_path = Path(args.config_path).expanduser()
    if args.platform == "cursor":
        changed = merge_cursor(config_path, args.server_path, args.node_path, udid)
    else:
        changed = merge_codex(config_path, args.server_path, args.node_path, udid)

    print(f"config={config_path}")
    print(f"changed={'yes' if changed else 'no'}")
    if udid:
        print(f"device_udid={udid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
