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
                  "device_transport":"wired","app_launched":True,
                  "build_id":"build-test-1","device_id":"device-test-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe" "$TMP_ROOT/bin/fail-probe" "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_health_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

record_review_for() {
  local session_id="$1"
  /usr/bin/python3 - "$TMP_ROOT/review-$session_id.json" "$session_id" <<'PY'
import json
import sys
from pathlib import Path
# review gate 要求 producer=code-review-workflow + reviewer_result=pass + schema_version=1
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow",
    "schema_version": 1,
    "session_id": sys.argv[2],
    "gate": "review",
    "status": "pass",
    "reviewer_result": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
    record-gate --name review --report "$TMP_ROOT/review-$session_id.json" >/dev/null
}

run_for healthy start --type feature --task "healthy task" >/dev/null
# 环境门禁后移：confirm-plan 不再要求 environment-health
run_for healthy confirm-plan >/dev/null
# 写 review pass 报告（confirm 后、未跑 env 时 record-gate 应失败）
/usr/bin/python3 - "$TMP_ROOT/review-healthy.json" healthy <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
if run_for healthy record-gate --name review --report "$TMP_ROOT/review-healthy.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed without environment health after confirm" >&2
  exit 1
fi
if run_for healthy approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed without environment health after confirm" >&2
  exit 1
fi
# 跑 env 后 available，record-gate/approve-commit 通过
run_health_for healthy >/dev/null
run_for healthy record-gate --name review --report "$TMP_ROOT/review-healthy.json" >/dev/null
run_for healthy approve-commit >/dev/null

run_for blocked start --type bug --level heavy --task "blocked task" >/dev/null
# 环境门禁后移：confirm-plan 不要求 env，即使未跑 env 也能 confirm
run_for blocked confirm-plan >/dev/null
# confirm 后跑 env，debugbridge blocked → env blocked
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=blocked \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/fail-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: blocked environment health returned success" >&2
  exit 1
fi
# env blocked 时 approve-commit 失败
if run_for blocked approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed with blocked environment" >&2
  exit 1
fi

run_for invalid-launch start --type ui_review --level heavy --task "invalid launch evidence" >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=invalid-launch \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
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
# standard 级别不查 debugbridge/figma（not-required），只要求 app_launch + review_mcp
assert healthy["environment_health"]["checks"]["debugbridge"]["status"] == "not-required"
assert healthy["environment_health"]["checks"]["figma_rest_api"]["status"] == "not-required"
assert healthy["confirmed_at"] is not None
assert healthy["commit_approved_at"] is not None
assert blocked["environment_health"]["status"] == "blocked"
assert blocked["environment_health"]["checks"]["debugbridge"]["status"] == "blocked"
assert blocked["confirmed_at"] is not None  # 环境门禁后移：blocked 也能 confirm
PY

# 生产模式（未设 DEV_FLOW_TEST_MODE）下忽略 DEV_FLOW_*_HEALTH_CMD 覆盖，仍走默认探针
# 用 heavy 级别验证全 4 项都走默认探针
run_for prod-mode start --type feature --level heavy --task "prod mode health cmd ignored" >/dev/null
run_for prod-mode confirm-plan >/dev/null
# 先写入合法 app-launch 报告（生产模式 app_launch 走 read-app-launch-report.sh 读这个文件）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/prod-mode.app-launch.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 1, "session_id": "prod-mode",
    "status": "available", "build_run_device": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": "build-prod-1", "device_id": "device-prod-1",
}) + "\n")
PY
# 设置 4 个 HEALTH_CMD=/usr/bin/true 但不设 DEV_FLOW_TEST_MODE：应被忽略，走默认探针
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=prod-mode \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1 || true
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/prod-mode.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
app_launch = state["environment_health"]["checks"]["app_launch"]
# app_launch 应来自 read-app-launch-report.sh（evidence 含 build_id/device_id），而非 /usr/bin/true（probe_exit_0）
assert app_launch["status"] == "available", app_launch
assert "probe_exit_0" not in app_launch["evidence"], app_launch["evidence"]
assert "build_id=build-prod-1" in app_launch["evidence"], app_launch["evidence"]
# debugbridge 应来自默认 validate-bridge-session.sh（blocked），而非 /usr/bin/true（probe_exit_0）
debugbridge = state["environment_health"]["checks"]["debugbridge"]
assert debugbridge["status"] == "blocked", debugbridge
assert "probe_exit_0" not in debugbridge["evidence"], debugbridge["evidence"]
PY

# 深度防御：confirm 前跑过的 env（checked_at < confirmed_at）不能用于敏感动作
run_for stale start --type feature --level trivial --task "stale env" >/dev/null
run_for stale confirm-plan >/dev/null
# 手动构造 state：env available 但 checked_at 远早于 confirmed_at（模拟 confirm 前跑过的 env）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/stale.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
state = json.loads(p.read_text())
state["environment_health"] = {
    "status": "available",
    "checked_at": "2020-01-01T00:00:00Z",
    "checks": {
        "app_launch": {"status": "not-required", "evidence": "skipped_for_trivial_level"},
        "debugbridge": {"status": "not-required", "evidence": "skipped_for_level"},
        "review_mcp": {"status": "available", "evidence": "probe_exit_0"},
        "figma_rest_api": {"status": "not-required", "evidence": "skipped_for_level"},
    },
}
p.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
PY
/usr/bin/python3 - "$TMP_ROOT/review-stale.json" "stale" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
# record-gate/approve-commit 失败（checked_at < confirmed_at，深度防御）
if run_for stale record-gate --name review --report "$TMP_ROOT/review-stale.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed with env checked before confirm-plan" >&2
  exit 1
fi
if run_for stale approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed with env checked before confirm-plan" >&2
  exit 1
fi
# confirm 后重新跑 env（checked_at >= confirmed_at）后通过
run_health_for stale >/dev/null
run_for stale record-gate --name review --report "$TMP_ROOT/review-stale.json" >/dev/null
run_for stale approve-commit >/dev/null

echo "PASS: environment health runs after confirm-plan; required before gates/commit"
