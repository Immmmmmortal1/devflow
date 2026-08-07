#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/usr/bin/trash "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/scripts"
/bin/cp "$ROOT/scripts/dev-flow-session.sh" "$TMP_ROOT/scripts/dev-flow-session.sh"
/bin/cp "$ROOT/scripts/environment-health-check.sh" "$TMP_ROOT/scripts/environment-health-check.sh"

run_health_for() {
  local session_id="$1"
  DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="/usr/bin/true" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="/usr/bin/true" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="/usr/bin/true" \
    /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run >/dev/null
}

run_for() {
  local session_id="$1"
  shift
  CODEX_THREAD_ID="$session_id" /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" "$@"
}

run_for thread-a start --type feature --task "task a" >/dev/null
run_for thread-b start --type bug --task "task b" >/dev/null
run_for thread-feature-ui start --type feature --task "new ui feature" >/dev/null
run_for thread-review start --type ui_review --task "ui review" >/dev/null
if run_for thread-invalid start --type ui_new --task "must be rejected" >/dev/null 2>&1; then
  echo "FAIL: ui_new must not be an independent session type" >&2
  exit 1
fi
run_health_for thread-a
run_for thread-a confirm-plan >/dev/null
run_for thread-a end >/dev/null

/usr/bin/python3 - "$TMP_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
a_path = root / ".dev-flow" / "sessions" / "thread-a.json"
b_path = root / ".dev-flow" / "sessions" / "thread-b.json"
feature_ui_path = root / ".dev-flow" / "sessions" / "thread-feature-ui.json"
review_path = root / ".dev-flow" / "sessions" / "thread-review.json"

assert a_path.exists(), a_path
assert b_path.exists(), b_path
assert feature_ui_path.exists(), feature_ui_path
assert review_path.exists(), review_path
assert not (root / ".dev-flow" / "session.json").exists()

a = json.loads(a_path.read_text())
b = json.loads(b_path.read_text())
assert a["session_id"] == "thread-a"
assert a["active"] is False
assert a["confirmed_at"] is not None
assert b["session_id"] == "thread-b"
assert b["active"] is True
assert b["confirmed_at"] is None
assert b["task"] == "task b"
feature_ui = json.loads(feature_ui_path.read_text())
review = json.loads(review_path.read_text())
assert feature_ui["type"] == "feature"
assert review["type"] == "ui_review"
PY

echo "PASS: dev-flow sessions are isolated"
