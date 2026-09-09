#!/usr/bin/env bash
# Round 3 review ticket 高级特性测试：
# 1. worktree digest 变化检测（tracked 变更/untracked 新增/untracked 修改/untracked 删除）
# 2. ticket 覆盖拒绝 + cancel 流程
# 3. route whitelist 未知 route 拒绝
# 4. result artifact 缺失/伪造 digest/symlink/跨 session 拒绝
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

# 创建 git repo（worktree digest 测试需要）
/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || {
  /usr/bin/git -C "$TMP_ROOT" init -q
  /usr/bin/git -C "$TMP_ROOT" checkout -qb main
}
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'base content\n' > "$TMP_ROOT/base.txt"
/usr/bin/git -C "$TMP_ROOT" add base.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "base"
/usr/bin/git -C "$TMP_ROOT" checkout -qb feature
printf 'feature work\n' > "$TMP_ROOT/feature.txt"
/usr/bin/git -C "$TMP_ROOT" add feature.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "feature"
printf '.dev-flow/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# probe
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_env_health() {
  local session_id="$1"
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
}

# 辅助：写 gate report + result artifact
write_pass_report() {
  local session_id="$1" state_file="$2"
  local ticket_info tt td ra_info ra_path ra_digest
  ticket_info="$(inject_review_ticket "$session_id" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
  tt="${ticket_info% *}"
  td="${ticket_info#* }"
  ra_info="$(inject_result_artifact "$session_id" "$state_file" "$TMP_ROOT" "pass" "test-run-r3" "test pass")"
  ra_path="${ra_info% *}"
  ra_digest="${ra_info#* }"
  /usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-$session_id.json" "$session_id" "$tt" "$td" "$ra_path" "$ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, tt, td, ra_path, ra_digest = sys.argv[1:7]
run_id = "test-run-r3"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "test pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": run_id, "diff_evidence": "sha256:53f4048c261ad16874d0c4f586522cc6b88f7ac935466c1f463c4d4cf393ae21",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
  echo "$TMP_ROOT/.dev-flow/sessions/report-$session_id.json"
}

# ============================================================
# 1. worktree digest 变化检测
# ============================================================

# ---- 1a: tracked 文件变更 → 拒绝 ----
run_for wt1 start --type feature --task "wt tracked change" >/dev/null
run_for wt1 confirm-plan >/dev/null
run_env_health wt1
state_file="$TMP_ROOT/.dev-flow/sessions/wt1.json"
report_path="$(write_pass_report wt1 "$state_file")"
# 签发 ticket 后修改 tracked 文件
echo "modified" >> "$TMP_ROOT/feature.txt"
if run_for wt1 record-gate --name review --report "$report_path" 2>"$TMP_ROOT/.dev-flow/sessions/wt1.err"; then
  echo "FAIL: tracked file change after ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "worktree changed" "$TMP_ROOT/.dev-flow/sessions/wt1.err" || { echo "FAIL: wt1 error message wrong" >&2; exit 1; }
echo "OK: tracked file change after ticket rejected"
# 还原
/usr/bin/git -C "$TMP_ROOT" checkout -q -- feature.txt

# ---- 1b: untracked 文件新增 → 拒绝 ----
run_for wt2 start --type feature --task "wt untracked add" >/dev/null
run_for wt2 confirm-plan >/dev/null
run_env_health wt2
state_file="$TMP_ROOT/.dev-flow/sessions/wt2.json"
report_path="$(write_pass_report wt2 "$state_file")"
# 签发 ticket 后新增 untracked 文件（.dev-flow/ 外）
echo "new file" > "$TMP_ROOT/untracked-new.txt"
if run_for wt2 record-gate --name review --report "$report_path" 2>"$TMP_ROOT/.dev-flow/sessions/wt2.err"; then
  echo "FAIL: untracked file add after ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "worktree changed" "$TMP_ROOT/.dev-flow/sessions/wt2.err" || { echo "FAIL: wt2 error message wrong" >&2; exit 1; }
echo "OK: untracked file add after ticket rejected"
/bin/rm -f "$TMP_ROOT/untracked-new.txt"

# ---- 1c: .dev-flow/ 内文件新增 → 不影响 digest → 通过 ----
run_for wt3 start --type feature --task "wt devflow add" >/dev/null
run_for wt3 confirm-plan >/dev/null
run_env_health wt3
state_file="$TMP_ROOT/.dev-flow/sessions/wt3.json"
report_path="$(write_pass_report wt3 "$state_file")"
# .dev-flow/ 内新增文件不影响 digest
echo "dev-flow internal" > "$TMP_ROOT/.dev-flow/internal-note.txt"
run_for wt3 record-gate --name review --report "$report_path" >/dev/null
echo "OK: .dev-flow/ internal file does not affect digest"

# ---- 1d: untracked 文件删除 → 拒绝 ----
# 先创建一个 untracked 文件，签发 ticket 后删除
echo "pre-existing" > "$TMP_ROOT/pre-existing.txt"
run_for wt4 start --type feature --task "wt untracked delete" >/dev/null
run_for wt4 confirm-plan >/dev/null
run_env_health wt4
state_file="$TMP_ROOT/.dev-flow/sessions/wt4.json"
report_path="$(write_pass_report wt4 "$state_file")"
# 签发 ticket 后删除 untracked 文件
/bin/rm -f "$TMP_ROOT/pre-existing.txt"
if run_for wt4 record-gate --name review --report "$report_path" 2>"$TMP_ROOT/.dev-flow/sessions/wt4.err"; then
  echo "FAIL: untracked file delete after ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "worktree changed" "$TMP_ROOT/.dev-flow/sessions/wt4.err" || { echo "FAIL: wt4 error message wrong" >&2; exit 1; }
echo "OK: untracked file delete after ticket rejected"

# ---- 1e: staged 变更（git add 但不 commit）→ 拒绝 ----
run_for wt5 start --type feature --task "wt staged change" >/dev/null
run_for wt5 confirm-plan >/dev/null
run_env_health wt5
state_file="$TMP_ROOT/.dev-flow/sessions/wt5.json"
report_path="$(write_pass_report wt5 "$state_file")"
# 签发 ticket 后 stage 一个新变更（不影响 working tree，只改 index）
echo "staged content" > "$TMP_ROOT/staged-new.txt"
/usr/bin/git -C "$TMP_ROOT" add staged-new.txt
if run_for wt5 record-gate --name review --report "$report_path" 2>"$TMP_ROOT/.dev-flow/sessions/wt5.err"; then
  echo "FAIL: staged-only change after ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "worktree changed" "$TMP_ROOT/.dev-flow/sessions/wt5.err" || { echo "FAIL: wt5 staged change message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/wt5.err")" >&2; exit 1; }
echo "OK: staged-only change (index differs from working tree) after ticket rejected"
# 还原
/usr/bin/git -C "$TMP_ROOT" reset -q -- staged-new.txt
/bin/rm -f "$TMP_ROOT/staged-new.txt"

# ---- 1f: 非 git 项目 → worktree_digest.py 失败 → record-gate fail closed ----
TMP_NG="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_NG/.dev-flow/sessions"
run_ng() {
  DEV_FLOW_PROJECT_ROOT="$TMP_NG" DEV_FLOW_SESSION_ID=ngwt \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}
run_ng start --type feature --task "non-git" >/dev/null
run_ng confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_NG" DEV_FLOW_SESSION_ID=ngwt \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
# 非 git 项目签发 ticket 应失败
if inject_review_ticket "ngwt" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$TMP_NG/.dev-flow/sessions/ngwt.json" "$TMP_NG" >/dev/null 2>&1; then
  echo "FAIL: ticket injection should fail for non-git project" >&2
  exit 1
fi
echo "OK: non-git project ticket injection rejected (worktree_digest.py requires git)"
/bin/rm -rf -- "$TMP_NG"

# ============================================================
# 2. ticket 覆盖拒绝 + cancel 流程
# ============================================================

# ---- 2a: 未消费 ticket 存在时 issue-review-ticket 拒绝覆盖 ----
run_for ov1 start --type feature --task "overwrite reject" >/dev/null
run_for ov1 confirm-plan >/dev/null
run_env_health ov1
state_file="$TMP_ROOT/.dev-flow/sessions/ov1.json"
# 第一次签发
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/issue-review-ticket.sh" --route "code-quality-review" >/dev/null
# 第二次签发应该被拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/issue-review-ticket.sh" --route "code-quality-review" 2>"$TMP_ROOT/.dev-flow/sessions/ov1.err"; then
  echo "FAIL: issue-review-ticket should reject overwrite of unconsumed ticket" >&2
  exit 1
fi
/usr/bin/grep -q "already.*unconsumed\|cancel.*first\|already exists" "$TMP_ROOT/.dev-flow/sessions/ov1.err" || { echo "FAIL: ov1 overwrite message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ov1.err")" >&2; exit 1; }
echo "OK: issue-review-ticket rejects overwrite of unconsumed ticket"

# ---- 2b: cancel 后可重新签发 ----
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" --reason "test cancel" >/dev/null
# cancel 后重新签发应该成功
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/issue-review-ticket.sh" --route "code-quality-review" >/dev/null
echo "OK: cancel then re-issue works"

# ---- 2c: cancel 已消费的 ticket → 拒绝 ----
run_for ov2 start --type feature --task "cancel consumed" >/dev/null
run_for ov2 confirm-plan >/dev/null
run_env_health ov2
state_file="$TMP_ROOT/.dev-flow/sessions/ov2.json"
report_path="$(write_pass_report ov2 "$state_file")"
run_for ov2 record-gate --name review --report "$report_path" >/dev/null
# ticket 已消费，cancel 应该拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov2 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" 2>"$TMP_ROOT/.dev-flow/sessions/ov2.err"; then
  echo "FAIL: cancel of consumed ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "already consumed" "$TMP_ROOT/.dev-flow/sessions/ov2.err" || { echo "FAIL: ov2 cancel consumed message wrong" >&2; exit 1; }
echo "OK: cancel of consumed ticket rejected"

# ---- 2d: cancel 已 cancel 的 ticket → 拒绝 ----
# ov1 在 2b 重新签发了 ticket（未 cancel），先 cancel 一次，再试第二次
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" --reason "first cancel" >/dev/null
# 第二次 cancel 应该被拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov1 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" 2>"$TMP_ROOT/.dev-flow/sessions/ov1c.err"; then
  echo "FAIL: double cancel should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "already cancelled" "$TMP_ROOT/.dev-flow/sessions/ov1c.err" || { echo "FAIL: double cancel message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ov1c.err")" >&2; exit 1; }
echo "OK: double cancel rejected"

# ---- 2e: cancel 无 ticket 的 session → 拒绝 ----
run_for ov3 start --type feature --task "cancel no ticket" >/dev/null
run_for ov3 confirm-plan >/dev/null
run_env_health ov3
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=ov3 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" 2>"$TMP_ROOT/.dev-flow/sessions/ov3.err"; then
  echo "FAIL: cancel without ticket should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "no review_ticket\|nothing to cancel" "$TMP_ROOT/.dev-flow/sessions/ov3.err" || { echo "FAIL: ov3 no-ticket message wrong" >&2; exit 1; }
echo "OK: cancel without ticket rejected"

# ============================================================
# 3. route whitelist 未知 route 拒绝
# ============================================================

run_for rw1 start --type feature --task "route whitelist" >/dev/null
run_for rw1 confirm-plan >/dev/null
run_env_health rw1
# 未知 route 应该被拒绝
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=rw1 \
  /bin/bash "$ROOT/scripts/issue-review-ticket.sh" --route "unknown-route-xyz" 2>"$TMP_ROOT/.dev-flow/sessions/rw1.err"; then
  echo "FAIL: unknown route should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "invalid.*route\|unknown.*route\|route.*not.*valid\|route.*whitelist" "$TMP_ROOT/.dev-flow/sessions/rw1.err" || { echo "FAIL: rw1 route message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/rw1.err")" >&2; exit 1; }
echo "OK: unknown route rejected by whitelist"

# 已知 route 应该通过
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=rw1 \
  /bin/bash "$ROOT/scripts/issue-review-ticket.sh" --route "code-quality-review" >/dev/null
echo "OK: known route accepted"

# cancel 以清理
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=rw1 \
  /bin/bash "$ROOT/scripts/cancel-review-ticket.sh" >/dev/null

# ============================================================
# 4. result artifact 验证
# ============================================================

# ---- 4a: 缺少 result_artifact → 拒绝 ----
run_for ra1 start --type feature --task "missing artifact" >/dev/null
run_for ra1 confirm-plan >/dev/null
run_env_health ra1
state_file="$TMP_ROOT/.dev-flow/sessions/ra1.json"
ticket_info="$(inject_review_ticket "ra1" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
# 写不含 result_artifact 的报告
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-ra1.json" "ra1" "$tt" "$td" <<'PY'
import json, sys
from pathlib import Path
path, session_id, tt, td = sys.argv[1:5]
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "no artifact",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": "test-run-ra1", "diff_evidence": "sha256:92d0a9d2a1747fecd4e489a151e61a9998e950c6c14741759726bc29ba590633",
    "ticket_token": tt, "ticket_digest": td,
}) + "\n")
PY
if run_for ra1 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-ra1.json" 2>"$TMP_ROOT/.dev-flow/sessions/ra1.err"; then
  echo "FAIL: missing result_artifact should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "result_artifact" "$TMP_ROOT/.dev-flow/sessions/ra1.err" || { echo "FAIL: ra1 missing artifact message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ra1.err")" >&2; exit 1; }
echo "OK: missing result_artifact rejected"

# ---- 4b: 伪造 result_artifact_digest → 拒绝 ----
run_for ra2 start --type feature --task "fake digest" >/dev/null
run_for ra2 confirm-plan >/dev/null
run_env_health ra2
state_file="$TMP_ROOT/.dev-flow/sessions/ra2.json"
ticket_info="$(inject_review_ticket "ra2" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
ra_info="$(inject_result_artifact "ra2" "$state_file" "$TMP_ROOT" "pass" "test-run-ra2" "test pass")"
ra_path="${ra_info% *}"
# 用错误的 digest
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-ra2.json" "ra2" "$tt" "$td" "$ra_path" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, tt, td, ra_path = sys.argv[1:6]
run_id = "test-run-ra2"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "fake digest",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": run_id, "diff_evidence": "sha256:306ca01d02b9b8f059099a2e7106343434b69346f87bae1bc7afab76145c79fa",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
}) + "\n")
PY
if run_for ra2 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-ra2.json" 2>"$TMP_ROOT/.dev-flow/sessions/ra2.err"; then
  echo "FAIL: fake result_artifact_digest should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "digest.*mismatch\|digest.*does not match\|result_artifact_digest" "$TMP_ROOT/.dev-flow/sessions/ra2.err" || { echo "FAIL: ra2 fake digest message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ra2.err")" >&2; exit 1; }
echo "OK: fake result_artifact_digest rejected"

# ---- 4c: symlink result_artifact → 拒绝 ----
run_for ra3 start --type feature --task "symlink artifact" >/dev/null
run_for ra3 confirm-plan >/dev/null
run_env_health ra3
state_file="$TMP_ROOT/.dev-flow/sessions/ra3.json"
ticket_info="$(inject_review_ticket "ra3" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
# 创建一个真实文件，然后 symlink 指向它
echo "real content" > "$TMP_ROOT/.dev-flow/sessions/real-ra3.json"
symlink_path="$TMP_ROOT/.dev-flow/sessions/symlink-ra3.json"
/bin/ln -s "$TMP_ROOT/.dev-flow/sessions/real-ra3.json" "$symlink_path"
real_digest="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(open('$TMP_ROOT/.dev-flow/sessions/real-ra3.json','rb').read()).hexdigest())")"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-ra3.json" "ra3" "$tt" "$td" "$symlink_path" "$real_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, tt, td, ra_path, ra_digest = sys.argv[1:7]
run_id = "test-run-ra3"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "symlink test",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": run_id, "diff_evidence": "sha256:1449b9af1b3287697edaab990e7a19e947749e86d1f62ce77a1a83bbd4ff52c3",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
if run_for ra3 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-ra3.json" 2>"$TMP_ROOT/.dev-flow/sessions/ra3.err"; then
  echo "FAIL: symlink result_artifact should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "symlink" "$TMP_ROOT/.dev-flow/sessions/ra3.err" || { echo "FAIL: ra3 symlink message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ra3.err")" >&2; exit 1; }
echo "OK: symlink result_artifact rejected"

# ---- 4d: 跨 session 的 result_artifact → 拒绝 ----
# ra4 的报告引用 ra3 session 的 result artifact
run_for ra4 start --type feature --task "cross session" >/dev/null
run_for ra4 confirm-plan >/dev/null
run_env_health ra4
state_file="$TMP_ROOT/.dev-flow/sessions/ra4.json"
ticket_info="$(inject_review_ticket "ra4" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
# 用 ra3 session 的 result artifact 路径（不同 session）
# 需要先确保 ra3 有 ticket，才能创建 result artifact
ra3_state="$TMP_ROOT/.dev-flow/sessions/ra3.json"
ra3_ticket="$(inject_review_ticket "ra3" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$ra3_state" "$TMP_ROOT")" 2>/dev/null || true
ra3_ra_info="$(inject_result_artifact "ra3" "$ra3_state" "$TMP_ROOT" "pass" "test-run-ra3" "ra3 artifact")"
ra3_ra_path="${ra3_ra_info% *}"
ra3_digest="${ra3_ra_info#* }"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-ra4.json" "ra4" "$tt" "$td" "$ra3_ra_path" "$ra3_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, tt, td, ra_path, ra_digest = sys.argv[1:7]
run_id = "test-run-ra4"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "cross session",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": run_id, "diff_evidence": "sha256:cd318ca49ed5dd670f49252da4c6997a64a791c27d2e239dfdd70e3c453a3ff6",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
if run_for ra4 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-ra4.json" 2>"$TMP_ROOT/.dev-flow/sessions/ra4.err"; then
  echo "FAIL: cross-session result_artifact should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "boundary\|session\|outside\|not.*in\|cross" "$TMP_ROOT/.dev-flow/sessions/ra4.err" || { echo "FAIL: ra4 cross-session message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ra4.err")" >&2; exit 1; }
echo "OK: cross-session result_artifact rejected"

# ---- 4e: result_artifact 路径逃逸（../）→ 拒绝 ----
run_for ra5 start --type feature --task "path escape" >/dev/null
run_for ra5 confirm-plan >/dev/null
run_env_health ra5
state_file="$TMP_ROOT/.dev-flow/sessions/ra5.json"
ticket_info="$(inject_review_ticket "ra5" "agent/openai-reviewer" "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38" "code-quality-review" "$state_file" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
# 用 ../ 逃逸路径（指向 .dev-flow/ 外的文件）
# 文件写到 .dev-flow/ 内（不影响 digest），但路径用 ../ 构造逃逸
echo "escape" > "$TMP_ROOT/.dev-flow/sessions/escape-ra5.json"
escape_path="$TMP_ROOT/.dev-flow/sessions/../../../escape-ra5-target.json"
echo "target" > "$TMP_ROOT/.dev-flow/sessions/escape-ra5-target.json"
escape_digest="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(open('$TMP_ROOT/.dev-flow/sessions/escape-ra5-target.json','rb').read()).hexdigest())")"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-ra5.json" "ra5" "$tt" "$td" "$escape_path" "$escape_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, tt, td, ra_path, ra_digest = sys.argv[1:7]
run_id = "test-run-ra5"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "path escape",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1c07278136374b37cfb788cbc392672cc68392af2b62d681c1de196d6f3a7f38",
    "run_id": run_id, "diff_evidence": "sha256:2aa6603e5e980052e4677b6508d957eb397ac024eeaf3792e4c8194063bbf068",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
if run_for ra5 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-ra5.json" 2>"$TMP_ROOT/.dev-flow/sessions/ra5.err"; then
  echo "FAIL: path-escaping result_artifact should be rejected" >&2
  exit 1
fi
/usr/bin/grep -q "boundary\|outside\|escape\|not.*in\|parent" "$TMP_ROOT/.dev-flow/sessions/ra5.err" || { echo "FAIL: ra5 path escape message wrong: $(cat "$TMP_ROOT/.dev-flow/sessions/ra5.err")" >&2; exit 1; }
echo "OK: path-escaping result_artifact rejected"

# ============================================================
# 5. symlink 防护测试（atomic_json_write.py 模块）
# 详细的 symlink/trusted-root/正常路径测试见 test-reviewer-major-fixes.sh
# ============================================================

# ---- 5a: 正常（非 symlink）PROJECT_ROOT + .dev-flow → install 通过 ----
TMP_SL4="$(/usr/bin/mktemp -d)"
/usr/bin/git -C "$TMP_SL4" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_SL4" init -q && /usr/bin/git -C "$TMP_SL4" checkout -qb main; }
/usr/bin/git -C "$TMP_SL4" config user.email "test@example.com"
/usr/bin/git -C "$TMP_SL4" config user.name "test"
printf 'base\n' > "$TMP_SL4/base.txt"
/usr/bin/git -C "$TMP_SL4" add base.txt
/usr/bin/git -C "$TMP_SL4" commit -qm "init"
# macOS /var/folders 下的 tmpdir 不被遍历祖先
if ! /bin/bash "$ROOT/scripts/install-review-backend.sh" \
  --project "$TMP_SL4" --review-backend agent/openai-reviewer \
  --skip-mcp-config 2>"$TMP_SL4/sl4.err"; then
  echo "FAIL: normal (non-symlink) project should pass: $(cat "$TMP_SL4/sl4.err")" >&2
  exit 1
fi
echo "OK: normal (non-symlink) PROJECT_ROOT + .dev-flow accepted"
/bin/rm -rf -- "$TMP_SL4"

echo ""
echo "PASS: Round 3 review ticket advanced features (worktree digest staged/unstaged/untracked, non-git fail-closed, overwrite/cancel, route whitelist, result artifact validation, symlink protection) all covered"
