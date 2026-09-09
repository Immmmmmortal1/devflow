#!/usr/bin/env bash
# Selection binding (no-result-washing) 测试：
# 1. review_selection 在 record_environment 时写入 state（默认 review-health-probe.sh 路径）
# 2. record-gate 校验报告的 selected_adapter/config_digest 与 state 匹配
# 3. dispatch 后锁定 review_selection，不允许切换 adapter
# 4. 缺 selected_adapter/config_digest 的报告被拒绝（当 state 有 review_selection 时）
# 5. 无 review_selection 时报告不需要 selection 字段
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

# 带 selection binding 字段的 probe（用于需要 review_selection 的用例）
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:db02fd736c4800b285be0394b7f2d1adeb509f0027b41de95b8499661b41f681",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

# 不带 selection binding 字段的 probe（用于验证无 review_selection 时的拒绝）
cat > "$TMP_ROOT/bin/plain-probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
/bin/chmod +x "$TMP_ROOT/bin/plain-probe"

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

# 手动写入 review_selection + review_ticket 到 state（模拟 record_environment + issue-review-ticket）
inject_review_selection() {
  local session_id="$1"
  local adapter="$2"
  local digest="$3"
  local state_file="$TMP_ROOT/.dev-flow/sessions/$session_id.json"
  /usr/bin/python3 - "$state_file" "$adapter" "$digest" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
state = json.loads(p.read_text())
state["review_selection"] = {
    "selected_adapter": sys.argv[2],
    "selection_reason": "test_injection",
    "config_digest": sys.argv[3],
    "source": "project",
    "skill_path": "",
    "resolved_at": state.get("environment_health", {}).get("checked_at", "2026-01-01T00:00:00Z"),
    "locked": False,
}
p.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
PY
  # 注入 review_ticket
  local ticket_info
  ticket_info="$(inject_review_ticket "$session_id" "$adapter" "$digest" "code-quality-review" "$state_file" "$TMP_ROOT")"
  TICKET_TOKEN="${ticket_info% *}"
  TICKET_DIGEST="${ticket_info#* }"
  export TICKET_TOKEN TICKET_DIGEST
  # 注入 result artifact
  local ra_info
  ra_info="$(inject_result_artifact "$session_id" "$state_file" "$TMP_ROOT" "pass" "test-run-001" "test review pass")"
  export RESULT_ARTIFACT_PATH="${ra_info% *}"
  export RESULT_ARTIFACT_DIGEST="${ra_info#* }"
}

# ── 用例 1：record-gate 接受匹配的 selected_adapter/config_digest ──
run_for binding start --type feature --task "selection binding" >/dev/null
run_for binding confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=binding \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
# 手动注入 review_selection（模拟 review-health-probe.sh 产出的 selection binding）
inject_review_selection binding "agent/openai-reviewer" "sha256:e861b2eab679927cfa36fe256e9deb1969b0468ad0744d61064f9d188333aec6"

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-binding-pass.json" "binding" <<'PY'
import json, sys, os, hashlib
from pathlib import Path
run_id = "test-run-001"
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:e861b2eab679927cfa36fe256e9deb1969b0468ad0744d61064f9d188333aec6",
    "run_id": run_id, "diff_evidence": "sha256:419cf12452c8f99404f16311729f050fb2b2ef55851d63383e0dee6fee29e675",
    "adapter_result_ref": f"test-host-ref-{run_id}",
    "adapter_result_digest": "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest(),
    "ticket_token": os.environ.get("TICKET_TOKEN", ""),
    "ticket_digest": os.environ.get("TICKET_DIGEST", ""),
    "result_artifact": os.environ.get("RESULT_ARTIFACT_PATH", ""),
    "result_artifact_digest": os.environ.get("RESULT_ARTIFACT_DIGEST", ""),
}) + "\n")
PY
run_for binding record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-binding-pass.json" >/dev/null
echo "OK: record-gate accepted matching selected_adapter + config_digest"

# ── 用例 2：dispatch 后 review_selection 被锁定 ──
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/binding.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
selection = state.get("review_selection", {})
assert selection.get("locked") == True, selection
print("OK: review_selection locked after first review report")
PY

# ── 用例 3：锁定后用不同 adapter 的报告被拒绝（no-result-washing）──
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-washing.json" "binding" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "attempt to wash with different adapter",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:e861b2eab679927cfa36fe256e9deb1969b0468ad0744d61064f9d188333aec6",
}) + "\n")
PY
if run_for binding record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-washing.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted a different adapter after locking (no-result-washing)" >&2
  exit 1
fi
echo "OK: no-result-washing rejected (adapter switch after lock)"

# ── 用例 4：锁定后用不同 config_digest 的报告被拒绝 ──
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-digest-mismatch.json" "binding" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "attempt to wash with different digest",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:4bd45299bdc9b1e4f196ebaf93dd4931c58ecc3831e5133b896528b024a27fbb",
}) + "\n")
PY
if run_for binding record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-digest-mismatch.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted a different config_digest after locking" >&2
  exit 1
fi
echo "OK: config_digest mismatch rejected"

# ── 用例 5：缺 selected_adapter/config_digest 的报告被拒绝（当 state 有 review_selection 时）──
run_for no-fields start --type feature --task "no fields" >/dev/null
run_for no-fields confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=no-fields \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
inject_review_selection no-fields "agent/openai-reviewer" "sha256:5a4640c17e8e49ebcc72234cce9644dcacfbc2c53e026f59281ca33928bed52d"

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-no-fields.json" "no-fields" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "missing selection fields",
}) + "\n")
PY
if run_for no-fields record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-no-fields.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted report without selected_adapter/config_digest" >&2
  exit 1
fi
echo "OK: report without selected_adapter/config_digest rejected when review_selection exists"

# ── 用例 6：无 review_selection 时 review gate 必须拒绝（不能手写 pass）──
# review_selection 是 environment-health-check 产生的，旧会话或探针不产生 binding 时
# record-gate 必须拒绝，要求重跑 environment-health-check。
run_for no-binding start --type feature --task "no binding" >/dev/null
run_for no-binding confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=no-binding \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/plain-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/no-binding.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
# ok-probe 不产生 selection binding 字段 → review_selection 应为空
assert not state.get("review_selection"), state.get("review_selection")
print("OK: no review_selection when probe doesn't produce selection fields")
PY

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-no-binding.json" "no-binding" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "no binding needed",
    "run_id": "fake-run", "diff_evidence": "fake-diff",
}) + "\n")
PY
if run_for no-binding record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-no-binding.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted review report without review_selection in state" >&2
  exit 1
fi
echo "OK: report without review_selection in state rejected (must run environment-health-check first)"

# ── 用例 7：post-dispatch fallback 禁止 —— primary blocked 后用 review_path=fallback 被拒 ──
# 场景：primary adapter (agent/openai-reviewer) 被选中并锁定后，
#       dispatch 返回 blocked，然后试图用 review_path=fallback 的报告"洗"过门禁。
#       即使 selected_adapter 字段也改成 skill/gstack，也必须被拒。
run_for postfb start --type feature --task "post-dispatch fallback" >/dev/null
run_for postfb confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=postfb \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
inject_review_selection postfb "agent/openai-reviewer" "sha256:9acc474f68e3e7c6ab8b54adf2e983f08d20926544a9b38e05d738236351ff99"

# 先记录一个 blocked（模拟 dispatch 后 primary 返回 blocked）
# 需要为 blocked 状态创建 result artifact
postfb_ra="$(inject_result_artifact "postfb" "$TMP_ROOT/.dev-flow/sessions/postfb.json" "$TMP_ROOT" "blocked" "test-run-postfb" "primary adapter timeout")"
export POSTFB_RA_PATH="${postfb_ra% *}"
export POSTFB_RA_DIGEST="${postfb_ra#* }"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-postfb-blocked.json" "postfb" <<'PY'
import json, sys, os, hashlib
from pathlib import Path
run_id = "test-run-postfb"
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "blocked", "reviewer_result": "blocked",
    "evidence": "primary adapter timeout",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:9acc474f68e3e7c6ab8b54adf2e983f08d20926544a9b38e05d738236351ff99",
    "run_id": run_id, "diff_evidence": "sha256:e392e4a30f74b61799ff20969de0dbc61c00ddcd9d6b90710fa078a75cf20be7",
    "adapter_result_ref": f"test-host-ref-{run_id}",
    "adapter_result_digest": "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest(),
    "ticket_token": os.environ.get("TICKET_TOKEN", ""),
    "ticket_digest": os.environ.get("TICKET_DIGEST", ""),
    "result_artifact": os.environ.get("POSTFB_RA_PATH", ""),
    "result_artifact_digest": os.environ.get("POSTFB_RA_DIGEST", ""),
}) + "\n")
PY
run_for postfb record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-postfb-blocked.json" >/dev/null
echo "OK: primary blocked recorded (review_selection now locked)"

# 验证 review_selection 已锁定
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/postfb.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
selection = state.get("review_selection", {})
assert selection.get("locked") == True, selection
assert selection.get("selected_adapter") == "agent/openai-reviewer", selection
print("OK: review_selection locked to agent/openai-reviewer after blocked")
PY

# 试图用 review_path=fallback + selected_adapter=skill/gstack 的报告"洗"过门禁
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-postfb-wash.json" "postfb" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "attempt post-dispatch fallback wash",
    "review_path": "fallback",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:9acc474f68e3e7c6ab8b54adf2e983f08d20926544a9b38e05d738236351ff99",
}) + "\n")
PY
if run_for postfb record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-postfb-wash.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted post-dispatch fallback switch (review_path=fallback on locked non-gstack session)" >&2
  exit 1
fi
echo "OK: post-dispatch fallback switch rejected (review_path=fallback on locked agent/openai-reviewer session)"

# ── 用例 8：post-dispatch fallback 禁止 —— 即使 review_path 不设 fallback，adapter mismatch 也被拒 ──
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-postfb-mismatch.json" "postfb" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "attempt adapter switch without review_path",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:9acc474f68e3e7c6ab8b54adf2e983f08d20926544a9b38e05d738236351ff99",
}) + "\n")
PY
if run_for postfb record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-postfb-mismatch.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate accepted adapter switch after blocked (no review_path)" >&2
  exit 1
fi
echo "OK: adapter mismatch rejected after blocked (independent of review_path)"

# ── 用例 9：locked 后 re-run env-health 不能解锁或改变 selection ──
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=postfb \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/postfb.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
selection = state.get("review_selection", {})
assert selection.get("locked") == True, selection
assert selection.get("selected_adapter") == "agent/openai-reviewer", selection
print("OK: review_selection stays locked after env-health re-run")
PY

# ── 用例 10：review_path=reviewer 被接受（valid review_path 值）──
run_for revpath start --type feature --task "reviewer path" >/dev/null
run_for revpath confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=revpath \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
inject_review_selection revpath "agent/openai-reviewer" "sha256:2b79be020e346b132a168e8c6b546c9a93c5f2e0cc70608021bb6edcdbc28ebd"

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/review-revpath.json" "revpath" <<'PY'
import json, sys, os, hashlib
from pathlib import Path
run_id = "test-run-001"
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "reviewer path pass",
    "review_path": "reviewer",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:2b79be020e346b132a168e8c6b546c9a93c5f2e0cc70608021bb6edcdbc28ebd",
    "run_id": run_id, "diff_evidence": "sha256:bcb76ead9b3d2b41010b3d76160a57e3302dd293768e961a4f45890f2cf71060",
    "adapter_result_ref": f"test-host-ref-{run_id}",
    "adapter_result_digest": "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest(),
    "ticket_token": os.environ.get("TICKET_TOKEN", ""),
    "ticket_digest": os.environ.get("TICKET_DIGEST", ""),
    "result_artifact": os.environ.get("RESULT_ARTIFACT_PATH", ""),
    "result_artifact_digest": os.environ.get("RESULT_ARTIFACT_DIGEST", ""),
}) + "\n")
PY
run_for revpath record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-revpath.json" >/dev/null
echo "OK: review_path=reviewer accepted"

echo ""
echo "PASS: selection binding (no-result-washing + post-dispatch fallback prohibition) enforcement"
