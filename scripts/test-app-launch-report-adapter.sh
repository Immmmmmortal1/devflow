#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                  "status":"available","build_run_action":"build_run_device",
                  "build_run_result":"success",
                  "device_transport":"wired","app_launched":True,
                  "build_id":"build-probe-1","device_id":"device-probe-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_health_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

run_for adapter-session start --type feature --level heavy --task "adapter session" >/dev/null
run_for adapter-session configure-gates --required review,runtime >/dev/null
run_for adapter-session confirm-plan >/dev/null

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=adapter-session \
  /bin/bash "$ROOT/scripts/dev-flow.sh" app-launch status >"$TMP_ROOT/status-missing.json" 2>/dev/null; then
  echo "FAIL: app-launch status passed without a recorded report" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/status-missing.json" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["status"] == "blocked", payload
assert payload["evidence"] == "app_launch_report_missing;run_xcodebuildmcp_session_set_defaults_then_show_defaults_then_build_run_device", payload
assert payload["required_tools"] == ["session_set_defaults", "session_show_defaults", "build_run_device"], payload
PY

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=adapter-session \
  /bin/bash "$ROOT/scripts/dev-flow.sh" app-launch template >"$TMP_ROOT/template.json"
/usr/bin/python3 - "$TMP_ROOT/template.json" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["session_id"] == "adapter-session", payload
assert payload["producer"] == "XcodeBuildMCP", payload
PY

if run_health_for adapter-session >/dev/null 2>&1; then
  echo "FAIL: health check passed without a recorded app launch report" >&2
  exit 1
fi

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/adapter-session.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text())
evidence = state["environment_health"]["checks"]["app_launch"]["evidence"]
assert evidence == "app_launch_report_missing;run_xcodebuildmcp_session_set_defaults_then_show_defaults_then_build_run_device", evidence
assert evidence != "app_launch_probe_not_configured"
# 新模型：review_mcp 独立探针，app_launch blocked 不影响 review_mcp
assert state["environment_health"]["checks"]["review_mcp"]["status"] == "available", state
PY

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=adapter-session \
  /usr/bin/python3 - "$TMP_ROOT/adapter-launch-source.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 2, "session_id": "adapter-session",
    "status": "available", "build_run_action": "build_run_device",
    "build_run_result": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": "build-adapter-1", "device_id": "device-adapter-1",
}) + "\n")
PY
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=adapter-session \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT/adapter-launch-source.json" >/dev/null
run_health_for adapter-session >/dev/null

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=other-session \
  run_health_for other-session >/dev/null 2>&1; then
  echo "FAIL: health check accepted another session's app launch report" >&2
  exit 1
fi

run_for restart-session start --type bug --level heavy --task "restart clears stale report" >/dev/null
run_for restart-session configure-gates --required review,runtime >/dev/null
/usr/bin/python3 - "$TMP_ROOT/restart-launch-source.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 2, "session_id": "restart-session",
    "status": "available", "build_run_action": "build_run_device",
    "build_run_result": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": "build-restart-1", "device_id": "device-restart-1",
}) + "\n")
PY
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=restart-session \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT/restart-launch-source.json" >/dev/null
run_for restart-session start --type bug --level heavy --task "restart clears stale report" >/dev/null
if [[ -f "$TMP_ROOT/.dev-flow/sessions/restart-session.app-launch.json" ]]; then
  echo "FAIL: dev-flow start did not clear stale app launch report" >&2
  exit 1
fi

cat > "$TMP_ROOT/bin/custom-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                  "status":"available","build_run_action":"build_run_device",
                  "build_run_result":"success",
                  "device_transport":"wired","app_launched":True,
                  "build_id":"build-override-1","device_id":"device-override-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/custom-probe"

run_for override-session start --type feature --level heavy --task "override probe" >/dev/null
run_for override-session configure-gates --required review,runtime >/dev/null
run_for override-session confirm-plan >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=override-session \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/custom-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null; then
  echo "FAIL: DEV_FLOW_APP_LAUNCH_HEALTH_CMD override stopped working" >&2
  exit 1
fi

echo "PASS: session-scoped app launch report adapter works"
