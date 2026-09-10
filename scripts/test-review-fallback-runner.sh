#!/usr/bin/env bash
# gstack-review fallback runner + record-gate 绑定测试：
# runner 只在 fallback 会话放行，注入 banner/gstack SKILL.md/route/审查包/报告模板并签发
# 一次性 fallback_token + packet_digest；record-gate 在 fallback 会话强制三件套
# （token/digest/报告路径），pass 后销毁 token；非 fallback 会话向后兼容。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

# git 业务项目：main 初始提交 + feature 分支改动
/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_ROOT" init -q && /usr/bin/git -C "$TMP_ROOT" checkout -qb main; }
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'base\n' > "$TMP_ROOT/base.txt"
/usr/bin/git -C "$TMP_ROOT" add base.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "base"
/usr/bin/git -C "$TMP_ROOT" checkout -qb feature
printf 'feature work\n' > "$TMP_ROOT/feature-work.txt"
/usr/bin/git -C "$TMP_ROOT" add feature-work.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "feature work"
printf '.dev-flow/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

# fake gstack skill
/bin/mkdir -p "$TMP_ROOT/gstack-skill/review"
cat > "$TMP_ROOT/gstack-skill/review/SKILL.md" <<'EOF'
# gstack review workflow (fake for tests)
按清单审查 diff：SQL 安全、信任边界、副作用。输出 findings。
EOF

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_runner() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/gstack-skill/review" \
    /bin/bash "$ROOT/scripts/run-review-fallback.sh" "$@"
}

craft_state() {
  local session_id="$1" env_json="$2" confirmed="${3:-null}"
  /usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/$session_id.json" "$session_id" "$env_json" "$confirmed" <<'PY'
import json, sys
from pathlib import Path
path, session_id, env_json, confirmed = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
env = json.loads(env_json)
# 根据 env 类型设置 review_selection（模拟 record_environment 产出）
review_mcp = (env.get("checks") or {}).get("review_mcp") or {}
evidence = review_mcp.get("evidence") or ""
if "fallback=gstack-review" in evidence:
    review_selection = {
        "selected_adapter": "skill/gstack",
        "selection_reason": "fallback",
        "config_digest": "sha256:702652b5b4c29de426813882e80065a4dbb175c21fd8210210d0f7d4392d9037",
        "source": "project",
        "resolved_at": env.get("checked_at") or "2026-08-26T00:00:00Z",
        "locked": False,
    }
else:
    review_selection = {
        "selected_adapter": "mcp/orchestrator",
        "selection_reason": "default",
        "config_digest": "sha256:1b5d51f449fc1c5ebfa17d74e470e0597362c33481545fb3242dcc9cfe1f2cb2",
        "source": "project",
        "resolved_at": env.get("checked_at") or "2026-08-26T00:00:00Z",
        "locked": False,
    }
path.write_text(json.dumps({
    "session_id": session_id, "active": True, "type": "feature", "task": session_id,
    "level": "standard", "started_at": "2026-08-26T00:00:00Z",
    "confirmed_at": None if confirmed == "null" else confirmed,
    "commit_approved_at": None, "ended_at": None,
    "required_gates": ["review"],
    "gate_results": {"review": {"status": "pending", "evidence": None, "recorded_at": None}},
    "environment_health": env,
    "review_selection": review_selection,
}) + "\n")
PY
}

ENV_NOT_RUN='{"status":"not-run","checked_at":null,"checks":{}}'
ENV_MCP='{"status":"available","checked_at":"2026-08-26T00:00:00Z","checks":{"review_mcp":{"status":"available","evidence":"probe_exit_0"}}}'
ENV_FALLBACK='{"status":"available","checked_at":"2026-08-26T00:00:00Z","checks":{"review_mcp":{"status":"available","evidence":"review_mcp_unavailable;fallback=gstack-review;skill=/fake;run=scripts/run-review-fallback.sh"}}}'
CONF='"2026-08-26T00:01:00Z"'

# 从 state 读 review_fallback 三件套（token digest report_path）
read_fb() {
  /usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/$1.json" <<'PY'
import json, sys
from pathlib import Path
fb = (json.loads(Path(sys.argv[1]).read_text()).get("review_fallback") or {})
print(fb.get("token") or "", fb.get("packet_digest") or "", fb.get("report_path") or "")
PY
}

write_fb_report() {
  local session_id="$1" token="$2" digest="$3" path="$4"
  local state_file="$TMP_ROOT/.dev-flow/sessions/$session_id.json"
  # 从 state 读取 ticket_token/ticket_digest（runner 签发后写入 state.review_ticket）
  local tt td
  read -r tt td < <(/usr/bin/python3 - "$state_file" <<'PY'
import json, sys
from pathlib import Path
rt = (json.loads(Path(sys.argv[1]).read_text()).get("review_ticket") or {})
print(rt.get("token") or "", rt.get("ticket_digest") or "")
PY
)
  # 创建 result artifact
  local ra_info
  ra_info="$(inject_result_artifact "$session_id" "$state_file" "$TMP_ROOT" "pass" "fallback-run" "fallback review done per injected gstack workflow")"
  local ra_path="${ra_info% *}"
  local ra_digest="${ra_info#* }"
  /usr/bin/python3 - "$session_id" "$token" "$digest" "$path" "$tt" "$td" "$ra_path" "$ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
session_id, token, digest, path, tt, td, ra_path, ra_digest = sys.argv[1:9]
run_id = "fallback-run"
ref = f"test-host-ref-{run_id}"
adigest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": session_id, "gate": "review",
    "route": "code-quality-review", "review_path": "fallback",
    "fallback_token": token, "packet_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
    "status": "pass", "reviewer_result": "pass",
    "evidence": "fallback review done per injected gstack workflow",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:702652b5b4c29de426813882e80065a4dbb175c21fd8210210d0f7d4392d9037",
    "run_id": run_id,
    "adapter_result_ref": ref, "adapter_result_digest": adigest,
    "diff_evidence": "sha256:8483b031c0c19ec0ef92a40c1aa73c6a5c4c0b196ad082271ab165298bac3ec6",
}) + "\n")
PY
}

# ---- 用例 1：无会话 → 拒绝 ----
if run_runner nosuch >/dev/null 2>&1; then
  echo "FAIL: runner passed without session" >&2
  exit 1
fi

# ---- 用例 2：env 未跑 → 拒绝 ----
craft_state e2 "$ENV_NOT_RUN"
if run_runner e2 2>"$TMP_ROOT/e2.err"; then
  echo "FAIL: runner passed with env not-run" >&2
  exit 1
fi
/usr/bin/grep -q "Environment health not run" "$TMP_ROOT/e2.err" || { echo "FAIL: e2 message wrong" >&2; exit 1; }

# ---- 用例 3：mcp 模式 → 拒绝走 fallback runner ----
craft_state e3 "$ENV_MCP"
if run_runner e3 2>"$TMP_ROOT/e3.err"; then
  echo "FAIL: runner passed in mcp mode" >&2
  exit 1
fi
/usr/bin/grep -q "NOT in gstack-review fallback mode" "$TMP_ROOT/e3.err" || { echo "FAIL: e3 message wrong" >&2; exit 1; }

# ---- 用例 4：fallback 会话 → 五件套注入 + state 写入 review_fallback ----
craft_state e4 "$ENV_FALLBACK"
run_for e4 read-rules >/dev/null
out="$(run_runner e4)"
printf '%s' "$out" | /usr/bin/grep -q "REVIEW FALLBACK MODE" || { echo "FAIL: e4 missing banner" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "禁止开子 Agent" || { echo "FAIL: e4 missing no-subagent instruction" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "gstack review workflow (fake for tests)" || { echo "FAIL: e4 missing gstack SKILL.md injection" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "Code Quality Review Route" || { echo "FAIL: e4 missing route injection" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "feature-work.txt" || { echo "FAIL: e4 missing diff packet" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q '"fallback_token"' || { echo "FAIL: e4 missing token in template" >&2; exit 1; }
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/e4.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
fb = state.get("review_fallback") or {}
assert fb.get("token") and len(fb["token"]) == 32, fb
assert fb.get("packet_digest") and len(fb["packet_digest"]) == 64, fb
assert fb.get("report_path", "").endswith(".review-report.json"), fb
assert fb.get("route") == "code-quality-review", fb
assert state.get("rules", {}).get("project"), state  # runner 保留其他字段
PY

# ---- 用例 5：gstack skill 不存在 → blocked ----
if env -u GSTACK_REVIEW_SKILL_ROOT -u CURSOR_AGENT -u CURSOR_CONVERSATION_ID \
  -u CODEX_HOME -u CODEX_SKILLS_ROOT -u CURSOR_SKILLS_ROOT \
  HOME="$TMP_ROOT/fakehome" \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=e4 \
  /bin/bash "$ROOT/scripts/run-review-fallback.sh" 2>"$TMP_ROOT/e5.err" >/dev/null; then
  echo "FAIL: runner passed without gstack skill" >&2
  exit 1
fi
/usr/bin/grep -q "gstack-review skill not found" "$TMP_ROOT/e5.err" || { echo "FAIL: e5 message wrong" >&2; exit 1; }

# ---- 用例 6：fallback 会话 + 手写报告（无 token）→ 拒 ----
craft_state fb "$ENV_FALLBACK" "$CONF"
run_for fb read-rules >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-fb.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": "fb", "gate": "review", "route": "code-quality-review",
    "review_path": "fallback", "status": "pass", "reviewer_result": "pass",
    "evidence": "hand-written without running the runner",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:702652b5b4c29de426813882e80065a4dbb175c21fd8210210d0f7d4392d9037",
}) + "\n")
PY
if run_for fb record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-fb.json" 2>"$TMP_ROOT/fb.err"; then
  echo "FAIL: hand-written fallback report accepted without token" >&2
  exit 1
fi
/usr/bin/grep -q "fallback_token" "$TMP_ROOT/fb.err" || { echo "FAIL: fb message wrong" >&2; exit 1; }

# ---- 用例 7：完整 runner 流程 → record-gate pass → token 销毁 ----
craft_state fb7 "$ENV_FALLBACK" "$CONF"
run_for fb7 read-rules >/dev/null
run_runner fb7 >/dev/null
read -r FB7_TOKEN FB7_DIGEST FB7_PATH <<< "$(read_fb fb7)"
write_fb_report fb7 "$FB7_TOKEN" "$FB7_DIGEST" "$FB7_PATH"
run_for fb7 record-gate --name review --report "$FB7_PATH" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/fb7.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
assert state["gate_results"]["review"]["status"] == "pass", state["gate_results"]
assert state.get("review_fallback") is None, state.get("review_fallback")
PY

# ---- 用例 7b：packet_digest 篡改 → 拒 ----
craft_state fb7b "$ENV_FALLBACK" "$CONF"
run_for fb7b read-rules >/dev/null
run_runner fb7b >/dev/null
read -r T7B D7B P7B <<< "$(read_fb fb7b)"
write_fb_report fb7b "$T7B" "deadbeef${D7B#deadbeef}" "$P7B"
if run_for fb7b record-gate --name review --report "$P7B" 2>"$TMP_ROOT/fb7b.err"; then
  echo "FAIL: tampered packet_digest accepted" >&2
  exit 1
fi
/usr/bin/grep -q "packet_digest mismatch" "$TMP_ROOT/fb7b.err" || { echo "FAIL: fb7b message wrong" >&2; exit 1; }

# ---- 用例 7c：报告路径不是 runner 签发路径 → 拒 ----
write_fb_report fb7b "$T7B" "$D7B" "$TMP_ROOT/.dev-flow/sessions/wrong-path.json"
if run_for fb7b record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/wrong-path.json" 2>"$TMP_ROOT/fb7c.err"; then
  echo "FAIL: wrong report path accepted" >&2
  exit 1
fi
/usr/bin/grep -q "runner-issued path" "$TMP_ROOT/fb7c.err" || { echo "FAIL: fb7c message wrong" >&2; exit 1; }

# ---- 用例 8：非 fallback 会话 + review_path=bogus → 枚举拒 ----
craft_state fb8 "$ENV_MCP" "$CONF"
run_for fb8 read-rules >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-fb8.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": "fb8", "gate": "review", "route": "code-quality-review",
    "review_path": "bogus", "status": "pass", "reviewer_result": "pass",
    "evidence": "x",
    "selected_adapter": "mcp/orchestrator",
    "config_digest": "sha256:1b5d51f449fc1c5ebfa17d74e470e0597362c33481545fb3242dcc9cfe1f2cb2",
    "run_id": "test-run-fb8", "diff_evidence": "sha256:18a702bb84503db439651f6823403513e728e22ccaa019a502d4214880a71cb1",
}) + "\n")
PY
if run_for fb8 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-fb8.json" 2>"$TMP_ROOT/fb8.err"; then
  echo "FAIL: bogus review_path accepted" >&2
  exit 1
fi
/usr/bin/grep -q 'must be "reviewer", "mcp", or "fallback"' "$TMP_ROOT/fb8.err" || { echo "FAIL: fb8 message wrong" >&2; exit 1; }

# ---- 用例 9：非 fallback 会话 + 无 review_path → 向后兼容通过 ----
craft_state mc "$ENV_MCP" "$CONF"
run_for mc read-rules >/dev/null
# 注入 review_ticket（非 fallback 会话需要统一 ticket）
mc_ticket="$(inject_review_ticket "mc" "mcp/orchestrator" "sha256:1b5d51f449fc1c5ebfa17d74e470e0597362c33481545fb3242dcc9cfe1f2cb2" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/mc.json" "$TMP_ROOT")"
mc_tt="${mc_ticket% *}"
mc_td="${mc_ticket#* }"
mc_ra="$(inject_result_artifact "mc" "$TMP_ROOT/.dev-flow/sessions/mc.json" "$TMP_ROOT" "pass" "test-run-mc" "x")"
mc_ra_path="${mc_ra% *}"
mc_ra_digest="${mc_ra#* }"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/report-mc.json" "$mc_tt" "$mc_td" "$mc_ra_path" "$mc_ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
tt, td, ra_path, ra_digest = sys.argv[2:6]
run_id = "test-run-mc"
ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": "mc", "gate": "review", "route": "code-quality-review",
    "status": "pass", "reviewer_result": "pass", "evidence": "x",
    "selected_adapter": "mcp/orchestrator",
    "config_digest": "sha256:1b5d51f449fc1c5ebfa17d74e470e0597362c33481545fb3242dcc9cfe1f2cb2",
    "run_id": run_id, "diff_evidence": "sha256:a8d6600ff219d338ee8a13b3cf04e9433dfe44e82fce45ec308af4995852b601",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
run_for mc record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/report-mc.json" >/dev/null

# ---- 用例 10：工作区未提交改动（unstaged 修改 + untracked）进入审查包 ----
# 先清掉前序用例在项目根留下的 untracked 测试产物（保留 gstack-skill），
# 避免它们挤占 untracked 内容预算导致目标文件落选
/usr/bin/git -C "$TMP_ROOT" clean -fdq -- . ':!gstack-skill'
craft_state wt "$ENV_FALLBACK"
run_for wt read-rules >/dev/null
printf 'base modified unstaged\n' >> "$TMP_ROOT/base.txt"
printf 'brand new untracked content MARKER_UNTRACKED\n' > "$TMP_ROOT/untracked-new.txt"
out="$(run_runner wt)"
printf '%s' "$out" | /usr/bin/grep -q "base modified unstaged" || { echo "FAIL: unstaged change missing from packet" >&2; exit 1; }
printf '%s' "$out" | /usr/bin/grep -q "MARKER_UNTRACKED" || { echo "FAIL: untracked file content missing from packet" >&2; exit 1; }
/usr/bin/git -C "$TMP_ROOT" checkout -q -- base.txt
/bin/rm -f "$TMP_ROOT/untracked-new.txt"

# ---- 用例 11：DEV_FLOW_REVIEW_BASE 注入防护 ----
craft_state bi "$ENV_FALLBACK"
run_for bi read-rules >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=bi \
  GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/gstack-skill/review" \
  DEV_FLOW_REVIEW_BASE="-HEAD" \
  /bin/bash "$ROOT/scripts/run-review-fallback.sh" >/dev/null 2>&1; then
  echo "FAIL: dash-prefixed base accepted" >&2
  exit 1
fi
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=bi \
  GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/gstack-skill/review" \
  DEV_FLOW_REVIEW_BASE="bogus..ref" \
  /bin/bash "$ROOT/scripts/run-review-fallback.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid ref accepted as base" >&2
  exit 1
fi

# ---- 用例 12：--route 路径穿越拒绝 ----
craft_state rt "$ENV_FALLBACK"
run_for rt read-rules >/dev/null
if run_runner rt --route "../SKILL" >/dev/null 2>&1; then
  echo "FAIL: route traversal accepted" >&2
  exit 1
fi
if run_runner rt --route "nonexistent-route" >/dev/null 2>&1; then
  echo "FAIL: unknown route accepted" >&2
  exit 1
fi

# ---- 用例 13：evidence 伪造变体（非精确分段匹配）→ runner 拒绝 ----
ENV_FAKE1='{"status":"available","checked_at":"x","checks":{"review_mcp":{"status":"available","evidence":"not-fallback=gstack-review"}}}'
ENV_FAKE2='{"status":"available","checked_at":"x","checks":{"review_mcp":{"status":"available","evidence":"fallback=gstack-review-unknown"}}}'
craft_state fake1 "$ENV_FAKE1"
run_for fake1 read-rules >/dev/null
if run_runner fake1 >/dev/null 2>&1; then
  echo "FAIL: forged evidence variant 1 accepted" >&2
  exit 1
fi
craft_state fake2 "$ENV_FAKE2"
run_for fake2 read-rules >/dev/null
if run_runner fake2 >/dev/null 2>&1; then
  echo "FAIL: forged evidence variant 2 accepted" >&2
  exit 1
fi

# ---- 用例 14：大 diff → TOO LARGE 退化且不装载完整 diff ----
craft_state big "$ENV_FALLBACK"
run_for big read-rules >/dev/null
/usr/bin/seq 1 4500 > "$TMP_ROOT/big.txt"
/usr/bin/git -C "$TMP_ROOT" add big.txt
out="$(run_runner big)"
printf '%s' "$out" | /usr/bin/grep -q "TOO LARGE" || { echo "FAIL: large diff did not degrade" >&2; exit 1; }
if printf '%s' "$out" | /usr/bin/grep -q "git diff (full"; then
  echo "FAIL: large diff still loaded in full" >&2
  exit 1
fi
/usr/bin/git -C "$TMP_ROOT" reset -q -- big.txt >/dev/null
/bin/rm -f "$TMP_ROOT/big.txt"

# ---- 用例 7d：签发后篡改 packet 文件 → record-gate 重算 digest 拒绝 ----
craft_state fb7d "$ENV_FALLBACK" "$CONF"
run_for fb7d read-rules >/dev/null
run_runner fb7d >/dev/null
read -r T7D D7D P7D <<< "$(read_fb fb7d)"
PKT7D="$TMP_ROOT/.dev-flow/sessions/.fb7d.review-packet.txt"
printf 'tampered after issue\n' >> "$PKT7D"
write_fb_report fb7d "$T7D" "$D7D" "$P7D"
if run_for fb7d record-gate --name review --report "$P7D" 2>"$TMP_ROOT/fb7d.err"; then
  echo "FAIL: tampered packet file accepted" >&2
  exit 1
fi
/usr/bin/grep -q "packet file changed" "$TMP_ROOT/fb7d.err" || { echo "FAIL: fb7d message wrong" >&2; exit 1; }
/usr/bin/git -C "$TMP_ROOT" checkout -q -- . 2>/dev/null || true

# ---- 用例 15：packet 路径预建 symlink → safe_atomic_write_bytes 拒绝（不写 symlink）----
craft_state sl "$ENV_FALLBACK"
run_for sl read-rules >/dev/null
printf 'precious content\n' > "$TMP_ROOT/symlink-target.txt"
/bin/ln -s "$TMP_ROOT/symlink-target.txt" "$TMP_ROOT/.dev-flow/sessions/.sl.review-packet.txt"
if run_runner sl >/dev/null 2>&1; then
  echo "FAIL: runner should reject symlinked packet path (safe_atomic_write_bytes)" >&2
  exit 1
fi
[[ "$(cat "$TMP_ROOT/symlink-target.txt")" == "precious content" ]] || { echo "FAIL: symlink target overwritten despite rejection" >&2; exit 1; }
echo "OK: symlinked packet path rejected, symlink target not polluted"
/bin/rm -f "$TMP_ROOT/.dev-flow/sessions/.sl.review-packet.txt" "$TMP_ROOT/symlink-target.txt"

# ---- 用例 16：换行文件名的 untracked 文件安全入包 ----
/usr/bin/git -C "$TMP_ROOT" clean -fdq -- . ':!gstack-skill'
craft_state nl "$ENV_FALLBACK"
run_for nl read-rules >/dev/null
NLFILE="$TMP_ROOT/$(printf 'line1\nline2.txt')"
printf 'NEWLINE_NAME_MARKER\n' > "$NLFILE"
if ! out="$(run_runner nl 2>&1)"; then
  echo "FAIL: runner choked on newline filename" >&2
  exit 1
fi
printf '%s' "$out" | /usr/bin/grep -q "NEWLINE_NAME_MARKER" || { echo "FAIL: newline-filename content missing" >&2; exit 1; }
/bin/rm -f "$NLFILE"

# ---- 用例 17：env 结构不一致（evidence 含 fallback 但 status 异常）→ runner 拒绝 ----
ENV_BAD1='{"status":"not-run","checked_at":null,"checks":{"review_mcp":{"status":"failed","evidence":"fallback=gstack-review"}}}'
ENV_BAD2='{"status":"available","checked_at":"x","checks":{"review_mcp":{"status":"failed","evidence":"fallback=gstack-review"}}}'
craft_state bad1 "$ENV_BAD1"
run_for bad1 read-rules >/dev/null
if run_runner bad1 >/dev/null 2>&1; then
  echo "FAIL: inconsistent env (not-run + fallback evidence) accepted" >&2
  exit 1
fi
craft_state bad2 "$ENV_BAD2"
run_for bad2 read-rules >/dev/null
if run_runner bad2 >/dev/null 2>&1; then
  echo "FAIL: inconsistent env (review_mcp failed + fallback evidence) accepted" >&2
  exit 1
fi

# ---- 用例 18：报告 route 与 runner 签发 route 不一致 → 拒 ----
craft_state fb18 "$ENV_FALLBACK" "$CONF"
run_for fb18 read-rules >/dev/null
run_runner fb18 >/dev/null
read -r T18 D18 P18 <<< "$(read_fb fb18)"
# 从 state 读取 ticket（runner 签发）
read -r TT18 TD18 < <(/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/fb18.json" <<'PY'
import json, sys
from pathlib import Path
rt = (json.loads(Path(sys.argv[1]).read_text()).get("review_ticket") or {})
print(rt.get("token") or "", rt.get("ticket_digest") or "")
PY
)
# 创建 result artifact（route 与 ticket 不同，测试 route mismatch）
fb18_ra="$(inject_result_artifact "fb18" "$TMP_ROOT/.dev-flow/sessions/fb18.json" "$TMP_ROOT" "pass" "test-run-fb18" "route mismatch attempt")"
fb18_ra_path="${fb18_ra% *}"
fb18_ra_digest="${fb18_ra#* }"
/usr/bin/python3 - "$P18" "$T18" "$D18" "$TT18" "$TD18" "$fb18_ra_path" "$fb18_ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
path, token, digest, tt, td, ra_path, ra_digest = sys.argv[1:8]
run_id = "test-run-fb18"
ref = f"test-host-ref-{run_id}"
adigest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
Path(path).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": "fb18", "gate": "review",
    "route": "api-contract-review",  # 签发出 code-quality-review，报告填别的 route
    "review_path": "fallback",
    "fallback_token": token, "packet_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
    "status": "pass", "reviewer_result": "pass",
    "evidence": "route mismatch attempt",
    "selected_adapter": "skill/gstack",
    "config_digest": "sha256:702652b5b4c29de426813882e80065a4dbb175c21fd8210210d0f7d4392d9037",
    "run_id": run_id,
    "adapter_result_ref": ref, "adapter_result_digest": adigest,
    "diff_evidence": "sha256:8483b031c0c19ec0ef92a40c1aa73c6a5c4c0b196ad082271ab165298bac3ec6",
}) + "\n")
PY
if run_for fb18 record-gate --name review --report "$P18" 2>"$TMP_ROOT/fb18.err"; then
  echo "FAIL: mismatched route accepted" >&2
  exit 1
fi
/usr/bin/grep -q "route mismatch" "$TMP_ROOT/fb18.err" || { echo "FAIL: fb18 message wrong" >&2; exit 1; }

# ---- 用例 19：签发后修改 gstack skill → record-gate 拒（审查规范一致性）----
craft_state fb19 "$ENV_FALLBACK" "$CONF"
run_for fb19 read-rules >/dev/null
run_runner fb19 >/dev/null
read -r T19 D19 P19 <<< "$(read_fb fb19)"
printf '\n# mutated after issue\n' >> "$TMP_ROOT/gstack-skill/review/SKILL.md"
write_fb_report fb19 "$T19" "$D19" "$P19"
if run_for fb19 record-gate --name review --report "$P19" 2>"$TMP_ROOT/fb19.err"; then
  echo "FAIL: mutated gstack skill accepted" >&2
  exit 1
fi
/usr/bin/grep -q "gstack skill changed" "$TMP_ROOT/fb19.err" || { echo "FAIL: fb19 message wrong" >&2; exit 1; }
# 恢复 fake skill 原始内容，避免影响后续用例
cat > "$TMP_ROOT/gstack-skill/review/SKILL.md" <<'EOF'
# gstack review workflow (fake for tests)
按清单审查 diff：SQL 安全、信任边界、副作用。输出 findings。
EOF

# ---- 用例 20：报告路径预建 symlink 指向外部文件 → 拒（token/digest 不外流）----
craft_state fb20 "$ENV_FALLBACK" "$CONF"
run_for fb20 read-rules >/dev/null
run_runner fb20 >/dev/null
read -r T20 D20 P20 <<< "$(read_fb fb20)"
write_fb_report fb20 "$T20" "$D20" "$TMP_ROOT/external-report.json"
/bin/rm -f "$P20"
/bin/ln -s "$TMP_ROOT/external-report.json" "$P20"
if run_for fb20 record-gate --name review --report "$P20" 2>"$TMP_ROOT/fb20.err"; then
  echo "FAIL: symlinked fallback report accepted" >&2
  exit 1
fi
/usr/bin/grep -q "through a symlink" "$TMP_ROOT/fb20.err" || { echo "FAIL: fb20 message wrong" >&2; exit 1; }
/bin/rm -f "$P20" "$TMP_ROOT/external-report.json"

# ---- 用例 21：packet 路径预建 symlink → runner 写入拒绝（trusted-boundary 安全辅助）----
# 场景：PACKET_FILE 被预建为 symlink 指向外部文件。
# safe_atomic_write_bytes 应拒绝写入 symlink 目标。
craft_state fb21 "$ENV_FALLBACK" "$CONF"
run_for fb21 read-rules >/dev/null

# 预建 packet 路径为 symlink
PACKET21="$TMP_ROOT/.dev-flow/sessions/.fb21.review-packet.txt"
echo "evil" > "$TMP_ROOT/external-packet.txt"
/bin/rm -f "$PACKET21"
/bin/ln -s "$TMP_ROOT/external-packet.txt" "$PACKET21"

if run_runner fb21 >/dev/null 2>&1; then
  # 检查 packet 是否被写入 symlink 目标（不应如此）
  if /usr/bin/grep -q "evil" "$TMP_ROOT/external-packet.txt" 2>/dev/null; then
    echo "FAIL: runner wrote packet through symlink to external file" >&2
    exit 1
  fi
  echo "FAIL: runner should reject symlinked packet path" >&2
  exit 1
fi
echo "OK: runner rejects symlinked packet path (trusted-boundary safe write)"

# 清理 symlink，重跑 runner 验证正常路径仍工作
/bin/rm -f "$PACKET21"
/bin/rm -f "$TMP_ROOT/external-packet.txt"
run_runner fb21 >/dev/null
read -r T21 D21 P21 <<< "$(read_fb fb21)"
if [[ -z "$T21" ]]; then
  echo "FAIL: after removing symlink, runner should write state normally" >&2
  exit 1
fi
echo "OK: after removing symlink, runner writes packet normally"

# ---- 用例 22: sessions -> 外部 symlink → runner 在创建任何外部文件前拒绝 ----
# 场景：.dev-flow/sessions 是 symlink 指向外部目录。
# runner 必须在安全前置检查阶段 fail closed，不创建任何临时文件到外部目录。
craft_state fb22 "$ENV_FALLBACK" "$CONF"
run_for fb22 read-rules >/dev/null

# 创建外部目录，复制 state 文件
EXTERNAL_SESSIONS22="$(/usr/bin/mktemp -d)"
/bin/cp "$TMP_ROOT/.dev-flow/sessions/fb22.json" "$EXTERNAL_SESSIONS22/fb22.json"
# 删除 sessions 目录，创建 symlink 指向外部目录
/bin/rm -rf "$TMP_ROOT/.dev-flow/sessions"
/bin/ln -s "$EXTERNAL_SESSIONS22" "$TMP_ROOT/.dev-flow/sessions"

# 运行 runner — 应该拒绝
if run_runner fb22 >/dev/null 2>&1; then
  echo "FAIL: runner should reject sessions symlink to external dir" >&2
  exit 1
fi
echo "OK: runner rejects sessions symlink to external dir"

# 验证外部目录无临时文件（只有 state 文件 fb22.json）
EXTERNAL_FILES22="$(/bin/ls -A "$EXTERNAL_SESSIONS22" 2>/dev/null)"
for f in $EXTERNAL_FILES22; do
  case "$f" in
    fb22.json) ;;
    *)
      echo "FAIL: external directory polluted with temp file: $f" >&2
      exit 1
      ;;
  esac
done
echo "OK: external directory stays clean (no temp files created through symlink)"

# 清理：恢复 sessions 目录
/bin/rm -f "$TMP_ROOT/.dev-flow/sessions"
/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"
/bin/cp "$EXTERNAL_SESSIONS22/fb22.json" "$TMP_ROOT/.dev-flow/sessions/fb22.json"
/bin/rm -rf "$EXTERNAL_SESSIONS22"

# ---- 用例 23: sessions -> trusted root 内部目录 symlink → runner 拒绝 ----
# 场景：.dev-flow/sessions 是 symlink 指向 .dev-flow/real-sessions（在 trusted root 内部）。
# 即使指向内部，symlink 可被交换，runner 必须 fail closed。
craft_state fb23 "$ENV_FALLBACK" "$CONF"
run_for fb23 read-rules >/dev/null

# 创建内部 real-sessions 目录，复制 state 文件
/bin/mkdir -p "$TMP_ROOT/.dev-flow/real-sessions"
/bin/cp "$TMP_ROOT/.dev-flow/sessions/fb23.json" "$TMP_ROOT/.dev-flow/real-sessions/fb23.json"
# 删除 sessions 目录，创建 symlink 指向内部 real-sessions
/bin/rm -rf "$TMP_ROOT/.dev-flow/sessions"
/bin/ln -s "$TMP_ROOT/.dev-flow/real-sessions" "$TMP_ROOT/.dev-flow/sessions"

# 运行 runner — 应该拒绝
if run_runner fb23 >/dev/null 2>&1; then
  echo "FAIL: runner should reject internal sessions symlink" >&2
  exit 1
fi
echo "OK: runner rejects internal sessions symlink (-> trusted root internal dir)"

# 验证 real-sessions 无临时文件
REAL_FILES23="$(/bin/ls -A "$TMP_ROOT/.dev-flow/real-sessions" 2>/dev/null)"
for f in $REAL_FILES23; do
  case "$f" in
    fb23.json) ;;
    *)
      echo "FAIL: internal real-sessions polluted with temp file: $f" >&2
      exit 1
      ;;
  esac
done
echo "OK: internal real-sessions stays clean (no temp files created through symlink)"

# 清理
/bin/rm -f "$TMP_ROOT/.dev-flow/sessions"
/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"
/bin/cp "$TMP_ROOT/.dev-flow/real-sessions/fb23.json" "$TMP_ROOT/.dev-flow/sessions/fb23.json"
/bin/rm -rf "$TMP_ROOT/.dev-flow/real-sessions"

echo "PASS: fallback runner issues token-bound packets, includes worktree diff, and record-gate enforces the three-piece binding"
