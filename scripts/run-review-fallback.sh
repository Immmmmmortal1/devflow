#!/usr/bin/env bash
# gstack-review fallback 机械执行入口（review_mcp 不可用时）：
# 把"去读 gstack SKILL.md 并自己组织 diff"这条纯文档指令变成一条命令——
# 校验会话处于 fallback 模式 → 机械准备 bounded diff 审查包（含工作区未提交改动）
# → 签发一次性 fallback_token + packet_digest 记入 session state
# → 把审查指令横幅 + gstack review SKILL.md 全文 + route 契约 + diff 包 + 报告模板
# 全部注入 stdout（tool result 注入上下文，AI 不需要自愿读任何文件）。
# record-gate 在 fallback 会话强制校验 token/digest/报告路径，不跑 runner 手写报告会被拒。
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
# shellcheck source=lib/dev-flow-rules.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-rules.sh"
# shellcheck source=lib/route-whitelist.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/route-whitelist.sh"
dev_flow_rules_init

ROUTE="code-quality-review"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --route)
      ROUTE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/run-review-fallback.sh [--route code-quality-review]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# route 白名单校验（从实际 routes 目录扫描）
if ! validate_route_name "$ROUTE" "$SOURCE_ROOT"; then
  exit 2
fi
ROUTES_DIR="$SOURCE_ROOT/skills/code-review-workflow/routes"
ROUTE_FILE="$ROUTES_DIR/$ROUTE.md"

# 1. 会话校验：active + 环境门 review_mcp 证据按 ; 分段精确匹配 fallback=gstack-review
/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
checks = (state.get("environment_health") or {}).get("checks") or {}
review_mcp = checks.get("review_mcp") or {}
env = state.get("environment_health") or {}
evidence = str(review_mcp.get("evidence") or "")
if not evidence:
    raise SystemExit("Environment health not run yet. Run environment-health-check.sh first.")
# 结构一致性：不仅 evidence 分段匹配，环境门与 review_mcp 检查本身都必须 available，
# 防止 status=not-run/failed 但 evidence 含目标串的不一致状态进入 fallback
if env.get("status") != "available":
    raise SystemExit("Environment health is not available in this session.")
if review_mcp.get("status") != "available":
    raise SystemExit("review_mcp check is not available in this session.")
segments = [seg.strip() for seg in evidence.split(";")]
if "fallback=gstack-review" not in segments:
    raise SystemExit(
        "Session is NOT in gstack-review fallback mode (review_mcp evidence: "
        + evidence
        + "). Use orchestrator_mcp -> code_review instead; this runner is fallback-only."
    )
PY

# 1.5 双层规则机制：runner 会写 state（签发 token），与门禁 action 同样强制项目规则 fresh
dev_flow_rules_verify_project_fresh "$STATE_FILE"

# 2. 解析 gstack review SKILL.md 路径
# 绑定到 state.review_selection.skill_path（与 review-health-probe.sh 探活时一致）。
# runner 不得自行找出不同路径——path 从 environment selection 绑定到 state，
# 路径不存在/变化 fail closed。
# shellcheck source=lib/reviewer-readiness.sh
source "$(dev_flow_script_path lib/reviewer-readiness.sh)"

GSTACK_SKILL_DIR=""
GSTACK_SKILL=""
# 优先从 state.review_selection.skill_path 读取（绑定路径）
BOUND_SKILL_PATH="$(/usr/bin/python3 -c '
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
selection = state.get("review_selection") or {}
print(selection.get("skill_path") or "")
' "$STATE_FILE" 2>/dev/null || true)"

if [[ -n "$BOUND_SKILL_PATH" ]]; then
    # 绑定路径存在性校验
    if [[ ! -f "$BOUND_SKILL_PATH" ]]; then
        echo "FAIL: bound gstack skill_path does not exist: $BOUND_SKILL_PATH" >&2
        echo "The skill path was bound at environment-health-check time but is now missing." >&2
        echo "Re-run environment-health-check.sh to rebind, or check skill installation." >&2
        exit 1
    fi
    GSTACK_SKILL="$BOUND_SKILL_PATH"
    GSTACK_SKILL_DIR="$(dirname "$GSTACK_SKILL")"
elif ! GSTACK_SKILL_DIR="$(resolve_gstack_skill_path 2>/dev/null)"; then
    echo "gstack-review skill not found: no skill_path in review_selection and no candidate path found" >&2
    echo "Run environment-health-check.sh to bind skill_path, or set GSTACK_REVIEW_SKILL_ROOT" >&2
    exit 1
else
    GSTACK_SKILL="$GSTACK_SKILL_DIR/SKILL.md"
fi

# 3. git 与 base 校验
if ! /usr/bin/git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "project root is not a git repository: $ROOT" >&2
  exit 1
fi

BASE=""
if [[ -n "${DEV_FLOW_REVIEW_BASE:-}" ]]; then
  BASE="$DEV_FLOW_REVIEW_BASE"
else
  for candidate_base in origin/main origin/master main master; do
    if /usr/bin/git -C "$ROOT" rev-parse --verify --quiet "$candidate_base" >/dev/null 2>&1; then
      BASE="$candidate_base"
      break
    fi
  done
fi
if [[ -z "$BASE" ]]; then
  echo "cannot resolve a base ref; set DEV_FLOW_REVIEW_BASE (e.g. origin/main)" >&2
  exit 1
fi
# 参数注入防护：拒 - 开头（git 选项注入）+ 拒绝 git ref 禁用字符集 + 必须指向既有 commit。
# （不用 check-ref-format：它要求 ref 至少含一个 /，会误杀 main 这类单级分支名）
case "$BASE" in
  -*|*..*|*@\{*|*[[:space:]]*|*~*|*^*|*:*|*\?*|*\**|*\[*|\\*)
    echo "invalid git ref for review base: $BASE" >&2
    exit 2
    ;;
esac
if ! /usr/bin/git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "review base does not resolve to a commit: $BASE" >&2
  exit 1
fi
MERGE_BASE="$(/usr/bin/git -C "$ROOT" merge-base "$BASE" HEAD)"

# 4. 安全前置检查：在任何对 STATE_DIR 创建/写临时文件前，
# 验证 trusted_root=$ROOT/.dev-flow 到 STATE_DIR 原始链无 symlink 且 boundary 内。
# sessions symlink 会越界——必须在开始构建前 fail closed，避免浪费/泄露。
PROJECT_ROOT="${DEV_FLOW_PROJECT_ROOT:-$ROOT}"
DEV_FLOW_SOURCE_ROOT="$SOURCE_ROOT" /usr/bin/python3 - "$PROJECT_ROOT/.dev-flow" "$STATE_DIR" <<'PYCHECK'
import os, sys
from pathlib import Path
sys.path.insert(0, os.path.join(os.environ["DEV_FLOW_SOURCE_ROOT"], "scripts", "lib"))
from atomic_json_write import _validate_trusted_root, _check_original_path, _check_resolved_boundary
trusted_root = Path(os.path.normpath(sys.argv[1]))
state_dir = Path(os.path.normpath(sys.argv[2]))
_validate_trusted_root(trusted_root)
_check_original_path(trusted_root, state_dir)
_check_resolved_boundary(trusted_root, state_dir)
PYCHECK

# 5. 机械准备审查包：merge-base → 工作区（含 staged/unstaged）+ untracked 文件。
# 不在 STATE_DIR 创建构建临时文件——packet 内容在 Python 内存中构建，
# 最终仅通过 safe_atomic_write_bytes 写入 trusted root。
# untracked 列表也在 Python 中处理（不落盘 STATE_DIR）。
PACKET_FILE="$STATE_DIR/.${SESSION_ID}.review-packet.txt"
REPORT_PATH="$STATE_DIR/.${SESSION_ID}.review-report.json"

PACKET_DIGEST="$(DEV_FLOW_SOURCE_ROOT="$SOURCE_ROOT" /usr/bin/python3 - "$ROOT" "$MERGE_BASE" "$SESSION_ID" "$STATE_DIR" "$PROJECT_ROOT/.dev-flow" <<'PKT'
import hashlib
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["DEV_FLOW_SOURCE_ROOT"], "scripts", "lib"))
from atomic_json_write import safe_atomic_write_bytes

root, merge_base, session_id, state_dir, trusted_root = sys.argv[1:6]

MAX_DIFF_LINES = 4000
MAX_UNTRACKED_LINES = 2000
packet_file = os.path.join(state_dir, f".{session_id}.review-packet.txt")

# git diff stat
diff_stat = subprocess.run(
    ["git", "-C", root, "diff", "--stat", merge_base],
    capture_output=True, text=True,
).stdout

# git diff name-status
diff_names = subprocess.run(
    ["git", "-C", root, "diff", "--name-status", merge_base],
    capture_output=True, text=True,
).stdout

# git diff full
diff_full = subprocess.run(
    ["git", "-C", root, "diff", merge_base],
    capture_output=True, text=True,
).stdout
diff_lines = diff_full.count("\n")

# untracked files (NUL-separated, binary-safe)
untracked_raw = subprocess.run(
    ["git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z",
     "--", ":(exclude).dev-flow"],
    capture_output=True,
).stdout
untracked_paths = [p for p in untracked_raw.split(b"\0") if p]

# build packet content in memory
parts = []
parts.append("=== git diff --stat (merge-base -> worktree) ===\n")
parts.append(diff_stat + "\n\n")
parts.append("=== git diff --name-status ===\n")
parts.append(diff_names + "\n\n")
if diff_lines <= MAX_DIFF_LINES:
    parts.append(f"=== git diff (full, {diff_lines} lines; merge-base -> worktree incl. staged+unstaged) ===\n")
    parts.append(diff_full)
else:
    parts.append(f"=== git diff TOO LARGE ({diff_lines} lines > {MAX_DIFF_LINES}) ===\n")
    parts.append("完整 diff 超过上限未装载。按上面 name-status 清单分文件自行 git diff 审查，\n")
    parts.append("或设置 DEV_FLOW_REVIEW_BASE 缩小范围后重跑本脚本。\n")
parts.append("\n")
parts.append("=== untracked files ===\n")
if not untracked_paths:
    parts.append("(none)\n")
else:
    untracked_budget = MAX_UNTRACKED_LINES
    for raw_path in sorted(untracked_paths):
        if untracked_budget <= 0:
            break
        uf = raw_path.decode("utf-8", "surrogateescape")
        parts.append(f"--- untracked: {uf} ---\n")
        abs_path = os.path.join(root, uf)
        try:
            with open(abs_path, "r", errors="replace") as f:
                lines = []
                for i, line in enumerate(f):
                    if i >= 500:
                        break
                    lines.append(line)
                if lines:
                    parts.append("".join(lines))
                    if not lines[-1].endswith("\n"):
                        parts.append("\n")
        except (OSError, IOError):
            parts.append("(unreadable/binary)\n")
        parts.append("\n")
        untracked_budget -= 500

content = "".join(parts).encode("utf-8", "surrogateescape")

# write via safe_atomic_write_bytes (trusted-boundary check)
safe_atomic_write_bytes(trusted_root, packet_file, content)

# compute packet digest
packet_digest = hashlib.sha256(content).hexdigest()
print(packet_digest)
PKT
)"

# 7. 计算统一 worktree digest（与 issue-review-ticket.sh 共享同一实现）
WT_INFO="$(/usr/bin/python3 "$SOURCE_ROOT/scripts/lib/worktree_digest.py" "$PROJECT_ROOT")"

# 8. 签发统一 review dispatch ticket + 一次性 fallback token 并记入 state
# 统一 ticket 由 issue-review-ticket.sh 签发（agent/mcp/fallback 共用）；
# fallback 额外签发 packet 绑定（packet_digest/report_path/gstack_skill/route_contract）。
# 两套 token 机制并存：ticket_token 是统一机械防伪，fallback_token 是 fallback 专属绑定。
# 拒绝覆盖未消费/未作废的 ticket——先运行 cancel-review-ticket.sh。
read -r FALLBACK_TOKEN ISSUED_AT SELECTION_DIGEST TICKET_TOKEN TICKET_DIGEST <<< "$(/usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$PACKET_DIGEST" "$REPORT_PATH" "$ROUTE" "$PACKET_FILE" "$GSTACK_SKILL" "$ROUTE_FILE" "$WT_INFO" "$PROJECT_ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import secrets
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
session_id, packet_digest, report_path, route, packet_path, gstack_skill, route_file = sys.argv[2:9]
wt_info = json.loads(sys.argv[9])
trusted_root = sys.argv[10]
source_root = sys.argv[11]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

def sha256_file(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def sha256_str(s):
    return "sha256:" + hashlib.sha256(s.encode("utf-8")).hexdigest()

state = json.loads(state_path.read_text())
issued_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ── 拒绝覆盖未消费/未作废的 ticket ──
existing_ticket = state.get("review_ticket")
if existing_ticket:
    if not existing_ticket.get("consumed") and not existing_ticket.get("cancelled"):
        raise SystemExit(
            "an unconsumed review ticket already exists in this session. "
            "Run scripts/cancel-review-ticket.sh to cancel it before issuing a new one."
        )

# ── 统一 ticket ──
selection = state.get("review_selection") or {}
if not selection.get("selected_adapter"):
    raise SystemExit("review_selection missing; run environment-health-check.sh first.")
selected_adapter = selection["selected_adapter"]
config_digest = selection.get("config_digest", "")

ticket_token = secrets.token_hex(16)
ticket_path = state_path.parent / f".{session_id}.review-ticket.json"
ticket = {
    "session_id": session_id,
    "ticket_token": ticket_token,
    "selected_adapter": selected_adapter,
    "config_digest": config_digest,
    "route": route,
    "base_ref": wt_info["base_ref"],
    "merge_base": wt_info["merge_base"],
    "worktree_digest": wt_info["worktree_digest"],
    "tracked_digest": wt_info["tracked_digest"],
    "untracked_digest": wt_info["untracked_digest"],
    "issued_at": issued_at,
    "consumed": False,
}
ticket_json = json.dumps(ticket, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
ticket_digest = sha256_str(ticket_json)
ticket["ticket_digest"] = ticket_digest
safe_atomic_write_json(trusted_root, ticket_path, ticket)

# ── fallback 专属绑定 ──
fallback_token = secrets.token_hex(16)
state["review_fallback"] = {
    "token": fallback_token,
    "packet_digest": packet_digest,
    "packet_path": packet_path,
    "report_path": report_path,
    "route": route,
    "gstack_skill_path": gstack_skill,
    "gstack_skill_digest": sha256_file(gstack_skill),
    "route_path": route_file,
    "route_digest": sha256_file(route_file),
    "issued_at": issued_at,
}
# ── 统一 ticket 写入 state ──
state["review_ticket"] = {
    "token": ticket_token,
    "ticket_digest": ticket_digest,
    "ticket_path": str(ticket_path),
    "selected_adapter": selected_adapter,
    "config_digest": config_digest,
    "route": route,
    "base_ref": wt_info["base_ref"],
    "merge_base": wt_info["merge_base"],
    "worktree_digest": wt_info["worktree_digest"],
    "tracked_digest": wt_info["tracked_digest"],
    "untracked_digest": wt_info["untracked_digest"],
    "issued_at": issued_at,
    "consumed": False,
}
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(fallback_token, issued_at, config_digest, ticket_token, ticket_digest)
PY
)"

# 9. 注入：指令横幅（含 token/digest/报告路径）+ gstack SKILL.md + route 契约 + 审查包 + 报告模板
cat <<EOF
========================================================================
REVIEW FALLBACK MODE (review_mcp unavailable -> gstack-review)
========================================================================
你现在处于 gstack-review fallback 模式。硬性要求：

1. 禁止开子 Agent / 禁止使用宿主自带的审查 agent —— fallback 审查者就是你本人。
2. 按下面注入的 gstack review SKILL.md 流程 + dev-flow route 契约，亲自完成审查。
3. 审查输入：本输出末尾的 bounded 审查包（全文同时落盘：${PACKET_FILE}）。
   范围 = merge-base(${MERGE_BASE}) → 工作区（含 staged/unstaged）+ untracked 文件。
4. 审查结论写入指定报告路径（必须原路径，record-gate 会校验）：
   $REPORT_PATH
    必需字段（缺一拒收）：
    {
      "producer": "code-review-workflow",
      "schema_version": 1,
      "session_id": "${SESSION_ID}",
      "gate": "review",
      "route": "${ROUTE}",
      "review_path": "fallback",
      "fallback_token": "${FALLBACK_TOKEN}",
      "packet_digest": "${PACKET_DIGEST}",
      "ticket_token": "${TICKET_TOKEN}",
      "ticket_digest": "${TICKET_DIGEST}",
      "selected_adapter": "skill/gstack",
      "config_digest": "${SELECTION_DIGEST}",
      "status": "pass | revise | blocked",
      "reviewer_result": "<与 status 相同>",
      "evidence": "<bounded 审查摘要，含发现/严重度/位置>"
    }
5. 写完后收口：bash scripts/dev-flow-session.sh record-gate --name review --report ${REPORT_PATH}
6. status=pass 仅当 route 的全部 pass conditions 满足；未审查/timeout 不得报 pass。
7. 代码每次变更后必须重跑本脚本（packet_digest 会变，旧报告作废）。
8. fallback_token 一次性：record-gate 接受 pass 后即销毁。ticket_token 同理（统一机械防伪）。
9. 报告必须携带 selected_adapter=skill/gstack 和 config_digest（从会话 review_selection 获取）；
    record-gate 会校验 selection binding（no-result-washing：dispatch 后不得切换 adapter）。
10. 报告必须携带 ticket_token 和 ticket_digest（统一 review dispatch ticket）；
    record-gate 会校验 ticket 归属、adapter/config/route/diff digest、未消费状态。

========================================================================
GSTACK REVIEW SKILL（全文注入， source: ${GSTACK_SKILL}）
========================================================================
EOF
cat "$GSTACK_SKILL"
cat <<EOF

========================================================================
DEV-FLOW REVIEW ROUTE（契约注入， source: ${ROUTE_FILE}）
========================================================================
EOF
cat "$ROUTE_FILE"
cat <<EOF

========================================================================
REVIEW PACKET（base: ${BASE}, merge-base: ${MERGE_BASE} -> worktree）
========================================================================
EOF
cat "$PACKET_FILE"
# 双层规则机制：state 写操作后回带项目规则（与其他门禁 action 一致）
dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
