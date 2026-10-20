#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
TMP_DEFAULT_PROJECT="$(/usr/bin/mktemp -d)"
TMP_MCP_CONFIG="$(/usr/bin/mktemp)"
trap '/bin/rm -rf -- "$TMP_PROJECT" "$TMP_DEFAULT_PROJECT" "$TMP_MCP_CONFIG"' EXIT

# safe_write_external 默认 trusted_external_root=HOME；测试用 tmpdir 需显式指定
export DEV_FLOW_TRUSTED_EXTERNAL_ROOT="$(dirname "$TMP_MCP_CONFIG")"

mkdir -p "$TMP_PROJECT"
cat >"$TMP_PROJECT/Podfile" <<'RUBY'
platform :ios, '15.0'

target 'SampleApp' do
  use_frameworks!
end
RUBY

output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$output" | sed -n 's/^changed=//p')" == "yes" ]]
/usr/bin/grep -q "LookDebugBridge" "$TMP_PROJECT/Podfile"

/usr/bin/grep -q "LookDebugBridgeService.git" "$TMP_PROJECT/Podfile"
/usr/bin/grep -q ":tag => '0.1.18'" "$TMP_PROJECT/Podfile"
/usr/bin/grep -q ":configurations => \['Debug'\]" "$TMP_PROJECT/Podfile"

output_again="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$output_again" | sed -n 's/^changed=//p')" == "no" ]]

# Omitting --tag must use the current stable default. This guards against the
# installer's default drifting behind explicitly versioned call sites.
cp "$TMP_PROJECT/Podfile" "$TMP_DEFAULT_PROJECT/Podfile"
python3 - "$TMP_DEFAULT_PROJECT/Podfile" <<'PY'
from pathlib import Path
import sys

podfile = Path(sys.argv[1])
podfile.write_text(podfile.read_text().replace("0.1.18", "0.1.7"))
PY
default_output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_DEFAULT_PROJECT")"
[[ "$(printf '%s\n' "$default_output" | sed -n 's/^changed=//p')" == "yes" ]]
/usr/bin/grep -q ":tag => '0.1.18'" "$TMP_DEFAULT_PROJECT/Podfile"

python3 "$ROOT/scripts/lib/merge-debugbridge-mcp-config.py" \
  --platform cursor \
  --server-path "$ROOT/scripts/dev-flow.sh" \
  --node-path "$(command -v node)" \
  --config-path "$TMP_MCP_CONFIG" \
  --device-udid "TEST-UDID" >/dev/null

/usr/bin/grep -q 'ui_dbugbridge_mcp' "$TMP_MCP_CONFIG"
/usr/bin/grep -q 'TEST-UDID' "$TMP_MCP_CONFIG"


# Existing stale LookDebugBridge declaration must be normalized to the current
# canonical source/tag/configuration instead of being treated as already valid.
TMP_STALE_PROJECT="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_STALE_PROJECT"
cat >"$TMP_STALE_PROJECT/Podfile" <<'RUBY'
platform :ios, '15.0'

target 'SampleApp' do
  use_frameworks!
  pod 'LookDebugBridge',
      :git => 'https://github.com/Immmmmmortal1/UI-dbugbridge-mcp.git',
      :tag => '0.1.7'
end
RUBY

stale_output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_STALE_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$stale_output" | sed -n 's/^changed=//p')" == "yes" ]]
/usr/bin/grep -q "LookDebugBridgeService.git" "$TMP_STALE_PROJECT/Podfile"
/usr/bin/grep -q ":tag => '0.1.18'" "$TMP_STALE_PROJECT/Podfile"
/usr/bin/grep -q ":configurations => \['Debug'\]" "$TMP_STALE_PROJECT/Podfile"
if /usr/bin/grep -q "UI-dbugbridge-mcp.git\|0.1.7" "$TMP_STALE_PROJECT/Podfile"; then
  echo "stale LookDebugBridge pod declaration was not fully normalized" >&2
  exit 1
fi

stale_again="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_STALE_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$stale_again" | sed -n 's/^changed=//p')" == "no" ]]
/bin/rm -rf -- "$TMP_STALE_PROJECT"

# Commented LookDebugBridge lines are comments, not existing pods. They must not
# be upgraded in place or resurrected as active declarations outside intent.
TMP_COMMENT_PROJECT="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_COMMENT_PROJECT"
cat >"$TMP_COMMENT_PROJECT/Podfile" <<'RUBY'
platform :ios, '15.0'

target 'SampleApp' do
  use_frameworks!
  # pod 'LookDebugBridge', :tag => '0.1.7'
end
RUBY
comment_output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_COMMENT_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$comment_output" | sed -n 's/^changed=//p')" == "yes" ]]
# The commented historical line remains a comment; exactly one active declaration exists.
active_count="$(/usr/bin/grep -E "^[[:space:]]*pod ['\"]LookDebugBridge['\"]" "$TMP_COMMENT_PROJECT/Podfile" | /usr/bin/wc -l | tr -d ' ')"
[[ "$active_count" == "1" ]]
/usr/bin/grep -q "# pod 'LookDebugBridge'" "$TMP_COMMENT_PROJECT/Podfile"
/usr/bin/grep -q "LookDebugBridgeService.git" "$TMP_COMMENT_PROJECT/Podfile"
/usr/bin/grep -q ":tag => '0.1.18'" "$TMP_COMMENT_PROJECT/Podfile"
/bin/rm -rf -- "$TMP_COMMENT_PROJECT"

# Multiple active declarations are collapsed to one canonical Debug-only pod.
TMP_DUP_PROJECT="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_DUP_PROJECT"
cat >"$TMP_DUP_PROJECT/Podfile" <<'RUBY'
platform :ios, '15.0'

target 'SampleApp' do
  use_frameworks!
  pod 'LookDebugBridge', :git => 'https://github.com/Immmmmmortal1/UI-dbugbridge-mcp.git', :tag => '0.1.7'
  pod 'LookDebugBridge', :path => '../LookDebugBridgeService'
end
RUBY
dup_output="$(python3 "$ROOT/scripts/lib/install-debugbridge-pod.py" "$TMP_DUP_PROJECT" --tag 0.1.18)"
[[ "$(printf '%s\n' "$dup_output" | sed -n 's/^changed=//p')" == "yes" ]]
active_dup_count="$(/usr/bin/grep -E "^[[:space:]]*pod ['\"]LookDebugBridge['\"]" "$TMP_DUP_PROJECT/Podfile" | /usr/bin/wc -l | tr -d ' ')"
[[ "$active_dup_count" == "1" ]]
/usr/bin/grep -q "LookDebugBridgeService.git" "$TMP_DUP_PROJECT/Podfile"
/usr/bin/grep -q ":tag => '0.1.18'" "$TMP_DUP_PROJECT/Podfile"
if /usr/bin/grep -q "UI-dbugbridge-mcp.git\|:path => '../LookDebugBridgeService'\|0.1.7" "$TMP_DUP_PROJECT/Podfile"; then
  echo "duplicate LookDebugBridge declarations were not fully normalized" >&2
  exit 1
fi
/bin/rm -rf -- "$TMP_DUP_PROJECT"

echo "PASS: debugbridge pod injection and MCP config merge"
