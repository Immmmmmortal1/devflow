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
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True}))
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
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

run_for adapter-session start --type feature --task "adapter session" >/dev/null

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
assert evidence == "invalid_or_failed_xcodebuildmcp_app_launch_report", evidence
assert evidence != "app_launch_probe_not_configured"
PY

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=adapter-session \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record >/dev/null
run_health_for adapter-session >/dev/null
run_for adapter-session confirm-plan >/dev/null

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=other-session \
  run_health_for other-session >/dev/null 2>&1; then
  echo "FAIL: health check accepted another session's app launch report" >&2
  exit 1
fi

run_for restart-session start --type bug --task "restart clears stale report" >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=restart-session \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record >/dev/null
run_for restart-session start --type bug --task "restart clears stale report" >/dev/null
if [[ -f "$TMP_ROOT/.dev-flow/sessions/restart-session.app-launch.json" ]]; then
  echo "FAIL: dev-flow start did not clear stale app launch report" >&2
  exit 1
fi

cat > "$TMP_ROOT/bin/custom-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/custom-probe"

run_for override-session start --type feature --task "override probe" >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=override-session \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/custom-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null; then
  echo "FAIL: DEV_FLOW_APP_LAUNCH_HEALTH_CMD override stopped working" >&2
  exit 1
fi

echo "PASS: session-scoped app launch report adapter works"
