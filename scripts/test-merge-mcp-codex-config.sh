#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_CONFIG="$(/usr/bin/mktemp)"
trap '/bin/rm -f -- "$TMP_CONFIG"' EXIT

cat >"$TMP_CONFIG" <<'TOML'
model = "gpt-5"

[mcp_servers.ui_dbugbridge_mcp]
command = "/old/node"
args = ["/old/server.js"]
startup_timeout_sec = 30.0

[mcp_servers.ui_dbugbridge_mcp.env]
IPROXY_PATH = "iproxy"
LOOKDEBUG_DEVICE_UDID = "OLD-UDID"

[mcp_servers.ui_dbugbridge_mcp.env]
IPROXY_PATH = "iproxy"
LOOKDEBUG_DEVICE_UDID = "DUPLICATE-UDID"
TOML

python3 "$ROOT/scripts/lib/merge-debugbridge-mcp-config.py" \
  --platform codex \
  --server-path "$ROOT/scripts/dev-flow.sh" \
  --node-path "$(command -v node)" \
  --config-path "$TMP_CONFIG" \
  --device-udid "NEW-UDID" >/dev/null

env_count="$(/usr/bin/grep -c '^\[mcp_servers\.ui_dbugbridge_mcp\.env\]' "$TMP_CONFIG" || true)"
[[ "$env_count" -eq 1 ]]
/usr/bin/grep -q 'NEW-UDID' "$TMP_CONFIG"
if /usr/bin/grep -q 'DUPLICATE-UDID' "$TMP_CONFIG"; then
  echo "FAIL: duplicate env section was not removed" >&2
  exit 1
fi

python3 - <<PY
import tomllib
from pathlib import Path

tomllib.loads(Path("$TMP_CONFIG").read_text(encoding="utf-8"))
print("toml parse ok")
PY

python3 "$ROOT/scripts/lib/merge-debugbridge-mcp-config.py" \
  --platform codex \
  --server-path "$ROOT/scripts/dev-flow.sh" \
  --node-path "$(command -v node)" \
  --config-path "$TMP_CONFIG" \
  --device-udid "NEW-UDID" >/dev/null

env_count_again="$(/usr/bin/grep -c '^\[mcp_servers\.ui_dbugbridge_mcp\.env\]' "$TMP_CONFIG" || true)"
[[ "$env_count_again" -eq 1 ]]

echo "PASS: codex ui_dbugbridge_mcp merge deduplicates env sections"
