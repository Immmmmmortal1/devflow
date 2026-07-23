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
  scripts/dev-flow-session.sh start --type bug|feature [--task "label"]
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
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$action" "$session_type" "$task" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
session_id = sys.argv[2]
action = sys.argv[3]
session_type = sys.argv[4]
task = sys.argv[5]
timestamp = sys.argv[6]

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
    }
elif action == "confirm-plan":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    data["confirmed_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "approve-commit":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if not data.get("confirmed_at"):
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
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

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  start)
    parse_common_args "$@"
    if [[ "$SESSION_TYPE" != "bug" && "$SESSION_TYPE" != "feature" ]]; then
      echo "start requires --type bug|feature" >&2
      exit 2
    fi
    write_state "start" "$SESSION_TYPE" "$TASK"
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
