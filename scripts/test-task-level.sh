#!/usr/bin/env bash
# task-level + capability 模型测试：
# - --level 仍用于描述任务复杂度，但不再限制 gate 配置
# - required_gates 决定哪些 capability 被 probe（非 level 直接决定）
# - app-launch v2 schema
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

# git init（record-gate 要求项目为 git 仓库）
/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_ROOT" init -q && /usr/bin/git -C "$TMP_ROOT" checkout -qb main; }
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'base\n' > "$TMP_ROOT/base.txt"
/usr/bin/git -C "$TMP_ROOT" add base.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "init"
printf '.dev-flow/\nbin/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:3442e1b8bf278f94262e920076cfb201202958e4d5b5c43be1af25767202a7e9",
                   "source":"project"}))
PY
EOF

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"
cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                  "status":"available","build_run_action":"build_run_device",
                  "build_run_result":"success",
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

# 只设置 review_mcp 探针；其余探针不设（用于验证 capability 裁剪后不查它们）
run_health_review_only() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

# 全 4 项探针（heavy + all gates 用）
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

# 用例 1：trivial docs → required_gates=[]，env 四项 not-required + available（fast-path）
run_for trivial start --type feature --level trivial --trivial-kind docs --task "trivial docs" >/dev/null
run_for trivial confirm-plan >/dev/null
run_health_review_only trivial >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/trivial.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["level"] == "trivial", state
assert state["schema_version"] == 2, state
assert state["fast_path"] is True, state
assert state["required_gates"] == [], state
assert state["trivial"]["kind"] == "docs", state
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert checks["review_mcp"]["status"] == "not-required", checks
assert checks["app_launch"]["status"] == "not-required", checks
assert checks["debugbridge"]["status"] == "not-required", checks
assert checks["figma_rest_api"]["status"] == "not-required", checks
assert state["confirmed_at"] is not None, state
PY

# 用例 2：trivial 禁止 configure-gates（fast-path 不走 gate 配置）
run_for trivial-g start --type bug --level trivial --trivial-kind docs --task "trivial no cfg" >/dev/null
if run_for trivial-g configure-gates --required review,runtime >/dev/null 2>&1; then
  echo "FAIL: trivial configure-gates accepted" >&2
  exit 1
fi
if run_for trivial-g configure-gates --required review >/dev/null 2>&1; then
  echo "FAIL: trivial configure-gates accepted" >&2
  exit 1
fi

# 用例 3：standard + review only → review_mcp available，app_launch not-required
# （新模型：level 不直接决定 required checks；required_gates 决定。standard 默认只有 review gate。）
run_for std start --type feature --task "standard task" >/dev/null
run_for std confirm-plan >/dev/null
run_health_review_only std >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/std.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["level"] == "standard", state
# review only → review_mcp available，其余 not-required
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert checks["review_mcp"]["status"] == "available", checks
assert checks["app_launch"]["status"] == "not-required", checks
assert checks["debugbridge"]["status"] == "not-required", checks
assert checks["figma_rest_api"]["status"] == "not-required", checks
PY

# 用例 3b：heavy + review,runtime → app_launch + debugbridge + review_mcp required；
#          app_launch 缺 → blocked
run_for std-rt start --type feature --level heavy --task "standard+runtime" >/dev/null
run_for std-rt configure-gates --required review,runtime >/dev/null
run_for std-rt confirm-plan >/dev/null
# 只设 review_mcp probe，不设 app_launch → app_launch blocked → env blocked
if run_health_review_only std-rt >/dev/null 2>&1; then
  echo "FAIL: review+runtime environment passed without app_launch" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/std-rt.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["environment_health"]["status"] == "blocked", state["environment_health"]
assert checks["app_launch"]["status"] == "blocked", checks
# 新模型：review_mcp 独立探针，app_launch blocked 不影响 review_mcp
assert checks["review_mcp"]["status"] == "available", checks
# debugbridge 依赖 app_launch：app_launch blocked → debugbridge not-run
assert checks["debugbridge"]["status"] == "not-run", checks
PY

# 用例 4：heavy + review,runtime,figma_ui → 全 4 项 required；全探针通过 → available
run_for hvy start --type feature --level heavy --task "heavy task" >/dev/null
run_for hvy configure-gates --required review,runtime,figma_ui >/dev/null
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

# 用例 4b：heavy + review,runtime,figma_ui + figma blocked → env blocked
run_for hvy-figma start --type feature --level heavy --task "heavy no figma" >/dev/null
run_for hvy-figma configure-gates --required review,runtime,figma_ui >/dev/null
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

# 用例 6：ui_review 不再要求 --level heavy（能力模型：required_gates 决定必需能力）
# ui_review 的 confirm-plan 仍要求 review,runtime,ui_parity gates
run_for ui-std start --type ui_review --level standard --task "ui standard" >/dev/null
run_for ui-hvy start --type ui_review --level heavy --task "ui heavy" >/dev/null

# 用例 7：--level 缺值 → 拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=empty-level /bin/bash "$ROOT/scripts/dev-flow-session.sh" \
  start --type feature --level --task "empty level" >/dev/null 2>&1; then
  echo "FAIL: empty level accepted" >&2
  exit 1
fi

# 用例 8：standard 也能 configure 重型 gate（能力模型：--level 不限制 gate 配置）
run_for std-gates start --type feature --task "standard gates" >/dev/null
run_for std-gates configure-gates --required review,runtime >/dev/null
run_for hvy-gates start --type feature --level heavy --task "heavy gates" >/dev/null
run_for hvy-gates configure-gates --required review,runtime >/dev/null

# 用例 9：trivial docs 完整 fast-path 链路：confirm → env → stage → validate-trivial → approve
run_for tri-full start --type feature --level trivial --trivial-kind docs --task "trivial full chain" >/dev/null
run_for tri-full confirm-plan >/dev/null
run_health_review_only tri-full >/dev/null
printf '# Notes\n\ntrivial docs\n' > "$TMP_ROOT/NOTES.md"
/usr/bin/git -C "$TMP_ROOT" add NOTES.md
run_for tri-full validate-trivial >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/tri-full.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tv = state["trivial_validation"]
assert tv["result"] == "pass", tv
assert tv["kind"] == "docs", tv
assert tv["head"], tv
assert tv["index_tree"], tv
assert tv["scope_digest"].startswith("sha256:"), tv
assert len(tv["entries"]) == 1, tv
assert tv["entries"][0]["path"] == "NOTES.md", tv["entries"]
PY
run_for tri-full approve-commit >/dev/null

# 用例 10：环境门禁后移——confirm-plan 不要求 environment-health；confirm 后未跑 env 时
# validate-trivial/approve-commit/commit/testflight 失败；跑 env 后恢复（trivial 无 review gate）
run_for noenv start --type feature --level trivial --trivial-kind docs --task "no env" >/dev/null
run_for noenv confirm-plan >/dev/null
printf '# Doc\n\nbody\n' > "$TMP_ROOT/DOC.md"
/usr/bin/git -C "$TMP_ROOT" add DOC.md
if run_for noenv validate-trivial >/dev/null 2>&1; then
  echo "FAIL: validate-trivial passed without environment health after confirm" >&2
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
run_health_review_only noenv >/dev/null
run_for noenv validate-trivial >/dev/null
run_for noenv approve-commit >/dev/null

# 用例 11：confirm 前误跑 environment-health 失败；confirm 后重跑才成功
run_for preenv start --type feature --level trivial --trivial-kind docs --task "pre-confirm env" >/dev/null
if run_health_review_only preenv >/dev/null 2>&1; then
  echo "FAIL: environment-health ran before confirm-plan" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/preenv.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["environment_health"]["status"] == "not-run", state["environment_health"]
assert state["environment_health"]["checked_at"] is None, state["environment_health"]
PY
run_for preenv confirm-plan >/dev/null
run_health_review_only preenv >/dev/null

echo "PASS: task level + capability model (--level is descriptive, required_gates drives probes)"
