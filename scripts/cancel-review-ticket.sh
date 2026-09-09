#!/usr/bin/env bash
# 作废当前 session 的未消费 review ticket。
# 必须先作废才能重新签发（issue-review-ticket.sh / run-review-fallback.sh 拒绝覆盖未消费 ticket）。
#
# Usage: bash scripts/cancel-review-ticket.sh [--reason <text>] [--session-id <id>]
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"

REASON=""
SESSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)
      REASON="${2:-}"
      shift 2
      ;;
    --session-id)
      SESSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/cancel-review-ticket.sh [--reason <text>] [--session-id <id>]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$SESSION_OVERRIDE" ]]; then
  if [[ ! "$SESSION_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid session id: $SESSION_OVERRIDE" >&2
    exit 2
  fi
  SESSION_ID="$SESSION_OVERRIDE"
else
  SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
fi
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No active session: $STATE_FILE" >&2
  exit 1
fi

/usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$REASON" "$DEV_FLOW_PROJECT_ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
reason = sys.argv[3] or "manual cancel"
trusted_root = sys.argv[4]
source_root = sys.argv[5]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

state = json.loads(state_path.read_text())
rt = state.get("review_ticket")
if not rt:
    raise SystemExit("no review_ticket in session state; nothing to cancel.")
if rt.get("consumed"):
    raise SystemExit("review_ticket is already consumed; no need to cancel.")
if rt.get("cancelled"):
    raise SystemExit(f"review_ticket is already cancelled at {rt.get('cancelled_at')}.")

cancelled_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rt["cancelled"] = True
rt["cancelled_at"] = cancelled_at
rt["cancel_reason"] = reason
state["review_ticket"] = rt
safe_atomic_write_json(trusted_root, state_path, state)

# 删除 ticket artifact（如果存在且是普通文件）
ticket_path = Path(rt.get("ticket_path") or "")
if ticket_path and ticket_path.is_file() and not ticket_path.is_symlink():
    try:
        ticket_path.unlink()
    except OSError:
        pass

print(json.dumps({
    "session_id": session_id,
    "cancelled": True,
    "cancelled_at": cancelled_at,
    "reason": reason,
}, ensure_ascii=False, indent=2))
PY
