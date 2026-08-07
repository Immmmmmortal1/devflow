#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_ID="${DEV_FLOW_SESSION_ID:-${CODEX_THREAD_ID:-local}}"
STATE_DIR="$ROOT/.dev-flow/sessions"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
FIGMA_SKILL_ROOT="${FIGMA_REST_API_SKILL_ROOT:-$HOME/.codex/skills/figma-rest-api}"

usage() {
  cat <<'EOF'
Usage:
  scripts/environment-health-check.sh run

The command records the report in the current dev-flow session. Probe commands may be supplied
through DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD and DEV_FLOW_REVIEW_MCP_HEALTH_CMD. Figma REST uses the
installed figma-rest-api skill and FIGMA_REST_TOKEN unless DEV_FLOW_FIGMA_REST_HEALTH_CMD is set.
EOF
}

if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid dev-flow session id: $SESSION_ID" >&2
  exit 2
fi

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

debug_command="${DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD:-}"
if [[ -z "$debug_command" ]]; then
  debug_url="${DEV_FLOW_DEBUGBRIDGE_URL:-${BRIDGE_BASE_URL:-http://127.0.0.1:37777}}"
  debug_command="/usr/bin/curl -fsS --max-time 3 '${debug_url%/}/ping' >/dev/null"
fi

review_command="${DEV_FLOW_REVIEW_MCP_HEALTH_CMD:-}"
if [[ -z "$review_command" ]]; then
  default_review_doctor="${ORCHESTRATOR_MCP_ROOT:-$ROOT/../../orchestrator-mcp}/scripts/orchestrator-doctor.sh"
  if [[ -x "$default_review_doctor" ]]; then
    review_command="'$default_review_doctor' >/dev/null"
  fi
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

debug_result="$(run_probe "$debug_command" debugbridge)"
review_result="$(run_probe "$review_command" review_mcp)"

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

/usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" "$debug_result" "$review_result" "$figma_result" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]
checks = {
    "debugbridge": json.loads(sys.argv[3]),
    "review_mcp": json.loads(sys.argv[4]),
    "figma_rest_api": json.loads(sys.argv[5]),
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
