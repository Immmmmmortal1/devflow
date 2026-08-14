#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"
TMP_CONFIG="$(/usr/bin/mktemp)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -f -- "$TMP_CONFIG"; /bin/rm -rf -- "$TMP_PROJECT"' EXIT

python3 "$LIB/merge-xcodebuild-mcp-config.py" \
  --platform codex \
  --npx-path "$(command -v npx)" \
  --config-path "$TMP_CONFIG" >/dev/null

/usr/bin/grep -q 'XcodeBuildMCP' "$TMP_CONFIG"
/usr/bin/grep -q 'session-management,project-discovery,device' "$TMP_CONFIG"
/usr/bin/grep -q 'tool_timeout_sec = 600.0' "$TMP_CONFIG"

python3 - <<PY
import tomllib
from pathlib import Path

tomllib.loads(Path("$TMP_CONFIG").read_text(encoding="utf-8"))
print("toml parse ok")
PY

bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --codex \
  --project "$TMP_PROJECT" \
  --config-path "$TMP_CONFIG" \
  --skip-mcp-config >/dev/null

[[ -f "$TMP_PROJECT/.dev-flow/xcodebuild-mcp-install.json" ]]
[[ -f "$TMP_PROJECT/.xcodebuildmcp/config.yaml" ]]
/usr/bin/grep -q 'device' "$TMP_PROJECT/.xcodebuildmcp/config.yaml"

python3 "$LIB/verify-xcodebuild-mcp-config.py" \
  --platform codex \
  --config-path "$TMP_CONFIG" \
  --project-root "$TMP_PROJECT" | /usr/bin/grep -q '^status=ok$'

python3 "$LIB/merge-xcodebuild-mcp-config.py" \
  --platform codex \
  --npx-path "$(command -v npx)" \
  --config-path "$TMP_CONFIG" >/dev/null

env_count="$(/usr/bin/grep -c '^\[mcp_servers\.XcodeBuildMCP\.env\]' "$TMP_CONFIG" || true)"
[[ "$env_count" -eq 1 ]]

echo "PASS: install-xcodebuild-mcp.sh and config verification"
