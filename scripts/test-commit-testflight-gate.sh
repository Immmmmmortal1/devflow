#!/usr/bin/env bash
# commit / testflight 入口测试：
# commit 收口（approve 前置、暂存区校验、hash 记录、HEAD 一致性）；
# testflight 委托项目命令（未配置 blocked、成功登记、HEAD 漂移拒绝、失败登记、
# DEV_FLOW_TESTFLIGHT_CMD 仅测试模式生效）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# TMP_ROOT 同时作为 git 业务项目
/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_ROOT" init -q && /usr/bin/git -C "$TMP_ROOT" checkout -qb main; }
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'init\n' > "$TMP_ROOT/app.txt"
/usr/bin/git -C "$TMP_ROOT" add app.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "init"
printf '.dev-flow/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:739023b65d327595c397b44d2c981e1c2b2e587a68dcacfcb68ced5fce4fe7d8",
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
  ticket_info="$(inject_review_ticket "$session_id" "agent/openai-reviewer" "sha256:739023b65d327595c397b44d2c981e1c2b2e587a68dcacfcb68ced5fce4fe7d8" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/$session_id.json" "$TMP_ROOT")"
  local tt="${ticket_info% *}"
  local td="${ticket_info#* }"
  local ra_info
  ra_info="$(inject_result_artifact "$session_id" "$TMP_ROOT/.dev-flow/sessions/$session_id.json" "$TMP_ROOT" "pass" "test-run-commit" "test review pass")"
  local ra_path="${ra_info% *}"
  local ra_digest="${ra_info#* }"
  /usr/bin/python3 - "$TMP_ROOT" "$session_id" "$tt" "$td" "$ra_path" "$ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
root = Path(sys.argv[1])
session_id = sys.argv[2]
tt, td, ra_path, ra_digest = sys.argv[3:7]
run_id = "test-run-commit"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
# 报告写到 .dev-flow/sessions/ 下（从 worktree digest 排除，避免 digest 漂移）
(root / ".dev-flow" / "sessions" / f"review-{session_id}.json").write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:739023b65d327595c397b44d2c981e1c2b2e587a68dcacfcb68ced5fce4fe7d8",
    "run_id": run_id, "diff_evidence": "sha256:745d1066289590bc812ccd4db329198c39b7c60a65ed9c752dd4331f58476b0e",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
}

# trivial 链路走到 approve-commit（commit 入口的前置）
setup_approved() {
  local session_id="$1"
  run_for "$session_id" start --type feature --level trivial --task "$session_id" >/dev/null
  run_for "$session_id" confirm-plan >/dev/null
  run_health_review_only "$session_id"
  write_review_pass "$session_id"
  run_for "$session_id" record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-$session_id.json" >/dev/null
  run_for "$session_id" approve-commit >/dev/null
}

stage_change() {
  local name="$1"
  printf 'change %s\n' "$name" > "$TMP_ROOT/$name.txt"
  /usr/bin/git -C "$TMP_ROOT" add "$name.txt"
}

head_of() {
  /usr/bin/git -C "$TMP_ROOT" rev-parse HEAD
}

# ---- 用例 1：未 approve-commit 时 commit 拒绝 ----
run_for s1 start --type feature --level trivial --task "s1" >/dev/null
stage_change f1
if run_for s1 commit --message "should fail" >/dev/null 2>&1; then
  echo "FAIL: commit passed without approve-commit" >&2
  exit 1
fi
/usr/bin/git -C "$TMP_ROOT" reset -q

# ---- 用例 2：approve 后暂存区为空 → commit 拒绝 ----
setup_approved s2
if run_for s2 commit --message "nothing staged" 2>"$TMP_ROOT/s2.err"; then
  echo "FAIL: commit passed with empty staging area" >&2
  exit 1
fi
/usr/bin/grep -q "No staged changes" "$TMP_ROOT/s2.err" || { echo "FAIL: empty-staging rejection message wrong" >&2; exit 1; }

# ---- 用例 3：暂存后 commit 成功，state 记录 hash/message，testflight 重置 ----
stage_change f2
out="$(run_for s2 commit --message "feat: s2 work")"
printf '%s' "$out" | /usr/bin/grep -q "committed: $(head_of)" || { echo "FAIL: commit output missing hash" >&2; exit 1; }
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s2.json" "$(head_of)" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state.get("committed_at"), state
assert state.get("commit_hash") == sys.argv[2], (state.get("commit_hash"), sys.argv[2])
assert state.get("commit_message") == "feat: s2 work", state.get("commit_message")
assert state["testflight"]["status"] == "not-run", state["testflight"]
PY

# ---- 用例 4：项目规则变更后 commit 拒绝（双层规则机制适用于 commit）----
printf '\n# rule changed\n' >> "$TMP_ROOT/.dev-flow/rules.md"
stage_change f3
if run_for s2 commit --message "should fail" >/dev/null 2>&1; then
  echo "FAIL: commit passed after project rules changed" >&2
  exit 1
fi
/usr/bin/git -C "$TMP_ROOT" reset -q
run_for s2 read-rules >/dev/null

# ---- 用例 5：无 commit 记录时 testflight 拒绝 ----
setup_approved s5
if run_for s5 testflight >/dev/null 2>&1; then
  echo "FAIL: testflight passed without commit" >&2
  exit 1
fi

# ---- 用例 6：未配置 testflight 命令 → blocked 并提示配置方法 ----
stage_change f5
run_for s5 commit --message "feat: s5 work" >/dev/null
if run_for s5 testflight 2>"$TMP_ROOT/s5.err"; then
  echo "FAIL: testflight passed without configured command" >&2
  exit 1
fi
/usr/bin/grep -q "testflight-command" "$TMP_ROOT/s5.err" || { echo "FAIL: unconfigured rejection did not mention testflight-command" >&2; exit 1; }

# ---- 用例 7：配置命令后 testflight 成功并登记证据 ----
cat > "$TMP_ROOT/.dev-flow/testflight-command" <<'EOF'
/usr/bin/python3 -c "import pathlib; pathlib.Path('fastlane-ran.marker').write_text('ok')"
echo "uploaded build 42 to TestFlight"
EOF
run_for s5 testflight >/dev/null
[[ -f "$TMP_ROOT/fastlane-ran.marker" ]] || { echo "FAIL: testflight command did not run in project root" >&2; exit 1; }
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s5.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "uploaded", tf
assert tf["uploaded_at"], tf
assert "uploaded build 42" in (tf["evidence"] or ""), tf
assert tf["command_source"] == "file", tf
PY

# ---- 用例 8：HEAD 漂移后 testflight 拒绝 ----
printf 'drift\n' > "$TMP_ROOT/drift.txt"
/usr/bin/git -C "$TMP_ROOT" add drift.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "drift commit"
if run_for s5 testflight 2>"$TMP_ROOT/s5-drift.err"; then
  echo "FAIL: testflight passed after HEAD drift" >&2
  exit 1
fi
/usr/bin/grep -q "drifted" "$TMP_ROOT/s5-drift.err" || { echo "FAIL: drift rejection message wrong" >&2; exit 1; }

# ---- 用例 9：testflight 命令失败 → state 记 failed，脚本非零退出 ----
cat > "$TMP_ROOT/.dev-flow/testflight-command" <<'EOF'
echo "fastlane pilot failed"
exit 1
EOF
stage_change f6
run_for s5 commit --message "feat: s5 more work" >/dev/null
if run_for s5 testflight >/dev/null 2>&1; then
  echo "FAIL: failing testflight command reported success" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s5.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "failed", tf
assert tf["uploaded_at"] is None, tf
assert "fastlane pilot failed" in (tf["evidence"] or ""), tf
PY

# ---- 用例 10：DEV_FLOW_TESTFLIGHT_CMD 生产模式忽略 / 测试模式生效 ----
/bin/rm -f "$TMP_ROOT/.dev-flow/testflight-command"
# 生产模式：env 覆盖被忽略 → 未配置 blocked
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s5 \
  DEV_FLOW_TESTFLIGHT_CMD="/usr/bin/true" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null 2>&1; then
  echo "FAIL: production mode honored DEV_FLOW_TESTFLIGHT_CMD" >&2
  exit 1
fi
# 测试模式：env 覆盖生效 → 成功
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s5 \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_TESTFLIGHT_CMD="/usr/bin/true" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s5.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "uploaded", tf
assert tf["command_source"] == "env", tf
PY

# ---- 用例 11：已有 uploaded 状态在新 commit 后被重置 ----
setup_approved s11
stage_change f11a
run_for s11 commit --message "feat: s11 first" >/dev/null
cat > "$TMP_ROOT/.dev-flow/testflight-command" <<'EOF'
echo "tf ok"
EOF
run_for s11 testflight >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s11.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["testflight"]["status"] == "uploaded", state["testflight"]
PY
stage_change f11b
run_for s11 commit --message "feat: s11 second" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s11.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "not-run", tf
assert tf["uploaded_at"] is None and tf["evidence"] is None, tf
assert tf.get("command_source") is None, tf
PY

# ---- 用例 12：commit message 注入安全（$( ) / 反引号 / 换行 / 前导 - ）----
setup_approved s12
stage_change f12
INJECT_MSG="bad \$(touch $TMP_ROOT/pwned1) \`touch $TMP_ROOT/pwned2\`"
run_for s12 commit --message "$INJECT_MSG" >/dev/null
[[ ! -e "$TMP_ROOT/pwned1" && ! -e "$TMP_ROOT/pwned2" ]] || { echo "FAIL: commit message command injection executed" >&2; exit 1; }
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s12.json" "$TMP_ROOT" <<'PY'
import json, subprocess, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
actual = subprocess.run(
    ["/usr/bin/git", "-C", sys.argv[2], "log", "-1", "--pretty=%B"],
    capture_output=True, text=True, check=True,
).stdout.strip()
assert state["commit_message"] == actual, (state["commit_message"], actual)
assert "$(touch" in actual and "`touch" in actual, actual
PY
NL_MSG="$(printf 'first line\nsecond line')"
stage_change f12b
run_for s12 commit --message "$NL_MSG" >/dev/null
/usr/bin/git -C "$TMP_ROOT" log -1 --pretty=%B | /usr/bin/grep -q "second line" || { echo "FAIL: newline message not preserved" >&2; exit 1; }
stage_change f12c
run_for s12 commit --message "- leading dash message" >/dev/null
/usr/bin/git -C "$TMP_ROOT" log -1 --pretty=%B | /usr/bin/grep -q "leading dash message" || { echo "FAIL: leading-dash message not preserved" >&2; exit 1; }

# ---- 用例 13：message >200 字符 → 拒绝且不产生 commit ----
setup_approved s13
stage_change f13
HEAD_BEFORE="$(head_of)"
LONG_MSG="$(/usr/bin/python3 -c "print('m' * 201)")"
if run_for s13 commit --message "$LONG_MSG" 2>"$TMP_ROOT/s13.err"; then
  echo "FAIL: >200-char message accepted" >&2
  exit 1
fi
/usr/bin/grep -q "too long" "$TMP_ROOT/s13.err" || { echo "FAIL: long-message rejection message wrong" >&2; exit 1; }
[[ "$(head_of)" == "$HEAD_BEFORE" ]] || { echo "FAIL: rejected message still produced a commit" >&2; exit 1; }
/usr/bin/git -C "$TMP_ROOT" reset -q

# ---- 用例 14：testflight-command 为 symlink → 拒绝 ----
setup_approved s14
stage_change f14
run_for s14 commit --message "feat: s14" >/dev/null
printf '/usr/bin/true\n' > "$TMP_ROOT/tf-real-command"
/bin/rm -f "$TMP_ROOT/.dev-flow/testflight-command"
/bin/ln -s "$TMP_ROOT/tf-real-command" "$TMP_ROOT/.dev-flow/testflight-command"
if run_for s14 testflight >/dev/null 2>&1; then
  echo "FAIL: testflight accepted symlinked command file" >&2
  exit 1
fi
/bin/rm -f "$TMP_ROOT/.dev-flow/testflight-command" "$TMP_ROOT/tf-real-command"

# ---- 用例 15：非法 timeout 值 → 规范化错误（非 traceback）----
cat > "$TMP_ROOT/.dev-flow/testflight-command" <<'EOF'
/usr/bin/true
EOF
for bad in abc 0 -5 86401; do
  if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s14 \
    DEV_FLOW_TESTFLIGHT_TIMEOUT="$bad" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >"$TMP_ROOT/tf-to.out" 2>"$TMP_ROOT/tf-to.err"; then
    echo "FAIL: invalid timeout '$bad' accepted" >&2
    exit 1
  fi
  /usr/bin/grep -q "DEV_FLOW_TESTFLIGHT_TIMEOUT" "$TMP_ROOT/tf-to.err" || { echo "FAIL: invalid timeout '$bad' error not normalized" >&2; exit 1; }
  if /usr/bin/grep -q "Traceback" "$TMP_ROOT/tf-to.err"; then
    echo "FAIL: invalid timeout '$bad' produced a traceback" >&2
    exit 1
  fi
done

# ---- 用例 16：真实超时 → failed 且证据含 timed out ----
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s14 \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_TESTFLIGHT_TIMEOUT=1 \
  DEV_FLOW_TESTFLIGHT_CMD="/bin/sleep 5" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null 2>&1; then
  echo "FAIL: sleeping testflight command reported success" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s14.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "failed", tf
assert "timed out" in (tf["evidence"] or ""), tf
PY

# ---- 用例 17：大输出命令 → 证据截断 ≤1000 字符 ----
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s14 \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_TESTFLIGHT_CMD="/usr/bin/python3 -c \"print('x' * 200000)\"" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null 2>&1; then
  echo "FAIL: large-output testflight command failed" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s14.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "uploaded", tf
assert len(tf["evidence"] or "") <= 1000, len(tf["evidence"] or "")
PY

# ---- 用例 18：项目根非 git repo → review 和 commit 均拒绝 ----
# 非 git 项目无法签发 ticket（worktree_digest.py 要求 git），record-gate fail closed
TMP_NG="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_NG/.dev-flow/sessions"
run_ng() {
  DEV_FLOW_PROJECT_ROOT="$TMP_NG" DEV_FLOW_SESSION_ID=ng \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}
run_ng start --type feature --level trivial --task "ng" >/dev/null
run_ng confirm-plan >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_NG" DEV_FLOW_SESSION_ID=ng \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
# 非 git 项目签发 ticket 应失败（worktree_digest.py 要求 git）
if inject_review_ticket "ng" "agent/openai-reviewer" "sha256:739023b65d327595c397b44d2c981e1c2b2e587a68dcacfcb68ced5fce4fe7d8" "code-quality-review" "$TMP_NG/.dev-flow/sessions/ng.json" "$TMP_NG" >/dev/null 2>&1; then
  echo "FAIL: ticket injection should fail for non-git project" >&2
  exit 1
fi
echo "OK: non-git project ticket injection rejected"
# 非 git 项目 record-gate 应失败（无有效 ticket + worktree_digest 不可重算）
if run_ng record-gate --name review --report "$TMP_NG/.dev-flow/sessions/review-ng.json" 2>/dev/null; then
  echo "FAIL: record-gate should fail for non-git project" >&2
  exit 1
fi
echo "OK: non-git project record-gate rejected"
# 非 git 项目 commit 应失败（无法通过 review → 无法 approve → commit 被拒）
if run_ng commit --message "should fail" 2>"$TMP_NG/ng.err"; then
  echo "FAIL: commit passed in non-git project root" >&2
  exit 1
fi
echo "OK: non-git project commit rejected (cannot complete full flow without git)"
/bin/rm -rf -- "$TMP_NG"

# ---- 用例 19：git commit 执行失败 → state 不写入 committed 记录 ----
setup_approved s19
stage_change f19
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/.git/hooks/pre-commit"
/bin/chmod +x "$TMP_ROOT/.git/hooks/pre-commit"
if run_for s19 commit --message "will fail via hook" >/dev/null 2>&1; then
  echo "FAIL: commit passed despite failing pre-commit hook" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s19.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state.get("committed_at") is None, state
assert state.get("commit_hash") is None, state
PY
/bin/rm -f "$TMP_ROOT/.git/hooks/pre-commit"
/usr/bin/git -C "$TMP_ROOT" reset -q

# ---- 用例 20：git 规范化后 state 记录实际提交内容（首尾空白/末尾换行）----
setup_approved s20
stage_change f20
run_for s20 commit --message "$(printf '  padded message with trailing space  \n\n\n')" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s20.json" "$TMP_ROOT" <<'PY'
import json, subprocess, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
actual = subprocess.run(
    ["/usr/bin/git", "-C", sys.argv[2], "log", "-1", "--pretty=%B"],
    capture_output=True, text=True, check=True,
).stdout.strip()
assert state["commit_message"] == actual, (state["commit_message"], actual)
assert actual == "padded message with trailing space", actual
PY

# ---- 用例 21：超时时整个进程组被终止（子进程不残留）----
setup_approved s21
stage_change f21
run_for s21 commit --message "feat: s21" >/dev/null
/bin/rm -f "$TMP_ROOT/grandchild.marker"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s21 \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_TESTFLIGHT_TIMEOUT=1 \
  DEV_FLOW_TESTFLIGHT_CMD="( /bin/sleep 3; /usr/bin/touch $TMP_ROOT/grandchild.marker ) & wait" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null 2>&1; then
  echo "FAIL: timed-out testflight command reported success" >&2
  exit 1
fi
/bin/sleep 4
[[ ! -e "$TMP_ROOT/grandchild.marker" ]] || { echo "FAIL: grandchild process survived testflight timeout (process group not killed)" >&2; exit 1; }

# ---- 用例 22：后台脱离命令不得登记成功；进程组超时整组终止 ----
setup_approved s22
stage_change f22
run_for s22 commit --message "feat: s22" >/dev/null
/bin/rm -f "$TMP_ROOT/detached.marker"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=s22 \
  DEV_FLOW_TEST_MODE=1 DEV_FLOW_TESTFLIGHT_TIMEOUT=1 \
  DEV_FLOW_TESTFLIGHT_CMD="( /bin/sleep 3; /usr/bin/touch $TMP_ROOT/detached.marker ) &" \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" testflight >/dev/null 2>&1; then
  echo "FAIL: background-detached testflight command recorded success" >&2
  exit 1
fi
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/s22.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
tf = state["testflight"]
assert tf["status"] == "failed", tf
assert "timed out" in (tf["evidence"] or ""), tf
PY
/bin/sleep 4
[[ ! -e "$TMP_ROOT/detached.marker" ]] || { echo "FAIL: detached child survived process-group kill" >&2; exit 1; }

# ---- 用例 23：hook 改写 message 超 200 → 拒绝静默截断（显式报错）----
setup_approved s23
stage_change f23
cat > "$TMP_ROOT/.git/hooks/commit-msg" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "$1" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text(p.read_text() + "\n" + "h" * 300 + "\n")
PY
EOF
/bin/chmod +x "$TMP_ROOT/.git/hooks/commit-msg"
HEAD_BEFORE_HOOK="$(head_of)"
if run_for s23 commit --message "short but hook inflates" 2>"$TMP_ROOT/s23.err"; then
  echo "FAIL: hook-inflated >200 message silently truncated" >&2
  exit 1
fi
/usr/bin/grep -q "exceeds 200" "$TMP_ROOT/s23.err" || { echo "FAIL: hook-inflate rejection message wrong" >&2; exit 1; }
# 恢复路径：soft reset 后缩短 message 重跑 commit 成功
/bin/rm -f "$TMP_ROOT/.git/hooks/commit-msg"
/usr/bin/git -C "$TMP_ROOT" reset --soft HEAD~1
[[ "$(head_of)" == "$HEAD_BEFORE_HOOK" ]] || { echo "FAIL: soft reset did not restore HEAD" >&2; exit 1; }
run_for s23 commit --message "short message" >/dev/null

echo "PASS: commit gate closes on approval and records hash; testflight delegates to project command with HEAD pinning; injection/timeout/symlink/reset boundaries covered"
