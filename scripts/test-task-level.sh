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
/bin/chmod +x "$TMP_ROOT/bin/ok-probe" "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

# 只设置 review_mcp 探针；其余探针不设（用于验证 level 裁剪后不查它们）
run_health_review_only() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

# 全 4 项探针（heavy 用）
run_health_all() {
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

# 用例 1：trivial 只要求 review_mcp，其他 not-required，confirm → env → available
run_for trivial start --type feature --level trivial --task "trivial task" >/dev/null
run_for trivial confirm-plan >/dev/null
run_health_review_only trivial >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/trivial.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["level"] == "trivial", state
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert checks["review_mcp"]["status"] == "available", checks
assert checks["app_launch"]["status"] == "not-required", checks
assert checks["debugbridge"]["status"] == "not-required", checks
assert checks["figma_rest_api"]["status"] == "not-required", checks
assert state["confirmed_at"] is not None, state
PY

# 用例 2：trivial 禁止 configure 加 runtime
run_for trivial-g start --type bug --level trivial --task "trivial gates" >/dev/null
if run_for trivial-g configure-gates --required review,runtime >/dev/null 2>&1; then
  echo "FAIL: trivial session allowed runtime gate" >&2
  exit 1
fi
run_for trivial-g configure-gates --required review >/dev/null

# 用例 3：standard（默认）要求 app_launch + review_mcp；app_launch 缺 → blocked
run_for std start --type feature --task "standard task" >/dev/null
run_for std confirm-plan >/dev/null
if run_health_review_only std >/dev/null 2>&1; then
  echo "FAIL: standard environment passed without app_launch" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/std.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["level"] == "standard", state
assert state["environment_health"]["status"] == "blocked", state["environment_health"]
assert checks["app_launch"]["status"] == "blocked", checks
assert checks["review_mcp"]["status"] == "not-run", checks
assert checks["debugbridge"]["status"] == "not-required", checks
PY

# 用例 4：heavy 要求全 4 项；全探针通过 → available；缺 figma → blocked
run_for hvy start --type feature --level heavy --task "heavy task" >/dev/null
run_for hvy confirm-plan >/dev/null
run_health_all hvy >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/hvy.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["level"] == "heavy", state
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert all(checks[n]["status"] == "available" for n in ("app_launch","debugbridge","review_mcp","figma_rest_api")), checks
PY

# 用例 4b：heavy 缺 figma 探针 → blocked（figma 是必需项）
run_for hvy-figma start --type feature --level heavy --task "heavy no figma" >/dev/null
run_for hvy-figma confirm-plan >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=hvy-figma \
  DEV_FLOW_TEST_MODE=1 \
  FIGMA_REST_TOKEN= \
  FIGMA_ACCESS_TOKEN= \
  FIGMA_REST_API_SKILL_ROOT="$TMP_ROOT/nonexistent-figma-skill" \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: heavy environment passed without figma probe" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/hvy-figma.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["environment_health"]["status"] == "blocked", state["environment_health"]
assert checks["figma_rest_api"]["status"] == "blocked", checks
PY

# 用例 5：非法 level → start 拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=bad /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
  start --type feature --level bogus --task "bad level" >/dev/null 2>&1; then
  echo "FAIL: invalid level accepted" >&2
  exit 1
fi

# 用例 6：ui_review 必须 heavy（trivial/standard 拒绝）
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ui-triv /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
  start --type ui_review --level trivial --task "ui trivial" >/dev/null 2>&1; then
  echo "FAIL: ui_review accepted trivial level" >&2
  exit 1
fi
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ui-std /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
  start --type ui_review --level standard --task "ui standard" >/dev/null 2>&1; then
  echo "FAIL: ui_review accepted standard level" >&2
  exit 1
fi
run_for ui-hvy start --type ui_review --level heavy --task "ui heavy" >/dev/null

# 用例 7：--level 缺值 → 拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=empty-level /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
  start --type feature --level --task "empty level" >/dev/null 2>&1; then
  echo "FAIL: empty level accepted" >&2
  exit 1
fi

# 用例 8：standard 不能 configure 重型 gate（runtime/figma_ui/ui_parity 要求 heavy）
run_for std-gates start --type feature --task "standard gates" >/dev/null
if run_for std-gates configure-gates --required review,runtime >/dev/null 2>&1; then
  echo "FAIL: standard session allowed runtime gate" >&2
  exit 1
fi
run_for hvy-gates start --type feature --level heavy --task "heavy gates" >/dev/null
run_for hvy-gates configure-gates --required review,runtime >/dev/null

# 用例 9：trivial 完整链路：confirm → env → review pass → approve-commit
run_for tri-full start --type feature --level trivial --task "trivial full chain" >/dev/null
run_for tri-full confirm-plan >/dev/null
run_health_review_only tri-full >/dev/null
/usr/bin/python3 - "$TMP_ROOT" "tri-full" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
session_id = sys.argv[2]
(root / f"review-{session_id}.json").write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
run_for tri-full record-gate --name review --report "$TMP_ROOT/review-tri-full.json" >/dev/null
run_for tri-full approve-commit >/dev/null

# 用例 10：环境门禁后移——confirm-plan 不要求 environment-health；confirm 后未跑 env 时
# record-gate/approve-commit/commit/testflight 失败；跑 env 后恢复
run_for noenv start --type feature --level trivial --task "no env" >/dev/null
# confirm-plan 不需要先 environment-health（直接通过）
run_for noenv confirm-plan >/dev/null
/usr/bin/python3 - "$TMP_ROOT/review-noenv.json" "noenv" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
}) + "\n")
PY
# confirm 后未跑 env：record-gate/approve-commit/commit/testflight 均失败（环境门禁）
if run_for noenv record-gate --name review --report "$TMP_ROOT/review-noenv.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed without environment health after confirm" >&2
  exit 1
fi
if run_for noenv approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed without environment health after confirm" >&2
  exit 1
fi
if run_for noenv commit --message "should fail" >/dev/null 2>&1; then
  echo "FAIL: commit passed without environment health after confirm" >&2
  exit 1
fi
if run_for noenv testflight >/dev/null 2>&1; then
  echo "FAIL: testflight passed without environment health after confirm" >&2
  exit 1
fi
# 跑 env 后 available，record-gate/approve-commit 通过
run_health_review_only noenv >/dev/null
run_for noenv record-gate --name review --report "$TMP_ROOT/review-noenv.json" >/dev/null
run_for noenv approve-commit >/dev/null

# 用例 11：confirm 前误跑 environment-health 失败（不能写有效 state）；confirm 后重跑才成功
run_for preenv start --type feature --level trivial --task "pre-confirm env" >/dev/null
if run_health_review_only preenv >/dev/null 2>&1; then
  echo "FAIL: environment-health ran before confirm-plan" >&2
  exit 1
fi
# state 不应被写入有效 environment_health（record_environment 拒绝 confirm 前写入）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/preenv.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["environment_health"]["status"] == "not-run", state["environment_health"]
assert state["environment_health"]["checked_at"] is None, state["environment_health"]
PY
# confirm 后重新跑 env 才成功
run_for preenv confirm-plan >/dev/null
run_health_review_only preenv >/dev/null

echo "PASS: task level trims environment checks and gate configuration"
