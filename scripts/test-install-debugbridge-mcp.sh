#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
TMP_MCP_CONFIG="$(/usr/bin/mktemp)"
trap '/bin/rm -rf -- "$TMP_PROJECT" "$TMP_MCP_CONFIG"' EXIT

mkdir -p "$TMP_PROJECT"
cat >"$TMP_PROJECT/Podfile" <<'RUBY'
platform :ios, '15.0'

target 'SampleApp' do
  use_frameworks!
end
RUBY

output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_PROJECT" --tag 0.1.7)"
[[ "$(printf '%s\n' "$output" | sed -n 's/^changed=//p')" == "yes" ]]
/usr/bin/grep -q "LookDebugBridge" "$TMP_PROJECT/Podfile"

output_again="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_PROJECT" --tag 0.1.7)"
[[ "$(printf '%s\n' "$output_again" | sed -n 's/^changed=//p')" == "no" ]]

python3 "$ROOT/scripts/lib/merge-debugbridge-mcp-config.py" \
  --platform cursor \
  --server-path "$ROOT/scripts/dev-flow.sh" \
  --node-path "$(command -v node)" \
  --config-path "$TMP_MCP_CONFIG" \
  --device-udid "TEST-UDID" >/dev/null

/usr/bin/grep -q 'ui_dbugbridge_mcp' "$TMP_MCP_CONFIG"
/usr/bin/grep -q 'TEST-UDID' "$TMP_MCP_CONFIG"

echo "PASS: debugbridge pod injection and MCP config merge"
