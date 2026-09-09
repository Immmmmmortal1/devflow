#!/usr/bin/env bash
set -euo pipefail

# 覆盖 environment-health capability-based 模型的核心场景（requirement H 1-6）：
# 1. review-only：available，app_launch/debugbridge/figma not-required
# 2. review+runtime 缺 launch → blocked，reviewer 仍 available
# 3. review+figma_ui 缺 figma → blocked，runtime capabilities required
# 4. review+ui_parity 缺 figma → blocked
# 5. 非必需项状态契约（非 required 必须 not-required；伪造 available 被拒）
# 6. start 清旧 launch report

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"
printf '%s\n' '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$TMP_ROOT/opencode.json"

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
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                   "status":"available","build_run_action":"build_run_device","build_run_result":"success",
                   "device_transport":"wired","app_launched":True,
                   "build_id":"build-cap-1","device_id":"device-cap-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe" "$TMP_ROOT/bin/fail-probe" "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_health() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_OPENCODE_CONFIG="$TMP_ROOT/opencode.json" \
    OPENROUTER_API_KEY=sk-test \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

# ── 场景 1：review-only 无 launch/debug/figma 仍 available；三项 not-required ──
run_for cap-review-only start --type feature --task "review only" >/dev/null
run_for cap-review-only confirm-plan >/dev/null
run_health cap-review-only >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/cap-review-only.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
eh = state["environment_health"]
assert eh["status"] == "available", eh
checks = eh["checks"]
assert checks["review_mcp"]["status"] == "available", checks["review_mcp"]
assert checks["app_launch"]["status"] == "not-required", checks["app_launch"]
assert checks["debugbridge"]["status"] == "not-required", checks["debugbridge"]
assert checks["figma_rest_api"]["status"] == "not-required", checks["figma_rest_api"]
# required_capabilities 只有 review_mcp
assert eh["checks"] is not None
PY
echo "PASS: scenario 1 — review-only available, three not-required"

# ── 场景 2：review+runtime 缺 launch → blocked，reviewer 仍 available ──
run_for cap-runtime-blocked start --type bug --task "runtime blocked" >/dev/null
run_for cap-runtime-blocked configure-gates --required review,runtime >/dev/null
run_for cap-runtime-blocked confirm-plan >/dev/null
# app_launch fail-probe（没有合法 launch report）
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-runtime-blocked \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/fail-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_OPENCODE_CONFIG="$TMP_ROOT/opencode.json" \
  OPENROUTER_API_KEY=sk-test \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: scenario 2 — health should be blocked when app_launch fails" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/cap-runtime-blocked.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
eh = state["environment_health"]
assert eh["status"] == "blocked", eh
checks = eh["checks"]
# app_launch 失败（fail-probe exit 1 → blocked）
assert checks["app_launch"]["status"] == "blocked", checks["app_launch"]
# debugbridge not-run（依赖 app_launch，不探测）
assert checks["debugbridge"]["status"] == "not-run", checks["debugbridge"]
# reviewer 独立探活，仍 available（不被 app_launch 短路）
assert checks["review_mcp"]["status"] == "available", checks["review_mcp"]
# figma not-required（runtime 不需要 figma）
assert checks["figma_rest_api"]["status"] == "not-required", checks["figma_rest_api"]
PY
echo "PASS: scenario 2 — review+runtime blocked, reviewer still available"

# ── 场景 3：review+figma_ui 缺 figma → blocked，runtime capabilities required ──
run_for cap-figma-blocked start --type feature --task "figma blocked" >/dev/null
run_for cap-figma-blocked configure-gates --required review,figma_ui >/dev/null
run_for cap-figma-blocked confirm-plan >/dev/null
# figma 缺 skill + 缺 token → blocked；app_launch+debugbridge 用 ok-probe
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-figma-blocked \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_OPENCODE_CONFIG="$TMP_ROOT/opencode.json" \
  OPENROUTER_API_KEY=sk-test \
  FIGMA_REST_API_SKILL_ROOT="$TMP_ROOT/no-figma-skill" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: scenario 3 — health should be blocked when figma is missing" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/cap-figma-blocked.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
eh = state["environment_health"]
assert eh["status"] == "blocked", eh
checks = eh["checks"]
# figma blocked（skill 缺失）
assert checks["figma_rest_api"]["status"] == "blocked", checks["figma_rest_api"]
# runtime capabilities required 且 available（不被 figma 短路）
assert checks["app_launch"]["status"] == "available", checks["app_launch"]
assert checks["debugbridge"]["status"] == "available", checks["debugbridge"]
# reviewer 独立，仍 available
assert checks["review_mcp"]["status"] == "available", checks["review_mcp"]
PY
echo "PASS: scenario 3 — review+figma_ui blocked, runtime capabilities still required"

# ── 场景 4：review+ui_parity 缺 figma → blocked ──
run_for cap-parity-blocked start --type ui_review --task "parity blocked" >/dev/null
run_for cap-parity-blocked configure-gates --required review,runtime,ui_parity >/dev/null
run_for cap-parity-blocked confirm-plan >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-parity-blocked \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_OPENCODE_CONFIG="$TMP_ROOT/opencode.json" \
  OPENROUTER_API_KEY=sk-test \
  FIGMA_REST_API_SKILL_ROOT="$TMP_ROOT/no-figma-skill" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: scenario 4 — health should be blocked when figma is missing for ui_parity" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/cap-parity-blocked.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
eh = state["environment_health"]
assert eh["status"] == "blocked", eh
assert eh["checks"]["figma_rest_api"]["status"] == "blocked", eh["checks"]["figma_rest_api"]
assert eh["checks"]["app_launch"]["status"] == "available", eh["checks"]["app_launch"]
assert eh["checks"]["debugbridge"]["status"] == "available", eh["checks"]["debugbridge"]
assert eh["checks"]["review_mcp"]["status"] == "available", eh["checks"]["review_mcp"]
PY
echo "PASS: scenario 4 — review+ui_parity blocked, runtime capabilities still required"

# ── 场景 5：非必需项状态契约 —— 伪造 available 给非 required 项，record_environment 必须拒绝 ──
run_for cap-contract start --type feature --task "contract" >/dev/null
run_for cap-contract confirm-plan >/dev/null
SESSION_DIR="$TMP_ROOT/.dev-flow/sessions"
# 手工构造 schema_version=2 报告：review available，但 app_launch（非 required）也标 available
/usr/bin/python3 - "$SESSION_DIR/bad-report.json" "cap-contract" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "environment-health-check",
    "schema_version": 2,
    "session_id": sys.argv[2],
    "status": "available",
    "required_gates": ["review"],
    "required_capabilities": ["review_mcp"],
    "checked_at": "2026-09-08T00:00:00Z",
    "checks": {
        "app_launch": {"status": "available", "evidence": "fake_available"},
        "debugbridge": {"status": "available", "evidence": "fake_available"},
        "review_mcp": {"status": "available", "evidence": "reviewer_health_ok"},
        "figma_rest_api": {"status": "available", "evidence": "fake_available"},
    },
}) + "\n")
PY
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-contract \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" environment-health --report "$SESSION_DIR/bad-report.json" >/dev/null 2>&1; then
  echo "FAIL: scenario 5 — record_environment accepted fake available for non-required capability" >&2
  exit 1
fi
# 合法报告：非 required 项为 not-required，review available
/usr/bin/python3 - "$SESSION_DIR/good-report.json" "cap-contract" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "environment-health-check",
    "schema_version": 2,
    "session_id": sys.argv[2],
    "status": "available",
    "required_gates": ["review"],
    "required_capabilities": ["review_mcp"],
    "checked_at": "2026-09-08T00:00:01Z",
    "checks": {
        "app_launch": {"status": "not-required", "evidence": "not_required_for_session"},
        "debugbridge": {"status": "not-required", "evidence": "not_required_for_session"},
        "review_mcp": {"status": "available", "evidence": "reviewer_health_ok"},
        "figma_rest_api": {"status": "not-required", "evidence": "not_required_for_session"},
    },
}) + "\n")
PY
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-contract \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" environment-health --report "$SESSION_DIR/good-report.json" >/dev/null; then
  echo "FAIL: scenario 5 — record_environment rejected a valid not-required report" >&2
  exit 1
fi
echo "PASS: scenario 5 — non-required must be not-required; fake available rejected"

# ── 场景 6：start 清旧 launch report ──
run_for cap-restart start --type bug --task "restart clears" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/restart-launch.json" "cap-restart" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 2, "session_id": sys.argv[2],
    "status": "available", "build_run_action": "build_run_device", "build_run_result": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": "build-restart-1", "device_id": "device-restart-1",
}) + "\n")
PY
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=cap-restart \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT/restart-launch.json" >/dev/null
if [[ ! -f "$TMP_ROOT/.dev-flow/sessions/cap-restart.app-launch.json" ]]; then
  echo "FAIL: scenario 6 — launch report was not recorded" >&2
  exit 1
fi
# start again → must clear the old report
run_for cap-restart start --type bug --task "restart clears" >/dev/null
if [[ -f "$TMP_ROOT/.dev-flow/sessions/cap-restart.app-launch.json" ]]; then
  echo "FAIL: scenario 6 — start did not clear stale app launch report" >&2
  exit 1
fi
echo "PASS: scenario 6 — start clears stale app launch report"

echo "PASS: environment capability model (scenarios 1-6) all validated"
