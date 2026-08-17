#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

run_validate() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run "$@" || true
}

assert_blocked() {
  local session_id="$1"
  local identity_json="$2"
  local expected_evidence="$3"
  local output
  output="$(DEV_FLOW_BRIDGE_IDENTITY_JSON="$identity_json" run_validate "$session_id")"
  /usr/bin/python3 - "$output" "$expected_evidence" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
assert payload["status"] == "blocked", payload
assert expected in payload["evidence"], payload
PY
}

assert_available() {
  local session_id="$1"
  local identity_json="$2"
  local output exit_code=0
  output="$(DEV_FLOW_BRIDGE_IDENTITY_JSON="$identity_json" run_validate "$session_id")" || exit_code=$?
  /usr/bin/python3 - "$output" "$session_id" "$exit_code" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
session_id = sys.argv[2]
exit_code = int(sys.argv[3])
assert exit_code == 0, exit_code
assert payload["status"] == "available", payload
assert payload["bridge_session_id"] == session_id, payload
PY
}

assert_blocked adapter-session '{"ok":true,"sessionID":"local"}' bridge_session_local
assert_blocked adapter-session '{"ok":true,"sessionID":"other-session"}' bridge_session_mismatch
assert_available adapter-session '{"ok":true,"sessionID":"adapter-session"}'

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=local CURSOR_AGENT=1 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record >/dev/null 2>&1; then
  echo "FAIL: record-app-launch allowed local session inside Cursor" >&2
  exit 1
fi

echo "PASS: validate-bridge-session rejects local/mismatch and accepts matching session"
