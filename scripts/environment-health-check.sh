#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$ROOT/scripts/resolve-dev-flow-session-id.sh"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
STATE_DIR="$ROOT/.dev-flow/sessions"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
FIGMA_SKILL_ROOT="${FIGMA_REST_API_SKILL_ROOT:-$HOME/.codex/skills/figma-rest-api}"

usage() {
  cat <<'EOF'
Usage:
  scripts/environment-health-check.sh run

The command records the report in the current dev-flow session. The caller must first run the
registered XcodeBuildMCP physical-device launch preflight, then record the bounded result with
scripts/record-app-launch-report.sh record. By default the App launch probe reads
.dev-flow/sessions/<session-id>.app-launch.json through scripts/read-app-launch-report.sh.
Override with DEV_FLOW_APP_LAUNCH_HEALTH_CMD when a custom adapter is required. The stored or
adapter JSON must include producer=XcodeBuildMCP, schema_version=1, the current session_id,
status=available, build_run_device=success, device_transport=wired, and app_launched=true. Other
probes use DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD and DEV_FLOW_REVIEW_MCP_HEALTH_CMD. Review MCP health
defaults to scripts/review-health-probe.sh, which falls back to gstack-review when orchestrator MCP
is unavailable. Figma REST uses the installed skill and FIGMA_REST_TOKEN unless
DEV_FLOW_FIGMA_REST_HEALTH_CMD is set.

Session selection matches scripts/resolve-dev-flow-session-id.sh:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, then CURSOR_CONVERSATION_ID.
EOF
}

if [[ "${1:-}" != "run" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

mkdir -p "$STATE_DIR"
REPORT_FILE="$(mktemp "$STATE_DIR/.${SESSION_ID}.environment.XXXXXX.json")"
trap 'rm -f "$REPORT_FILE"' EXIT

run_probe() {
  local command_text="$1"
  local label="$2"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"

  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    /usr/bin/python3 - "$label" <<'PY'
import json
import sys
print(json.dumps({"status": "blocked", "evidence": "probe_not_configured"}, ensure_ascii=False))
PY
    return
  fi

  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  rm -f "$output_file" "$error_file"

  /usr/bin/python3 - "$exit_code" <<'PY'
import json
import sys

exit_code = int(sys.argv[1])
if exit_code == 0:
    result = {"status": "available", "evidence": "probe_exit_0"}
else:
    result = {"status": "blocked", "evidence": f"probe_exit_{exit_code}"}
print(json.dumps(result, ensure_ascii=False))
PY
}

run_app_launch_probe() {
  local command_text="$1"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    printf '%s\n' '{"status":"blocked","evidence":"app_launch_probe_not_configured"}'
    return
  fi
  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  /usr/bin/python3 - "$output_file" "$exit_code" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
session_id = sys.argv[3]
try:
    payload = json.loads(output_path.read_text())
except (json.JSONDecodeError, OSError):
    payload = {}
valid = (
    exit_code == 0
    and payload.get("producer") == "XcodeBuildMCP"
    and payload.get("schema_version") == 1
    and payload.get("session_id") == session_id
    and payload.get("status") == "available"
    and payload.get("build_run_device") == "success"
    and payload.get("device_transport") == "wired"
    and payload.get("app_launched") is True
)
if valid:
    result = {
        "status": "available",
        "evidence": "xcodebuildmcp_build_run_device_success;wired;app_launched",
    }
else:
    result = {
        "status": "blocked",
        "evidence": "invalid_or_failed_xcodebuildmcp_app_launch_report",
    }
print(json.dumps(result, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

run_review_probe() {
  local command_text="$1"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    printf '%s\n' '{"status":"blocked","evidence":"review_probe_not_configured"}'
    return
  fi
  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  /usr/bin/python3 - "$output_file" "$exit_code" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
session_id = sys.argv[3]
try:
    payload = json.loads(output_path.read_text())
except (json.JSONDecodeError, OSError):
    payload = {}
valid = (
    exit_code == 0
    and payload.get("producer") == "review-health-probe"
    and payload.get("schema_version") == 1
    and payload.get("session_id") == session_id
    and payload.get("status") == "available"
    and payload.get("transport") in ("mcp", "fallback")
)
if not valid:
    print(json.dumps({"status": "blocked", "evidence": "invalid_or_failed_review_health_report"}, ensure_ascii=False))
    sys.exit(0)
if payload.get("transport") == "mcp":
    evidence = "orchestrator_mcp_health_ok"
elif payload.get("fallback") == "gstack-review":
    skill_path = payload.get("skill_path") or "gstack-review"
    evidence = f"review_mcp_unavailable;fallback=gstack-review;skill={skill_path}"
else:
    evidence = "review_health_probe_available"
print(json.dumps({"status": "available", "evidence": evidence}, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

debug_command="${DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD:-}"
if [[ -z "$debug_command" ]]; then
  debug_url="${DEV_FLOW_DEBUGBRIDGE_URL:-${BRIDGE_BASE_URL:-http://127.0.0.1:37777}}"
  debug_command="/usr/bin/curl -fsS --max-time 3 '${debug_url%/}/ping' >/dev/null"
fi

app_launch_command="${DEV_FLOW_APP_LAUNCH_HEALTH_CMD:-}"
if [[ -z "$app_launch_command" ]]; then
  app_launch_command="'$ROOT/scripts/read-app-launch-report.sh'"
fi

app_launch_result="$(run_app_launch_probe "$app_launch_command")"
app_launch_status="$(/usr/bin/python3 - "$app_launch_result" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["status"])
PY
)"

review_command="${DEV_FLOW_REVIEW_MCP_HEALTH_CMD:-}"
if [[ -n "$review_command" ]]; then
  review_result="$(run_probe "$review_command" review_mcp)"
else
  review_result="$(run_review_probe "'$ROOT/scripts/review-health-probe.sh'")"
fi

figma_skill_status="available"
figma_skill_evidence="skill_and_script_present"
if [[ ! -f "$FIGMA_SKILL_ROOT/SKILL.md" ]]; then
  figma_skill_status="blocked"
  figma_skill_evidence="skill_file_missing"
elif [[ ! -f "$FIGMA_SKILL_ROOT/scripts/figma_rest.py" ]]; then
  figma_skill_status="blocked"
  figma_skill_evidence="figma_rest_script_missing"
elif [[ -z "${FIGMA_REST_TOKEN:-}" && -z "${DEV_FLOW_FIGMA_REST_HEALTH_CMD:-}" ]]; then
  figma_skill_status="blocked"
  figma_skill_evidence="FIGMA_REST_TOKEN_missing"
fi

if [[ "$app_launch_status" == "available" ]]; then
  debug_result="$(run_probe "$debug_command" debugbridge)"
else
  debug_result='{"status":"blocked","evidence":"app_launch_preflight_failed"}'
fi

if [[ "$figma_skill_status" == "available" ]]; then
  if [[ -n "${DEV_FLOW_FIGMA_REST_HEALTH_CMD:-}" ]]; then
    figma_result="$(run_probe "$DEV_FLOW_FIGMA_REST_HEALTH_CMD" figma_rest)"
  else
    figma_result="$(run_probe "/usr/bin/python3 '$FIGMA_SKILL_ROOT/scripts/figma_rest.py' me >/dev/null" figma_rest)"
  fi
  figma_result="$(/usr/bin/python3 - "$figma_skill_evidence" "$figma_result" <<'PY'
import json
import sys

skill_evidence = sys.argv[1]
result = json.loads(sys.argv[2])
if result["status"] == "available":
    result["evidence"] = skill_evidence + ";" + result["evidence"]
print(json.dumps(result, ensure_ascii=False))
PY
)"
else
  figma_result="$(/usr/bin/python3 - "$figma_skill_status" "$figma_skill_evidence" <<'PY'
import json
import sys
print(json.dumps({"status": sys.argv[1], "evidence": sys.argv[2]}, ensure_ascii=False))
PY
)"
fi

/usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" "$app_launch_result" "$debug_result" "$review_result" "$figma_result" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]
checks = {
    "app_launch": json.loads(sys.argv[3]),
    "debugbridge": json.loads(sys.argv[4]),
    "review_mcp": json.loads(sys.argv[5]),
    "figma_rest_api": json.loads(sys.argv[6]),
}
status = "available" if all(item["status"] == "available" for item in checks.values()) else "blocked"
report = {
    "producer": "environment-health-check",
    "schema_version": 1,
    "session_id": session_id,
    "status": status,
    "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "checks": checks,
}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(report_path)
PY

if "$ROOT/scripts/dev-flow-session.sh" environment-health --report "$REPORT_FILE" >/dev/null; then
  cat "$STATE_FILE"
  exit 0
fi

cat "$STATE_FILE" >&2
exit 1
