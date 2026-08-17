#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?

usage() {
  cat <<'EOF'
Usage:
  scripts/validate-bridge-session.sh run

Validate that the in-App DebugBridge /identity sessionID matches the current dev-flow session.
Rejects bridge session "local" when the dev-flow session is not "local".

Output: one JSON object on stdout with status available|blocked.
Tests may set DEV_FLOW_BRIDGE_IDENTITY_JSON instead of calling /identity.
EOF
}

if [[ "${1:-}" != "run" ]]; then
  usage >&2
  exit 2
fi

identity_json=""
if [[ -n "${DEV_FLOW_BRIDGE_IDENTITY_JSON:-}" ]]; then
  identity_json="$DEV_FLOW_BRIDGE_IDENTITY_JSON"
else
  debug_url="${DEV_FLOW_DEBUGBRIDGE_URL:-${BRIDGE_BASE_URL:-http://127.0.0.1:37777}}"
  set +e
  identity_json="$(/usr/bin/curl -fsS --max-time 3 "${debug_url%/}/identity" 2>/dev/null)"
  curl_exit=$?
  set -e
  if [[ $curl_exit -ne 0 || -z "$identity_json" ]]; then
    identity_json=""
  fi
fi

/usr/bin/python3 - "$SESSION_ID" "$identity_json" <<'PY'
import json
import sys

session_id = sys.argv[1]
identity_raw = sys.argv[2]

def emit(status, evidence, bridge_session_id=None):
    payload = {"status": status, "evidence": evidence}
    if bridge_session_id is not None:
        payload["bridge_session_id"] = bridge_session_id
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0 if status == "available" else 1)

if not identity_raw:
    emit("blocked", "bridge_identity_unreachable")

try:
    identity = json.loads(identity_raw)
except json.JSONDecodeError:
    emit("blocked", "bridge_identity_invalid_json")

if not isinstance(identity, dict):
    emit("blocked", "bridge_identity_not_object")

bridge_session = identity.get("sessionID")
if bridge_session is None:
    bridge_session = identity.get("session_id")
if not isinstance(bridge_session, str) or not bridge_session:
    emit("blocked", "bridge_identity_missing_session_id")

if bridge_session == "local" and session_id != "local":
    emit(
        "blocked",
        "bridge_session_local;pass_DEV_FLOW_SESSION_ID_via_build_run_device_env",
        bridge_session,
    )

if bridge_session != session_id:
    emit(
        "blocked",
        f"bridge_session_mismatch;expected={session_id};actual={bridge_session}",
        bridge_session,
    )

emit(
    "available",
    f"bridge_session={bridge_session};matches_dev_flow",
    bridge_session,
)
PY
