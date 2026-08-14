#!/usr/bin/env python3
"""Shared helpers for merging MCP server blocks into Codex config.toml."""

from __future__ import annotations

import re


def strip_mcp_server_sections(text: str, server_name: str) -> str:
    """Remove the main and .env TOML sections for one MCP server (including duplicates)."""
    pattern = re.compile(
        rf"\[mcp_servers\.{re.escape(server_name)}(?:\.env)?\][\s\S]*?(?=\n\[|\Z)",
        re.MULTILINE,
    )
    prev = None
    while prev != text:
        prev = text
        text = pattern.sub("", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.rstrip()


def append_mcp_block(text: str, block: str) -> str:
    if not text:
        return block.rstrip() + "\n"
    return text.rstrip() + "\n\n" + block.rstrip() + "\n"
