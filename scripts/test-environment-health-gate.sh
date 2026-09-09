#!/usr/bin/env bash
# environment-health-check v2 测试：capability 模型 + schema v2 + app-launch v2 + 深度防御
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
printf '.dev-flow/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734",
                   "source":"project"}))
PY
EOF

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"
cat > "$TMP_ROOT/bin/fail-probe" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
# v2 app-launch probe（wired 真机）
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
/bin/chmod +x "$TMP_ROOT/bin/ok-probe" "$TMP_ROOT/bin/fail-probe" "$TMP_ROOT/bin/app-launch-probe"

# v2 app-launch probe（simulator）
cat > "$TMP_ROOT/bin/app-launch-sim-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                  "status":"available","build_run_action":"build_run_sim",
                  "build_run_result":"success",
                  "device_transport":"simulator","app_launched":True,
                  "build_id":"build-sim-1","device_id":"sim-udid-1"}))
PY
EOF
# v1 app-launch probe（应被拒绝）
cat > "$TMP_ROOT/bin/app-launch-v1-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True,
                  "build_id":"build-v1-1","device_id":"device-v1-1"}))
PY
EOF
# v2 app-launch probe（bad transport：action=device 但 transport=simulator，交叉不匹配）
cat > "$TMP_ROOT/bin/app-launch-bad-transport-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":2,"session_id":sys.argv[1],
                  "status":"available","build_run_action":"build_run_device",
                  "build_run_result":"success",
                  "device_transport":"simulator","app_launched":True,
                  "build_id":"build-bad-1","device_id":"device-bad-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/app-launch-sim-probe" "$TMP_ROOT/bin/app-launch-v1-probe" "$TMP_ROOT/bin/app-launch-bad-transport-probe"

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

# ── 用例 1：healthy session（review only）──
run_for healthy start --type feature --task "healthy task" >/dev/null
run_for healthy confirm-plan >/dev/null
# confirm 后、未跑 env 时 record-gate 应失败
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-healthy.json" healthy <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734",
    "run_id": "test-run-healthy", "diff_evidence": "sha256:910236c1ded0c9d77311e6f266b0c3a771f48fa767fc27f25ffee99220d90696",
}) + "\n")
PY
if run_for healthy record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-healthy.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed without environment health after confirm" >&2
  exit 1
fi
if run_for healthy approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed without environment health after confirm" >&2
  exit 1
fi
# 跑 env 后 available，record-gate/approve-commit 通过
run_health_for healthy >/dev/null
# 注入 review_ticket
ticket_info="$(inject_review_ticket "healthy" "agent/openai-reviewer" "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/healthy.json" "$TMP_ROOT")"
tt_healthy="${ticket_info% *}"
td_healthy="${ticket_info#* }"
ra_healthy="$(inject_result_artifact "healthy" "$TMP_ROOT/.dev-flow/sessions/healthy.json" "$TMP_ROOT" "pass" "test-run-healthy" "test review pass")"
ra_healthy_path="${ra_healthy% *}"
ra_healthy_digest="${ra_healthy#* }"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-healthy.json" healthy "$tt_healthy" "$td_healthy" "$ra_healthy_path" "$ra_healthy_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
run_id = "test-run-healthy"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734",
    "run_id": run_id, "diff_evidence": "sha256:910236c1ded0c9d77311e6f266b0c3a771f48fa767fc27f25ffee99220d90696",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": sys.argv[3], "ticket_digest": sys.argv[4],
    "result_artifact": sys.argv[5], "result_artifact_digest": sys.argv[6],
}) + "\n")
PY
run_for healthy record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-healthy.json" >/dev/null
run_for healthy approve-commit >/dev/null

# ── 用例 2：blocked session（review + runtime，debugbridge blocked）──
run_for blocked start --type bug --level heavy --task "blocked task" >/dev/null
run_for blocked configure-gates --required review,runtime >/dev/null
run_for blocked confirm-plan >/dev/null
# debugbridge blocked → env blocked
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

# ── 用例 3：invalid-launch（review + runtime，app_launch probe 只 exit 0 无 JSON）──
run_for invalid-launch start --type feature --level heavy --task "invalid launch evidence" >/dev/null
run_for invalid-launch configure-gates --required review,runtime >/dev/null
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

# ── 断言：state 结构 ──
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
healthy = json.loads((root / "healthy.json").read_text())
blocked = json.loads((root / "blocked.json").read_text())
# healthy: review only → review_mcp available，其余 not-required
assert healthy["environment_health"]["status"] == "available"
assert healthy["environment_health"]["checks"]["review_mcp"]["status"] == "available"
assert healthy["environment_health"]["checks"]["app_launch"]["status"] == "not-required"
assert healthy["environment_health"]["checks"]["debugbridge"]["status"] == "not-required"
assert healthy["environment_health"]["checks"]["figma_rest_api"]["status"] == "not-required"
assert healthy["confirmed_at"] is not None
assert healthy["commit_approved_at"] is not None
# blocked: review + runtime → debugbridge blocked → env blocked
assert blocked["environment_health"]["status"] == "blocked"
assert blocked["environment_health"]["checks"]["debugbridge"]["status"] == "blocked"
assert blocked["confirmed_at"] is not None
print("OK: state structure assertions")
PY

# ── 用例 4：prod-mode（HEALTH_CMD 覆盖在非 TEST_MODE 下被忽略）──
run_for prod-mode start --type feature --level heavy --task "prod mode health cmd ignored" >/dev/null
run_for prod-mode configure-gates --required review,runtime >/dev/null
run_for prod-mode confirm-plan >/dev/null
# 写入合法 v2 app-launch 报告（生产模式 app_launch 走 read-app-launch-report.sh 读这个文件）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/prod-mode.app-launch.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 2, "session_id": "prod-mode",
    "status": "available", "build_run_action": "build_run_device",
    "build_run_result": "success",
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
print("OK: prod-mode ignores HEALTH_CMD overrides")
PY

# ── 用例 5：stale env（checked_at < confirmed_at → 深度防御拒绝）──
run_for stale start --type feature --level trivial --task "stale env" >/dev/null
run_for stale confirm-plan >/dev/null
# 手动构造 state：env available 但 checked_at 远早于 confirmed_at
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/stale.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
state = json.loads(p.read_text())
state["environment_health"] = {
    "status": "available",
    "checked_at": "2020-01-01T00:00:00Z",
    "checks": {
        "app_launch": {"status": "not-required", "evidence": "not_required_for_session"},
        "debugbridge": {"status": "not-required", "evidence": "not_required_for_session"},
        "review_mcp": {"status": "available", "evidence": "probe_exit_0"},
        "figma_rest_api": {"status": "not-required", "evidence": "not_required_for_session"},
    },
    "required_gates": ["review"],
    "required_capabilities": ["review_mcp"],
}
p.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
PY
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-stale.json" "stale" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734",
    "run_id": "test-run-stale", "diff_evidence": "sha256:1d24834b3b7136fa4cd3e5001096443baaba51cfaf02d9b9dbfc545ebd329d17",
}) + "\n")
PY
# record-gate/approve-commit 失败（checked_at < confirmed_at，深度防御）
if run_for stale record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-stale.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed with env checked before confirm-plan" >&2
  exit 1
fi
if run_for stale approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed with env checked before confirm-plan" >&2
  exit 1
fi
# confirm 后重新跑 env（checked_at >= confirmed_at）后通过
run_health_for stale >/dev/null
# 注入 review_ticket
stale_ticket="$(inject_review_ticket "stale" "agent/openai-reviewer" "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/stale.json" "$TMP_ROOT")"
stale_tt="${stale_ticket% *}"
stale_td="${stale_ticket#* }"
stale_ra="$(inject_result_artifact "stale" "$TMP_ROOT/.dev-flow/sessions/stale.json" "$TMP_ROOT" "pass" "test-run-stale" "test review pass")"
stale_ra_path="${stale_ra% *}"
stale_ra_digest="${stale_ra#* }"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-stale.json" "stale" "$stale_tt" "$stale_td" "$stale_ra_path" "$stale_ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
run_id = "test-run-stale"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:06353f7f49a0dca2012dc01497710d64788bc21b9a0973b03d7d401eb462f734",
    "run_id": run_id, "diff_evidence": "sha256:1d24834b3b7136fa4cd3e5001096443baaba51cfaf02d9b9dbfc545ebd329d17",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": sys.argv[3], "ticket_digest": sys.argv[4],
    "result_artifact": sys.argv[5], "result_artifact_digest": sys.argv[6],
}) + "\n")
PY
run_for stale record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-stale.json" >/dev/null
run_for stale approve-commit >/dev/null
echo "OK: stale env depth defense"

# ── 用例 6：simulator report 通过 review+runtime env-health ──
run_for sim-std start --type feature --level heavy --task "simulator standard" >/dev/null
run_for sim-std configure-gates --required review,runtime >/dev/null
run_for sim-std confirm-plan >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=sim-std \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-sim-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null; then
  echo "FAIL: review+runtime environment rejected a valid simulator app launch report" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/sim-std.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
checks = state["environment_health"]["checks"]
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert checks["app_launch"]["status"] == "available", checks
assert "simulator" in checks["app_launch"]["evidence"], checks["app_launch"]["evidence"]
print("OK: simulator report accepted for review+runtime")
PY

# ── 用例 7：simulator report 通过 review+runtime+figma_ui env-health（全 4 项探针）──
/bin/mkdir -p "$TMP_ROOT/figma-skill/scripts"
printf 'name: figma-rest-api\n' > "$TMP_ROOT/figma-skill/SKILL.md"
printf '#!/usr/bin/env python3\n' > "$TMP_ROOT/figma-skill/scripts/figma_rest.py"
run_for sim-hvy start --type feature --level heavy --task "simulator heavy" >/dev/null
run_for sim-hvy configure-gates --required review,runtime,figma_ui >/dev/null
run_for sim-hvy confirm-plan >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=sim-hvy \
  DEV_FLOW_TEST_MODE=1 \
  FIGMA_REST_API_SKILL_ROOT="$TMP_ROOT/figma-skill" \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-sim-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null; then
  echo "FAIL: review+runtime+figma_ui environment rejected a valid simulator app launch report" >&2
  exit 1
fi
echo "OK: simulator report accepted for full-capability env"

# ── 用例 8：v1 app-launch report 被拒绝（schema_version=1）──
run_for v1-reject start --type feature --level heavy --task "v1 reject" >/dev/null
run_for v1-reject configure-gates --required review,runtime >/dev/null
run_for v1-reject confirm-plan >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=v1-reject \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-v1-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: v1 app-launch report was accepted (should require schema_version=2)" >&2
  exit 1
fi
echo "OK: v1 app-launch report rejected"

# ── 用例 9：bad transport（action=device 但 transport=simulator）被拒绝 ──
run_for bad-trans start --type feature --level heavy --task "bad transport" >/dev/null
run_for bad-trans configure-gates --required review,runtime >/dev/null
run_for bad-trans confirm-plan >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=bad-trans \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-bad-transport-probe" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null 2>&1; then
  echo "FAIL: environment health accepted an invalid device_transport (cross-match violation)" >&2
  exit 1
fi
echo "OK: bad transport cross-match rejected"

echo ""
echo "PASS: environment health v2 (capability model + schema v2 + app-launch v2 + depth defense)"
