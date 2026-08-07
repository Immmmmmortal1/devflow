#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_ID="${DEV_FLOW_SESSION_ID:-${CODEX_THREAD_ID:-local}}"
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "Invalid dev-flow session id: $SESSION_ID" >&2
  exit 2
fi
STATE_DIR="$ROOT/.dev-flow/sessions"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/dev-flow-session.sh start --type bug|feature|ui_review [--task "label"]
  scripts/dev-flow-session.sh configure-gates --required review[,figma_ui][,runtime]
  scripts/dev-flow-session.sh environment-health --report <path>
  scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime --report <path>
  scripts/dev-flow-session.sh confirm-plan [--task "label"]
  scripts/dev-flow-session.sh approve-commit [--task "label"]
  scripts/dev-flow-session.sh end
  scripts/dev-flow-session.sh status

Session selection:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, otherwise "local".
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_common_args() {
  SESSION_TYPE=""
  TASK=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        SESSION_TYPE="${2:-}"
        shift 2
        ;;
      --task)
        TASK="${2:-}"
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
}

write_state() {
  local action="$1"
  local session_type="${2:-}"
  local task="${3:-}"
  local required_gates="${4:-}"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$action" "$session_type" "$task" "$required_gates" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
session_id = sys.argv[2]
action = sys.argv[3]
session_type = sys.argv[4]
task = sys.argv[5]
required_gates_arg = sys.argv[6]
timestamp = sys.argv[7]

all_gates = ("figma_ui", "review", "runtime")
required_gates = [item for item in required_gates_arg.split(",") if item]
if action == "start" and not required_gates:
    required_gates = ["review"]
if any(item not in all_gates for item in required_gates):
    raise SystemExit("Unknown gate. Use figma_ui, review, or runtime.")
if action in ("start", "configure-gates") and "review" not in required_gates:
    raise SystemExit("The review gate is required for every dev-flow commit session.")
if len(set(required_gates)) != len(required_gates):
    raise SystemExit("Duplicate required gate.")

default_gate_results = {
    "figma_ui": {"status": "not-required", "evidence": None, "recorded_at": None},
    "review": {"status": "pending", "evidence": None, "recorded_at": None},
    "runtime": {"status": "not-required", "evidence": None, "recorded_at": None},
}

def make_gate_results(required):
    results = json.loads(json.dumps(default_gate_results))
    for gate in required:
        results[gate]["status"] = "pending"
    return results

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        data = {}

if action == "start":
    data = {
        "session_id": session_id,
        "active": True,
        "type": session_type,
        "task": task,
        "started_at": timestamp,
        "confirmed_at": None,
        "commit_approved_at": None,
        "ended_at": None,
        "required_gates": required_gates,
        "gate_results": make_gate_results(required_gates),
        "environment_health": {
            "status": "not-run",
            "checked_at": None,
            "checks": {},
        },
    }
elif action == "configure-gates":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("confirmed_at"):
        raise SystemExit("Required gates cannot change after plan confirmation.")
    data["required_gates"] = required_gates
    data["gate_results"] = make_gate_results(required_gates)
    data["session_id"] = session_id
elif action == "confirm-plan":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    data["confirmed_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "approve-commit":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    if not data.get("confirmed_at"):
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
    required = data.get("required_gates", ["review"])
    results = data.get("gate_results", {})
    expected = {
        "figma_ui": "pass",
        "review": "pass",
        "runtime": "runtime-verified",
    }
    blocked = []
    for gate in required:
        actual = results.get(gate, {}).get("status")
        if actual != expected[gate]:
            blocked.append(f"{gate}={actual or 'missing'} (requires {expected[gate]})")
    if blocked:
        raise SystemExit("Required gate(s) unresolved: " + ", ".join(blocked))
    data["commit_approved_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "end":
    if not data:
        data = {"session_id": session_id, "active": False}
    data["session_id"] = session_id
    data["active"] = False
    data["ended_at"] = timestamp
else:
    raise SystemExit(f"Unsupported action: {action}")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(path)
PY
}

record_environment() {
  local report_file="$1"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$report_file" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
report_path = Path(sys.argv[3])
checked_at = sys.argv[4]

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
report = json.loads(report_path.read_text())
if report.get("producer") != "environment-health-check" or report.get("schema_version") != 1:
    raise SystemExit("Environment report was not produced by environment-health-check.")
if report.get("session_id") != session_id:
    raise SystemExit("Environment report belongs to another session.")
checks = report.get("checks")
required = ("debugbridge", "review_mcp", "figma_rest_api")
if not isinstance(checks, dict) or any(name not in checks for name in required):
    raise SystemExit("Environment report is missing required checks.")
if any(checks[name].get("status") not in ("available", "blocked", "not-run") for name in required):
    raise SystemExit("Environment report contains an invalid check status.")
derived_status = "available" if all(checks[name].get("status") == "available" for name in required) else "blocked"
if report.get("status") != derived_status:
    raise SystemExit("Environment report status does not match its checks.")
state["environment_health"] = {
    "status": derived_status,
    "checked_at": checked_at,
    "checks": checks,
}
state["session_id"] = session_id
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
print(state_path)
if derived_status != "available":
    raise SystemExit(1)
PY
}

record_gate() {
  local gate_name="$1"
  local report_file="$2"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$gate_name" "$report_file" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
gate_name = sys.argv[3]
report_path = Path(sys.argv[4])
recorded_at = sys.argv[5]

if gate_name not in ("figma_ui", "review", "runtime"):
    raise SystemExit("Unknown gate. Use figma_ui, review, or runtime.")
if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
if not state.get("confirmed_at"):
    raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
if gate_name not in state.get("required_gates", []):
    raise SystemExit(f"Gate is not required for this session: {gate_name}")
if not report_path.is_file():
    raise SystemExit("Gate report does not exist.")

report = json.loads(report_path.read_text())
if report.get("session_id") != session_id:
    raise SystemExit("Gate report belongs to another session.")
if report.get("gate") != gate_name:
    raise SystemExit("Gate report name does not match --name.")

status = report.get("status")
allowed = {
    "figma_ui": {"pass", "failed", "blocked"},
    "review": {"pass", "revise", "blocked", "failed", "unknown"},
    "runtime": {"runtime-verified", "runtime-failed", "runtime-blocked"},
}
if status not in allowed[gate_name]:
    raise SystemExit(f"Invalid {gate_name} status: {status}")

if gate_name == "figma_ui" and status == "pass":
    gates = report.get("gates")
    expected = [f"G{i}" for i in range(13)]
    if not isinstance(gates, dict) or any(gates.get(name) != "pass" for name in expected):
        raise SystemExit("figma_ui=pass requires G0 through G12 all to be pass.")

evidence = report.get("evidence")
if not isinstance(evidence, str) or not evidence.strip():
    raise SystemExit("Gate report requires bounded evidence text.")
state.setdefault("gate_results", {})[gate_name] = {
    "status": status,
    "evidence": evidence[:1000],
    "recorded_at": recorded_at,
    "report": str(report_path),
}
state["session_id"] = session_id
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
print(state_path)
PY
}

parse_environment_args() {
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report)
        REPORT_FILE="${2:-}"
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
  if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "environment-health requires an existing --report path" >&2
    exit 2
  fi
}

parse_gate_config_args() {
  REQUIRED_GATES=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --required)
        REQUIRED_GATES="${2:-}"
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
  if [[ -z "$REQUIRED_GATES" ]]; then
    echo "configure-gates requires --required" >&2
    exit 2
  fi
}

parse_gate_record_args() {
  GATE_NAME=""
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        GATE_NAME="${2:-}"
        shift 2
        ;;
      --report)
        REPORT_FILE="${2:-}"
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
  if [[ -z "$GATE_NAME" || -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "record-gate requires --name and an existing --report path" >&2
    exit 2
  fi
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  start)
    parse_common_args "$@"
    if [[ "$SESSION_TYPE" != "bug" && "$SESSION_TYPE" != "feature" && "$SESSION_TYPE" != "ui_review" ]]; then
      echo "start requires --type bug|feature|ui_review" >&2
      exit 2
    fi
    write_state "start" "$SESSION_TYPE" "$TASK" "review"
    ;;
  configure-gates)
    parse_gate_config_args "$@"
    write_state "configure-gates" "" "" "$REQUIRED_GATES"
    ;;
  environment-health)
    parse_environment_args "$@"
    record_environment "$REPORT_FILE"
    ;;
  record-gate)
    parse_gate_record_args "$@"
    record_gate "$GATE_NAME" "$REPORT_FILE"
    ;;
  confirm-plan)
    parse_common_args "$@"
    write_state "confirm-plan" "" "$TASK"
    ;;
  approve-commit)
    parse_common_args "$@"
    write_state "approve-commit" "" "$TASK"
    ;;
  end)
    write_state "end" "" ""
    ;;
  status)
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "No dev-flow session."
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
