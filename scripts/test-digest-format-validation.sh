#!/usr/bin/env bash
# 统一 digest 格式校验测试
# 验证：sha256: 后严格 64 位小写十六进制，覆盖 adapter_result_digest/config_digest/ticket_digest/diff_evidence
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# 创建 git repo（worktree digest 测试需要）
git init "$TMP_ROOT" >/dev/null 2>&1
git -C "$TMP_ROOT" config user.email "test@test.com"
git -C "$TMP_ROOT" config user.name "test"
printf 'placeholder\n' > "$TMP_ROOT/.gitkeep"
git -C "$TMP_ROOT" add .gitkeep
git -C "$TMP_ROOT" commit -m "init" >/dev/null 2>&1

# ok-probe
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-dig-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111",
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
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

VALID_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup_session() {
  local sid="$1"
  run_for "$sid" start --type feature --task "digest test" >/dev/null
  run_for "$sid" confirm-plan >/dev/null
  run_env_health "$sid" >/dev/null
}

write_report_with_digest() {
  local path="$1" session_id="$2" digest_field="$3" digest_value="$4"
  local tt="${5:-}" td="${6:-}"
  /usr/bin/python3 - "$path" "$session_id" "$digest_field" "$digest_value" "$tt" "$td" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, session_id, digest_field, digest_value, tt, td = sys.argv[1:7]
report = {
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    "run_id": "test-run-dig",
    "diff_evidence": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    "adapter_result_ref": "test-host-ref-dig",
    "adapter_result_digest": "sha256:" + hashlib.sha256(b"test-handoff-dig").hexdigest(),
}
if tt and td:
    report["ticket_token"] = tt
    report["ticket_digest"] = td
# 覆盖指定 digest 字段为测试值
report[digest_field] = digest_value
# 如果有 ticket，创建 result artifact
if tt and td:
    import os, tempfile
    state_path = Path(f"{path.rsplit('/', 1)[0]}/{session_id}.json")
    state = json.loads(state_path.read_text())
    rt = state["review_ticket"]
    ra_path = state_path.parent / f".{session_id}.review-result.json"
    result = {
        "producer": "code-review-workflow",
        "session_id": session_id,
        "adapter": rt["selected_adapter"],
        "config_digest": rt["config_digest"],
        "ticket_digest": rt["ticket_digest"],
        "route": rt["route"],
        "worktree_digest": rt.get("worktree_digest", ""),
        "run_id": "test-run-dig",
        "adapter_result_ref": "test-host-ref-dig",
        "adapter_result_digest": "sha256:" + hashlib.sha256(b"test-handoff-dig").hexdigest(),
        "status": "pass", "reviewer_result": "pass",
        "evidence": "test pass",
    }
    fd, tmp = tempfile.mkstemp(dir=str(ra_path.parent), prefix=".ra-", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2); f.write("\n")
    os.chmod(tmp, 0o600); os.replace(tmp, str(ra_path))
    ra_digest = "sha256:" + hashlib.sha256(ra_path.read_bytes()).hexdigest()
    report["result_artifact"] = str(ra_path)
    report["result_artifact_digest"] = ra_digest
Path(path).write_text(json.dumps(report) + "\n")
PY
}

# ============================================================
# 1. 无效 config_digest（无 sha256: 前缀）→ 拒绝
# ============================================================
echo "=== test 1: config_digest without sha256: prefix → rejected ==="
setup_session dig1
tt_td="$(inject_review_ticket dig1 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig1.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r1.json" dig1 config_digest "not-a-digest" "$tt" "$td"
if run_for dig1 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r1.json" >/dev/null 2>&1; then
  echo "FAIL: config_digest without prefix should be rejected" >&2; exit 1
fi
echo "OK: config_digest without prefix → rejected"

# ============================================================
# 2. 无效 config_digest（sha256: 后非 64 hex）→ 拒绝
# ============================================================
echo "=== test 2: config_digest with short hex → rejected ==="
setup_session dig2
tt_td="$(inject_review_ticket dig2 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig2.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r2.json" dig2 config_digest "sha256:abc123" "$tt" "$td"
if run_for dig2 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r2.json" >/dev/null 2>&1; then
  echo "FAIL: config_digest with short hex should be rejected" >&2; exit 1
fi
echo "OK: config_digest with short hex → rejected"

# ============================================================
# 3. 无效 config_digest（sha256: 后大写 hex）→ 拒绝
# ============================================================
echo "=== test 3: config_digest with uppercase hex → rejected ==="
setup_session dig3
tt_td="$(inject_review_ticket dig3 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig3.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r3.json" dig3 config_digest "sha256:ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD" "$tt" "$td"
if run_for dig3 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r3.json" >/dev/null 2>&1; then
  echo "FAIL: config_digest with uppercase hex should be rejected" >&2; exit 1
fi
echo "OK: config_digest with uppercase hex → rejected"

# ============================================================
# 4. 无效 ticket_digest（无 sha256: 前缀）→ 拒绝
# ============================================================
echo "=== test 4: ticket_digest without prefix → rejected ==="
setup_session dig4
tt_td="$(inject_review_ticket dig4 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig4.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r4.json" dig4 ticket_digest "not-a-digest" "$tt" "$td"
if run_for dig4 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r4.json" >/dev/null 2>&1; then
  echo "FAIL: ticket_digest without prefix should be rejected" >&2; exit 1
fi
echo "OK: ticket_digest without prefix → rejected"

# ============================================================
# 5. 无效 diff_evidence（无 sha256: 前缀）→ 拒绝
# ============================================================
echo "=== test 5: diff_evidence without prefix → rejected ==="
setup_session dig5
tt_td="$(inject_review_ticket dig5 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig5.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r5.json" dig5 diff_evidence "not-a-digest" "$tt" "$td"
if run_for dig5 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r5.json" >/dev/null 2>&1; then
  echo "FAIL: diff_evidence without prefix should be rejected" >&2; exit 1
fi
echo "OK: diff_evidence without prefix → rejected"

# ============================================================
# 6. 无效 adapter_result_digest（sha256: 后非 64 hex）→ 拒绝
# ============================================================
echo "=== test 6: adapter_result_digest with short hex → rejected ==="
setup_session dig6
tt_td="$(inject_review_ticket dig6 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig6.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r6.json" dig6 adapter_result_digest "sha256:short" "$tt" "$td"
if run_for dig6 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r6.json" >/dev/null 2>&1; then
  echo "FAIL: adapter_result_digest with short hex should be rejected" >&2; exit 1
fi
echo "OK: adapter_result_digest with short hex → rejected"

# ============================================================
# 7. 有效 digest 全部通过 → 成功
# ============================================================
echo "=== test 7: all valid digests → accepted ==="
setup_session dig7
tt_td="$(inject_review_ticket dig7 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig7.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
# 不覆盖任何 digest 字段，使用 write_report_with_digest 的默认有效值
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r7.json" dig7 config_digest "$VALID_DIGEST" "$tt" "$td"
if ! run_for dig7 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r7.json" >/dev/null 2>&1; then
  echo "FAIL: all valid digests should be accepted" >&2; exit 1
fi
echo "OK: all valid digests → accepted"

# ============================================================
# 8. record-review-result.sh 拒绝无效 adapter_result_digest
# ============================================================
echo "=== test 8: record-review-result.sh rejects invalid adapter_result_digest ==="
setup_session dig8
inject_review_ticket dig8 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig8.json" "$TMP_ROOT" >/dev/null

# 传入无效 adapter_result_digest
bad_json='{"status":"pass","reviewer_result":"pass","run_id":"bad","evidence":"bad","adapter_result_ref":"ref","adapter_result_digest":"sha256:short"}'
if echo "$bad_json" | DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=dig8 \
  /bin/bash "$ROOT/scripts/record-review-result.sh" 2>/dev/null; then
  echo "FAIL: record-review-result should reject invalid adapter_result_digest" >&2; exit 1
fi
echo "OK: record-review-result.sh rejects invalid adapter_result_digest"

# ============================================================
# 9. config_digest 65 hex（多一位）→ 拒绝
# ============================================================
echo "=== test 9: config_digest with 65 hex chars → rejected ==="
setup_session dig9
tt_td="$(inject_review_ticket dig9 agent/openai-reviewer "$VALID_DIGEST" code-quality-review "$TMP_ROOT/.dev-flow/sessions/dig9.json" "$TMP_ROOT")"
tt="${tt_td% *}" td="${tt_td#* }"
write_report_with_digest "$TMP_ROOT/.dev-flow/sessions/r9.json" dig9 config_digest "sha256:11111111111111111111111111111111111111111111111111111111111111111" "$tt" "$td"
if run_for dig9 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/r9.json" >/dev/null 2>&1; then
  echo "FAIL: config_digest with 65 hex should be rejected" >&2; exit 1
fi
echo "OK: config_digest with 65 hex → rejected"

echo ""
echo "PASS: unified digest format validation (sha256: + 64 hex across config/ticket/diff/adapter)"
