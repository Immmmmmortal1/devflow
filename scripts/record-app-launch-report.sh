#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
REPORT_FILE="$STATE_DIR/$SESSION_ID.app-launch.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/record-app-launch-report.sh record [--report <path>]

Record a bounded XcodeBuildMCP build_run_device success report for the current dev-flow
session. Without --report, writes the canonical success payload after build_run_device.
With --report, validates and stores JSON from the given path (use - for stdin).

Session selection matches scripts/resolve-dev-flow-session-id.sh.
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [[ "${1:-}" != "record" ]]; then
  usage >&2
  exit 2
fi
shift

source_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      source_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$STATE_DIR"

/usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" "$source_path" "$(now_utc)" <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]
source_path = sys.argv[3]
timestamp = sys.argv[4]

REQUIRED = {
    "producer": "XcodeBuildMCP",
    "schema_version": 1,
    "status": "available",
    "build_run_device": "success",
    "device_transport": "wired",
}


def validate_payload(payload):
    if not isinstance(payload, dict):
        raise SystemExit("App launch report must be a JSON object.")
    for key, expected in REQUIRED.items():
        if payload.get(key) != expected:
            raise SystemExit(f"Invalid app launch report field: {key}")
    if payload.get("session_id") != session_id:
        raise SystemExit("App launch report session_id does not match the current session.")
    if payload.get("app_launched") is not True:
        raise SystemExit("app_launched must be true.")
    if session_id == "local" and os.environ.get("CURSOR_AGENT") == "1":
        raise SystemExit(
            "Cannot record app launch for session_id 'local' inside Cursor. "
            "Run dev-flow session start and pass DEV_FLOW_SESSION_ID via build_run_device env."
        )


def canonical():
    return {
        **REQUIRED,
        "session_id": session_id,
        "app_launched": True,
        "recorded_at": timestamp,
    }


if source_path:
    if source_path == "-":
        raw = sys.stdin.read()
    else:
        raw = Path(source_path).read_text()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in app launch report: {exc}") from exc
    validate_payload(payload)
    if "recorded_at" not in payload:
        payload["recorded_at"] = timestamp
else:
    payload = canonical()

if session_id == "local" and os.environ.get("CURSOR_AGENT") == "1":
    raise SystemExit(
        "Cannot record app launch for session_id 'local' inside Cursor. "
        "Run dev-flow session start and pass DEV_FLOW_SESSION_ID via build_run_device env."
    )

report_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
print(report_path)
PY
