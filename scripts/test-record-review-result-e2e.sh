#!/usr/bin/env bash
# 端到端测试：stdin JSON → record-review-result.sh → record-gate
# 不使用 helper 模拟 artifact，真实走 record-review-result.sh 全流程
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

# git init（record-gate 需要 worktree_digest）
/usr/bin/git -C "$TMP" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP" init -q && /usr/bin/git -C "$TMP" checkout -qb main; }
/usr/bin/git -C "$TMP" config user.email "test@example.com"
/usr/bin/git -C "$TMP" config user.name "test"
printf 'base\n' > "$TMP/base.txt"
/usr/bin/git -C "$TMP" add base.txt
/usr/bin/git -C "$TMP" commit -qm "init"
printf '.dev-flow/\n*.err\nok-probe\n' > "$TMP/.gitignore"
/usr/bin/git -C "$TMP" add .gitignore
/usr/bin/git -C "$TMP" commit -qm "gitignore"

/bin/mkdir -p "$TMP/.dev-flow/sessions"

run_for() {
  local sid="$1"; shift
  DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID="$sid" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_env_health() {
  local sid="$1"
  DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID="$sid" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
}

# probe
cat > "$TMP/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:b18806ea326af79bc21fb99964ff4447715ecce0280766d924db6bfeb5a8dd11",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP/ok-probe"

source "$ROOT/scripts/test-helper-inject-ticket.sh"

# ============================================================
# 1. 真实 stdin JSON → record-review-result.sh → record-gate pass
# ============================================================

run_for e2e1 start --type feature --task "e2e record-review-result" >/dev/null
run_for e2e1 confirm-plan >/dev/null
run_env_health e2e1

state_file="$TMP/.dev-flow/sessions/e2e1.json"

# 注入 ticket（record-review-result.sh 需要 ticket 在 state 中）
ticket_info="$(inject_review_ticket "e2e1" "agent/openai-reviewer" "sha256:b18806ea326af79bc21fb99964ff4447715ecce0280766d924db6bfeb5a8dd11" "code-quality-review" "$state_file" "$TMP")"
TICKET_TOKEN="${ticket_info% *}"
TICKET_DIGEST="${ticket_info#* }"

# 构建真实 stdin JSON（adapter 结果）
run_id="e2e-run-1"
adapter_ref="opencode-task-${run_id}"
adapter_digest="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(b'canonicalized handoff for ${run_id}').hexdigest())")"

stdin_json="$(/usr/bin/python3 -c "
import json
print(json.dumps({
    'status': 'pass',
    'reviewer_result': 'pass',
    'run_id': '${run_id}',
    'evidence': 'e2e test review pass',
    'adapter_result_ref': '${adapter_ref}',
    'adapter_result_digest': '${adapter_digest}',
    'findings': ['no issues found'],
}))
")"

# 调用 record-review-result.sh，捕获 stdout（gate report JSON）
report_json="$(echo "$stdin_json" | DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID=e2e1 \
  /bin/bash "$ROOT/scripts/record-review-result.sh" 2>"$TMP/.dev-flow/e2e1.err")" || {
  echo "FAIL: record-review-result.sh failed: $(cat "$TMP/.dev-flow/e2e1.err")" >&2
  exit 1
}

# 验证 stdout 是有效 JSON 且包含必需字段
/usr/bin/python3 -c "
import json, sys
report = json.loads('''$report_json''')
assert report['producer'] == 'code-review-workflow', f'producer={report[\"producer\"]}'
assert report['session_id'] == 'e2e1', f'session_id={report[\"session_id\"]}'
assert report['status'] == 'pass', f'status={report[\"status\"]}'
assert report['adapter_result_ref'] == '${adapter_ref}', f'ref mismatch'
assert report['adapter_result_digest'] == '${adapter_digest}', f'digest mismatch'
assert report['result_artifact'].startswith('$TMP/.dev-flow/sessions/'), f'artifact path={report[\"result_artifact\"]}'
assert report['result_artifact_digest'].startswith('sha256:'), f'digest={report[\"result_artifact_digest\"]}'
assert report['ticket_token'] == '${TICKET_TOKEN}', f'token mismatch'
assert report['ticket_digest'] == '${TICKET_DIGEST}', f'ticket digest mismatch'
print('OK: record-review-result.sh outputs valid gate report with all fields')
"

# 验证 result artifact 真实写到项目 sessions 目录
ra_path="$(echo "$report_json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["result_artifact"])')"
ra_digest="$(echo "$report_json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["result_artifact_digest"])')"

[[ -f "$ra_path" ]] || { echo "FAIL: result artifact file not created at $ra_path" >&2; exit 1; }
[[ "$ra_path" == "$TMP/.dev-flow/sessions/.e2e1.review-result.json" ]] || {
  echo "FAIL: result artifact not in project sessions dir: $ra_path" >&2; exit 1
}
echo "OK: result artifact written to project sessions dir"

# 验证 result artifact 内容
/usr/bin/python3 -c "
import json
from pathlib import Path
ra = json.loads(Path('$ra_path').read_text())
assert ra['producer'] == 'code-review-workflow'
assert ra['session_id'] == 'e2e1'
assert ra['adapter'] == 'agent/openai-reviewer'
assert ra['adapter_result_ref'] == '${adapter_ref}'
assert ra['adapter_result_digest'] == '${adapter_digest}'
assert ra['status'] == 'pass'
assert ra['reviewer_result'] == 'pass'
print('OK: result artifact content valid')
"

# 验证 digest 一致
actual_digest="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(open('$ra_path','rb').read()).hexdigest())")"
[[ "$actual_digest" == "$ra_digest" ]] || {
  echo "FAIL: digest mismatch: actual=$actual_digest expected=$ra_digest" >&2; exit 1
}
echo "OK: result artifact digest matches report"

# 验证 gate report 也写到项目 sessions 目录
report_path="$TMP/.dev-flow/sessions/.e2e1.review-report.json"
[[ -f "$report_path" ]] || { echo "FAIL: gate report file not created at $report_path" >&2; exit 1; }
echo "OK: gate report written to project sessions dir"

# 现在 record-gate：把 record-review-result.sh 的 stdout 写到报告文件，然后 record-gate
# 注意：record-review-result.sh 的 stdout 就是 gate report，record-gate 读取的是同一个报告文件
# 但 record-gate 需要报告路径作为 --report 参数。我们用 record-review-result.sh 生成的报告文件。

run_for e2e1 record-gate --name review --report "$report_path" 2>&1 | tee "$TMP/.dev-flow/record-gate.out" || {
  echo "FAIL: record-gate failed with real record-review-result report" >&2
  cat "$TMP/.dev-flow/record-gate.out" | tail -5 >&2
  exit 1
}
echo "OK: record-gate accepts real record-review-result.sh output (full e2e pass)"

# ============================================================
# 2. record-review-result.sh 缺少 adapter_result_ref → 拒绝
# ============================================================

run_for e2e2 start --type feature --task "missing ref" >/dev/null
run_for e2e2 confirm-plan >/dev/null
run_env_health e2e2
state_file2="$TMP/.dev-flow/sessions/e2e2.json"
inject_review_ticket "e2e2" "agent/openai-reviewer" "sha256:b18806ea326af79bc21fb99964ff4447715ecce0280766d924db6bfeb5a8dd11" "code-quality-review" "$state_file2" "$TMP" >/dev/null

# stdin 缺少 adapter_result_ref
bad_json='{"status":"pass","reviewer_result":"pass","run_id":"bad","evidence":"missing ref","adapter_result_digest":"sha256:abc"}'

if echo "$bad_json" | DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID=e2e2 \
  /bin/bash "$ROOT/scripts/record-review-result.sh" 2>/dev/null; then
  echo "FAIL: record-review-result should reject missing adapter_result_ref" >&2
  exit 1
fi
echo "OK: record-review-result rejects missing adapter_result_ref"

# ============================================================
# 3. record-review-result.sh 缺少 adapter_result_digest → 拒绝
# ============================================================

run_for e2e3 start --type feature --task "missing digest" >/dev/null
run_for e2e3 confirm-plan >/dev/null
run_env_health e2e3
state_file3="$TMP/.dev-flow/sessions/e2e3.json"
inject_review_ticket "e2e3" "agent/openai-reviewer" "sha256:b18806ea326af79bc21fb99964ff4447715ecce0280766d924db6bfeb5a8dd11" "code-quality-review" "$state_file3" "$TMP" >/dev/null

bad_json2='{"status":"pass","reviewer_result":"pass","run_id":"bad2","evidence":"missing digest","adapter_result_ref":"ref"}'

if echo "$bad_json2" | DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID=e2e3 \
  /bin/bash "$ROOT/scripts/record-review-result.sh" 2>/dev/null; then
  echo "FAIL: record-review-result should reject missing adapter_result_digest" >&2
  exit 1
fi
echo "OK: record-review-result rejects missing adapter_result_digest"

# ============================================================
# 4. record-review-result.sh trusted_root 正确：artifact 在项目 .dev-flow，不在 source .dev-flow
# ============================================================

# 验证 artifact 路径确实是项目 sessions，不是 devflow source sessions
source_devflow="$TMP/.dev-flow"  # 这是项目的 .dev-flow
devflow_source="$ROOT/.dev-flow"  # 这是 devflow 源码的 .dev-flow

# 确认 artifact 在项目的 .dev-flow 下，不在 devflow 源码的 .dev-flow 下
[[ "$ra_path" == "$source_devflow/sessions/.e2e1.review-result.json" ]] || {
  echo "FAIL: artifact should be under project .dev-flow, got: $ra_path" >&2
  exit 1
}
[[ ! -f "$devflow_source/sessions/.e2e1.review-result.json" ]] || {
  echo "FAIL: artifact should NOT be under devflow source .dev-flow" >&2
  exit 1
}
echo "OK: trusted_root correctly uses project .dev-flow (not source_root .dev-flow)"

# ============================================================
# 5. record-review-result.sh revise 状态 → record-gate revise
# ============================================================

run_for e2e5 start --type feature --task "revise e2e" >/dev/null
run_for e2e5 confirm-plan >/dev/null
run_env_health e2e5
state_file5="$TMP/.dev-flow/sessions/e2e5.json"
inject_review_ticket "e2e5" "agent/openai-reviewer" "sha256:b18806ea326af79bc21fb99964ff4447715ecce0280766d924db6bfeb5a8dd11" "code-quality-review" "$state_file5" "$TMP" >/dev/null

run_id5="e2e-run-revise"
ref5="opencode-task-${run_id5}"
digest5="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(b'handoff revise').hexdigest())")"

stdin_json5="$(/usr/bin/python3 -c "
import json
print(json.dumps({
    'status': 'revise',
    'reviewer_result': 'revise',
    'run_id': '${run_id5}',
    'evidence': 'e2e test review revise',
    'adapter_result_ref': '${ref5}',
    'adapter_result_digest': '${digest5}',
}))
")"

report5="$(echo "$stdin_json5" | DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_SESSION_ID=e2e5 \
  /bin/bash "$ROOT/scripts/record-review-result.sh" 2>"$TMP/.dev-flow/e2e5.err")" || {
  echo "FAIL: record-review-result.sh revise failed: $(cat "$TMP/.dev-flow/e2e5.err")" >&2
  exit 1
}

/usr/bin/python3 -c "
import json
r = json.loads('''$report5''')
assert r['status'] == 'revise', f'status={r[\"status\"]}'
assert r['reviewer_result'] == 'revise'
print('OK: record-review-result.sh revise status works')
"

report_path5="$TMP/.dev-flow/sessions/.e2e5.review-report.json"
run_for e2e5 record-gate --name review --report "$report_path5" >/dev/null 2>&1 || {
  echo "FAIL: record-gate revise failed" >&2
  exit 1
}
echo "OK: record-gate accepts revise from real record-review-result.sh"

echo ""
echo "PASS: record-review-result.sh end-to-end (real stdin JSON → artifact → record-gate, trusted_root = project .dev-flow)"
