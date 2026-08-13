#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/scripts" "$TMP_ROOT/bin"
/bin/cp "$ROOT/scripts/dev-flow-session.sh" "$TMP_ROOT/scripts/dev-flow-session.sh"
/bin/cp "$ROOT/scripts/environment-health-check.sh" "$TMP_ROOT/scripts/environment-health-check.sh"
/bin/cp "$ROOT/scripts/resolve-dev-flow-session-id.sh" "$TMP_ROOT/scripts/resolve-dev-flow-session-id.sh"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_ROOT/bin/fail-probe" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe" "$TMP_ROOT/bin/fail-probe" "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" "$@"
}

run_health_for() {
  local session_id="$1"
  shift
  DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run "$@"
}

record_review_for() {
  local session_id="$1"
  /usr/bin/python3 - "$TMP_ROOT/review-$session_id.json" "$session_id" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "test",
    "schema_version": 1,
    "session_id": sys.argv[2],
    "gate": "review",
    "status": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
  DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" \
    record-gate --name review --report "$TMP_ROOT/review-$session_id.json" >/dev/null
}

run_for healthy start --type feature --task "healthy task" >/dev/null
if run_for healthy confirm-plan >/dev/null 2>&1; then
  echo "FAIL: confirm-plan bypassed environment health" >&2
  exit 1
fi
run_health_for healthy >/dev/null
run_for healthy confirm-plan >/dev/null
if run_for healthy approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit bypassed required review gate" >&2
  exit 1
fi
record_review_for healthy
run_for healthy approve-commit >/dev/null

run_for blocked start --type bug --task "blocked task" >/dev/null
if DEV_FLOW_SESSION_ID=blocked \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/fail-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: blocked environment health returned success" >&2
  exit 1
fi
if run_for blocked confirm-plan >/dev/null 2>&1; then
  echo "FAIL: blocked environment reached confirm-plan" >&2
  exit 1
fi

run_for invalid-launch start --type ui_review --task "invalid launch evidence" >/dev/null
if DEV_FLOW_SESSION_ID=invalid-launch \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: exit-code-only App launch probe was accepted" >&2
  exit 1
fi

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
healthy = json.loads((root / "healthy.json").read_text())
blocked = json.loads((root / "blocked.json").read_text())
assert healthy["environment_health"]["status"] == "available"
assert healthy["environment_health"]["checks"]["app_launch"]["status"] == "available"
assert healthy["environment_health"]["checks"]["debugbridge"]["status"] == "available"
assert healthy["confirmed_at"] is not None
assert healthy["commit_approved_at"] is not None
assert blocked["environment_health"]["status"] == "blocked"
assert blocked["environment_health"]["checks"]["debugbridge"]["status"] == "blocked"
assert blocked["confirmed_at"] is None
PY

echo "PASS: environment health is recorded and required before confirmation/commit"
