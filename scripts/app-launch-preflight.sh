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
  scripts/app-launch-preflight.sh status
  scripts/app-launch-preflight.sh instructions
  scripts/app-launch-preflight.sh template
  scripts/app-launch-preflight.sh record --report <path|->

This script owns the dev-flow App launch preflight boundary. It does not fabricate a launch
success. A real agent must first call XcodeBuildMCP session_show_defaults, then build_run_device
on a wired physical device with env DEV_FLOW_SESSION_ID=<current session id>. Record the bounded
result with record --report <path|-> before running environment-health.
EOF
}

emit_missing_json() {
  /usr/bin/python3 - "$SESSION_ID" "$REPORT_FILE" <<'PY'
import json
import sys

session_id, report_file = sys.argv[1], sys.argv[2]
print(json.dumps({
    "status": "blocked",
    "evidence": "app_launch_report_missing;run_xcodebuildmcp_session_show_defaults_then_build_run_device",
    "session_id": session_id,
    "expected_report": report_file,
    "required_tools": ["session_show_defaults", "build_run_device"],
    "record_command": "bash scripts/dev-flow.sh app-launch record --report <path|->",
}, ensure_ascii=False))
PY
}

validate_and_cat_report() {
  if [[ ! -f "$REPORT_FILE" ]]; then
    emit_missing_json
    return 1
  fi
  /usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]

try:
    payload = json.loads(report_path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({
        "status": "blocked",
        "evidence": f"app_launch_report_invalid_json:{exc}",
        "session_id": session_id,
        "expected_report": str(report_path),
    }, ensure_ascii=False))
    raise SystemExit(1)

def non_placeholder(value):
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value.strip().lower() not in {"unknown", "n/a", "-", ""}
    )

required = {
    "producer": "XcodeBuildMCP",
    "schema_version": 1,
    "session_id": session_id,
    "status": "available",
    "build_run_device": "success",
    "device_transport": "wired",
    "app_launched": True,
}
errors = []
for key, expected in required.items():
    if payload.get(key) != expected:
        errors.append(key)
for key in ("build_id", "device_id"):
    if not non_placeholder(payload.get(key)):
        errors.append(key)
if errors:
    print(json.dumps({
        "status": "blocked",
        "evidence": "app_launch_report_invalid_fields:" + ",".join(errors),
        "session_id": session_id,
        "expected_report": str(report_path),
    }, ensure_ascii=False))
    raise SystemExit(1)

print(json.dumps(payload, ensure_ascii=False))
PY
}

print_instructions() {
  cat <<EOF
App launch preflight for dev-flow session: $SESSION_ID

Required order:
  1. XcodeBuildMCP session_show_defaults
  2. Verify workspace/project, scheme, Debug configuration, and wired physical device
  3. XcodeBuildMCP build_run_device with env DEV_FLOW_SESSION_ID=$SESSION_ID
  4. Save a bounded JSON report, then run:
     bash "$(dev_flow_script_path dev-flow.sh)" app-launch record --report <path|->
  5. Run:
     bash "$(dev_flow_script_path dev-flow.sh)" environment-health run

Required report fields:
  producer=XcodeBuildMCP
  schema_version=1
  session_id=$SESSION_ID
  status=available
  build_run_device=success
  device_transport=wired
  app_launched=true
  build_id=<real non-placeholder build id>
  device_id=<real non-placeholder device id>
EOF
}

print_template() {
  /usr/bin/python3 - "$SESSION_ID" <<'PY'
import json
import sys

session_id = sys.argv[1]
print(json.dumps({
    "producer": "XcodeBuildMCP",
    "schema_version": 1,
    "session_id": session_id,
    "status": "available",
    "build_run_device": "success",
    "device_transport": "wired",
    "app_launched": True,
    "build_id": "<real-build-id-from-XcodeBuildMCP>",
    "device_id": "<wired-device-udid-or-id>",
}, ensure_ascii=False, indent=2))
PY
}

cmd="${1:-}"
case "$cmd" in
  status)
    validate_and_cat_report
    ;;
  instructions)
    print_instructions
    ;;
  template)
    print_template
    ;;
  record)
    shift
    exec bash "$(dev_flow_script_path record-app-launch-report.sh)" record "$@"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown app-launch command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
