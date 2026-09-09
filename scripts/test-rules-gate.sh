#!/usr/bin/env bash
# 双层规则机制测试：全局 rules/global-rules.md + 项目 .dev-flow/rules.md
# 覆盖：start 硬读/打印/记录、read-rules 刷新、hash 变更门禁拒绝与恢复、
# approve-commit 全局闭环、旧会话拒绝、空模板、>4KB 截断、多 session 隔离、全局缺失拒绝。
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
print(json.dumps({"status":"available","evidence":"test_review_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:2c3a42ec7f48b8e721a47205e0cdd549d1238d657882590f2d42b10dd570fc36",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"

PROJECT_RULES="$TMP_ROOT/.dev-flow/rules.md"
FAKE_GLOBAL="$TMP_ROOT/fake-global-rules.md"
printf '# fake global rules\n' > "$FAKE_GLOBAL"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

# 带全局规则覆盖的调用（测试模式才生效）
run_for_g() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 DEV_FLOW_GLOBAL_RULES_FILE="$FAKE_GLOBAL" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_health_review_only() {
  local session_id="$1"
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
}

write_review_pass() {
  local session_id="$1"
  # 注入 review_ticket
  local ticket_info
  ticket_info="$(inject_review_ticket "$session_id" "agent/openai-reviewer" "sha256:2c3a42ec7f48b8e721a47205e0cdd549d1238d657882590f2d42b10dd570fc36" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/$session_id.json" "$TMP_ROOT")"
  local tt="${ticket_info% *}"
  local td="${ticket_info#* }"
  # 注入 result artifact
  local ra_info
  ra_info="$(inject_result_artifact "$session_id" "$TMP_ROOT/.dev-flow/sessions/$session_id.json" "$TMP_ROOT" "pass" "test-run-rules" "test review pass")"
  local ra_path="${ra_info% *}"
  local ra_digest="${ra_info#* }"
  /usr/bin/python3 - "$TMP_ROOT" "$session_id" "$tt" "$td" "$ra_path" "$ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
root = Path(sys.argv[1])
session_id = sys.argv[2]
tt, td, ra_path, ra_digest = sys.argv[3:7]
run_id = "test-run-rules"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
(root / ".dev-flow" / "sessions" / f"review-{session_id}.json").write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:2c3a42ec7f48b8e721a47205e0cdd549d1238d657882590f2d42b10dd570fc36",
    "run_id": run_id, "diff_evidence": "sha256:77f3bc83fc16f09cff43485a9233873df08c0cfe9fc98ff3db44fe8958157f23",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
}

# trivial 全链路：start → env → confirm → review pass（之后可 approve-commit）
setup_trivial_chain() {
  local session_id="$1"
  run_for "$session_id" start --type feature --level trivial --task "$session_id" >/dev/null
  run_for "$session_id" confirm-plan >/dev/null
  run_health_review_only "$session_id"
  write_review_pass "$session_id"
  run_for "$session_id" record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-$session_id.json" >/dev/null
}

sha_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d' ' -f1
}

# ---- 用例 1：start 打印两份规则到 stdout，state 记录 hash ----
out="$(run_for basic start --type feature --level trivial --task "basic")"
printf '%s' "$out" | /usr/bin/grep -q "===== GLOBAL RULES" || { echo "FAIL: start did not print global rules" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "===== PROJECT RULES" || { echo "FAIL: start did not print project rules" >&2; exit 1; }
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/basic.json" "$PROJECT_RULES" "$ROOT/rules/global-rules.md" <<'PY'
import hashlib, json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
rules = state.get("rules") or {}
for scope, path in (("project", sys.argv[2]), ("global", sys.argv[3])):
    entry = rules.get(scope) or {}
    assert entry.get("path") == path, (scope, entry)
    assert entry.get("sha256") == hashlib.sha256(Path(path).read_bytes()).hexdigest(), scope
    assert entry.get("read_at"), scope
PY

# ---- 用例 2：项目规则不存在时 start 自动创建模板 ----
[[ -f "$PROJECT_RULES" ]] || { echo "FAIL: project rules template not created" >&2; exit 1; }
/usr/bin/grep -q "# 项目规则" "$PROJECT_RULES" || { echo "FAIL: project rules template content wrong" >&2; exit 1; }

# ---- 用例 3：门禁 action 成功后回带项目规则到 stdout ----
out="$(run_for basic configure-gates --required review)"
printf '%s' "$out" | /usr/bin/grep -q "===== PROJECT RULES" || { echo "FAIL: configure-gates did not echo project rules" >&2; exit 1; }

# ---- 用例 4：项目规则变更后门禁失败；read-rules 后恢复 ----
printf '\n# new project rule\n' >> "$PROJECT_RULES"
if run_for basic configure-gates --required review >/dev/null 2>&1; then
  echo "FAIL: gate action passed after project rules changed" >&2
  exit 1
fi
out="$(run_for basic read-rules)"
printf '%s' "$out" | /usr/bin/grep -q "new project rule" || { echo "FAIL: read-rules did not print updated rules" >&2; exit 1; }
run_for basic configure-gates --required review >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/basic.json" "$PROJECT_RULES" <<'PY'
import hashlib, json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["rules"]["project"]["sha256"] == hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
PY

# ---- 用例 5：approve-commit 全局规则闭环：篡改拒批，read-rules 放行 ----
setup_trivial_chain gclose
# 全链路用覆盖的全局文件（setup 里用的是真实全局文件；此用例单独建链）
run_for_g gchain start --type feature --level trivial --task "gchain" >/dev/null
run_for_g gchain confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=gchain \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_GLOBAL_RULES_FILE="$FAKE_GLOBAL" \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
write_review_pass gchain
run_for_g gchain record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-gchain.json" >/dev/null
printf '# tampered global rule\n' >> "$FAKE_GLOBAL"
if run_for_g gchain approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit passed after global rules changed" >&2
  exit 1
fi
run_for_g gchain read-rules >/dev/null
run_for_g gchain approve-commit >/dev/null

# 真实全局文件链路 approve-commit 正常（对照）
run_for gclose approve-commit >/dev/null

# ---- 用例 6：旧会话（无 rules 字段）门禁拒绝，read-rules 后恢复 ----
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/legacy.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "session_id": "legacy", "active": True, "type": "feature", "task": "legacy",
    "level": "trivial", "started_at": "2026-08-26T00:00:00Z",
    "confirmed_at": None, "commit_approved_at": None, "ended_at": None,
    "required_gates": ["review"],
    "gate_results": {"review": {"status": "pending", "evidence": None, "recorded_at": None}},
    "environment_health": {"status": "not-run", "checked_at": None, "checks": {}},
}) + "\n")
PY
if run_for legacy configure-gates --required review 2>"$TMP_ROOT/.dev-flow/sessions/legacy.err" >/dev/null; then
  echo "FAIL: legacy session passed gate action without rules record" >&2
  exit 1
fi
/usr/bin/grep -q "read-rules" "$TMP_ROOT/.dev-flow/sessions/legacy.err" || { echo "FAIL: legacy rejection did not mention read-rules" >&2; exit 1; }
run_for legacy read-rules >/dev/null
run_for legacy configure-gates --required review >/dev/null

# ---- 用例 7：空模板项目规则正常工作（用例 1-4 已覆盖模板创建与门禁，这里验证全链路）----
setup_trivial_chain empty-ok
run_for empty-ok approve-commit >/dev/null

# ---- 用例 8：>4KB 项目规则截断 + 警告 ----
/usr/bin/python3 - "$PROJECT_RULES" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("# big rules\n" + "x" * 5000 + "\n")
PY
out="$(run_for big start --type feature --level trivial --task "big" 2>&1)"
printf '%s' "$out" | /usr/bin/grep -q "WARNING: rules file truncated" || { echo "FAIL: no truncation warning for >4KB rules" >&2; exit 1; }

# ---- 用例 9：多 session 隔离 ----
printf '# shared project rules\n' > "$PROJECT_RULES"
run_for sess-a start --type feature --level trivial --task "a" >/dev/null
run_for sess-b start --type feature --level trivial --task "b" >/dev/null
printf '\n# changed\n' >> "$PROJECT_RULES"
run_for sess-a read-rules >/dev/null
run_for sess-a configure-gates --required review >/dev/null
if run_for sess-b configure-gates --required review >/dev/null 2>&1; then
  echo "FAIL: session b passed with stale rules hash" >&2
  exit 1
fi
run_for sess-b read-rules >/dev/null
run_for sess-b configure-gates --required review >/dev/null

# ---- 用例 10：全局规则缺失 → start 失败 ----
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=noglobal \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_GLOBAL_RULES_FILE="$TMP_ROOT/nonexistent-global.md" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --level trivial --task "noglobal" >/dev/null 2>&1; then
  echo "FAIL: start passed with missing global rules" >&2
  exit 1
fi

# ---- 用例 11：read-rules 无 active session 报错 ----
if run_for no-session read-rules >/dev/null 2>&1; then
  echo "FAIL: read-rules passed without active session" >&2
  exit 1
fi

# ---- 用例 12：.dev-flow 目录为 symlink → start 拒绝 ----
TMP_C="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_ROOT/.dev-flow" "$TMP_C/.dev-flow"
if DEV_FLOW_PROJECT_ROOT="$TMP_C" DEV_FLOW_SESSION_ID=sym-c \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --level trivial --task "sym" >/dev/null 2>&1; then
  echo "FAIL: start passed with symlinked .dev-flow directory" >&2
  exit 1
fi
/bin/rm -rf -- "$TMP_C"

# ---- 用例 13：rules.md 被替换为 symlink → 门禁拒绝 ----
printf '# stable rules\n' > "$PROJECT_RULES"
run_for sym-f start --type feature --level trivial --task "sym-f" >/dev/null
/bin/mv "$PROJECT_RULES" "$TMP_ROOT/rules-real.md"
/bin/ln -s "$TMP_ROOT/rules-real.md" "$PROJECT_RULES"
if run_for sym-f configure-gates --required review >/dev/null 2>&1; then
  echo "FAIL: gate action passed with symlinked rules.md" >&2
  exit 1
fi
/bin/rm -f "$PROJECT_RULES"
/bin/mv "$TMP_ROOT/rules-real.md" "$PROJECT_RULES"

# ---- 用例 14：项目规则变更后 environment-health 拒绝；read-rules 后恢复 ----
run_for env-fresh start --type feature --level trivial --task "env-fresh" >/dev/null
run_for env-fresh confirm-plan >/dev/null
printf '\n# changed before health\n' >> "$PROJECT_RULES"
if run_health_review_only env-fresh; then
  echo "FAIL: environment-health passed after project rules changed" >&2
  exit 1
fi
run_for env-fresh read-rules >/dev/null
run_health_review_only env-fresh

# ---- 用例 15：confirm-plan / record-gate 各自的 freshness 校验 ----
printf '\n# changed before confirm\n' >> "$PROJECT_RULES"
if run_for env-fresh confirm-plan >/dev/null 2>&1; then
  echo "FAIL: confirm-plan passed after project rules changed" >&2
  exit 1
fi
run_for env-fresh read-rules >/dev/null
run_for env-fresh confirm-plan >/dev/null
# 重新 confirm 后旧 env 过期（checked_at < 新 confirmed_at），重跑 env
run_health_review_only env-fresh >/dev/null
write_review_pass env-fresh
run_for env-fresh record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-env-fresh.json" >/dev/null
printf '\n# changed before record\n' >> "$PROJECT_RULES"
if run_for env-fresh record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-env-fresh.json" >/dev/null 2>&1; then
  echo "FAIL: record-gate passed after project rules changed" >&2
  exit 1
fi
run_for env-fresh read-rules >/dev/null
# ticket 已在第一次 record-gate pass 时消费，需重新签发
write_review_pass env-fresh
run_for env-fresh record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-env-fresh.json" >/dev/null

# ---- 用例 16：read-rules 不重置其他 state 字段 ----
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/env-fresh.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state.get("confirmed_at"), state
assert state["gate_results"]["review"]["status"] == "pass", state["gate_results"]
assert state["environment_health"]["status"] == "available", state["environment_health"]
assert state.get("level") == "trivial", state
assert state.get("task") == "env-fresh", state
PY

# ---- 用例 17：生产模式忽略 DEV_FLOW_GLOBAL_RULES_FILE 覆盖 ----
printf '# prod rules\n' > "$PROJECT_RULES"
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=prod-ovr \
  DEV_FLOW_GLOBAL_RULES_FILE="$FAKE_GLOBAL" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --level trivial --task "prod-ovr" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/prod-ovr.json" "$ROOT/rules/global-rules.md" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["rules"]["global"]["path"] == sys.argv[2], state["rules"]["global"]
PY

# ---- 用例 18：environment-health-check.sh 成功时 stdout 回带项目规则 ----
run_for env-echo start --type feature --level trivial --task "env-echo" >/dev/null
run_for env-echo confirm-plan >/dev/null
out="$(DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=env-echo \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run 2>/dev/null)"
printf '%s' "$out" | /usr/bin/grep -q "===== PROJECT RULES" || { echo "FAIL: health-check stdout missing project rules" >&2; exit 1; }

# ---- 用例 19：跨项目复用会话 → 门禁拒绝 + read-rules 拒绝重绑 ----
TMP_B="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_B/.dev-flow/sessions"
run_for xproj start --type feature --level trivial --task "xproj" >/dev/null
/bin/cp "$TMP_ROOT/.dev-flow/sessions/xproj.json" "$TMP_B/.dev-flow/sessions/xproj.json"
if DEV_FLOW_PROJECT_ROOT="$TMP_B" DEV_FLOW_SESSION_ID=xproj \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" configure-gates --required review 2>"$TMP_B/err" >/dev/null; then
  echo "FAIL: gate action passed with cross-project session state" >&2
  exit 1
fi
/usr/bin/grep -q "不一致" "$TMP_B/err" || { echo "FAIL: cross-project rejection did not report path mismatch" >&2; exit 1; }
if DEV_FLOW_PROJECT_ROOT="$TMP_B" DEV_FLOW_SESSION_ID=xproj \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" read-rules >/dev/null 2>&1; then
  echo "FAIL: read-rules allowed cross-project rebinding" >&2
  exit 1
fi
/bin/rm -rf -- "$TMP_B"

echo "PASS: rules gate enforces start/read-rules hashing, gate freshness, approve-commit closure, symlink and cross-project binding"
