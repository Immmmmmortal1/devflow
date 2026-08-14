#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/app-launch-probe"

run_health_for() {
  local session_id="$1"
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="/usr/bin/true" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="/usr/bin/true" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="/usr/bin/true" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
}

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" CODEX_THREAD_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
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

# Cursor conversation ids must isolate without DEV_FLOW_SESSION_ID / CODEX_THREAD_ID.
  CURSOR_CONVERSATION_ID=bd225fc5-4f36-47e2-876e-8d9d125033a1 \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type ui_review --task "cursor chat a" >/dev/null
CURSOR_CONVERSATION_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type bug --task "cursor chat b" >/dev/null

# Inside Cursor, missing conversation id must not fall back to shared local.json.
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" CURSOR_AGENT=1 DEV_FLOW_SESSION_ID= CODEX_THREAD_ID= CURSOR_CONVERSATION_ID= \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" status >/dev/null 2>&1; then
  echo "FAIL: Cursor agent without conversation id must not use local fallback" >&2
  exit 1
fi

/usr/bin/python3 - "$TMP_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
a_path = root / ".dev-flow" / "sessions" / "thread-a.json"
b_path = root / ".dev-flow" / "sessions" / "thread-b.json"
feature_ui_path = root / ".dev-flow" / "sessions" / "thread-feature-ui.json"
review_path = root / ".dev-flow" / "sessions" / "thread-review.json"
cursor_a = root / ".dev-flow" / "sessions" / "bd225fc5-4f36-47e2-876e-8d9d125033a1.json"
cursor_b = root / ".dev-flow" / "sessions" / "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"

assert a_path.exists(), a_path
assert b_path.exists(), b_path
assert feature_ui_path.exists(), feature_ui_path
assert review_path.exists(), review_path
assert cursor_a.exists(), cursor_a
assert cursor_b.exists(), cursor_b
assert not (root / ".dev-flow" / "session.json").exists()
assert not (root / ".dev-flow" / "sessions" / "local.json").exists()

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
assert json.loads(cursor_a.read_text())["task"] == "cursor chat a"
assert json.loads(cursor_b.read_text())["task"] == "cursor chat b"
PY

resolved="$(
  CURSOR_CONVERSATION_ID=bd225fc5-4f36-47e2-876e-8d9d125033a1 \
    /bin/bash "$ROOT/scripts/resolve-dev-flow-session-id.sh"
)"
if [[ "$resolved" != "bd225fc5-4f36-47e2-876e-8d9d125033a1" ]]; then
  echo "FAIL: resolve-dev-flow-session-id.sh ignored CURSOR_CONVERSATION_ID: $resolved" >&2
  exit 1
fi

echo "PASS: dev-flow sessions are isolated"
