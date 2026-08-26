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
dev_flow_rules_init

# 异常退出时统一清理临时文件（UNTRACKED_Z / PACKET_TMP 在成功路径上已被 rm/mv，此处兜底）
UNTRACKED_Z=""
PACKET_TMP=""
cleanup_tmp() {
  [[ -n "$UNTRACKED_Z" ]] && /bin/rm -f "$UNTRACKED_Z" 2>/dev/null
  [[ -n "$PACKET_TMP" ]] && /bin/rm -f "$PACKET_TMP" 2>/dev/null
  return 0
}
trap cleanup_tmp EXIT

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

# route 白名单：仅小写字母/数字/连字符，防路径穿越（../）与任意文件注入
case "$ROUTE" in
  ""|*[!a-z0-9-]*)
    echo "Invalid route name: $ROUTE (allowed: [a-z0-9-]+)" >&2
    exit 2
    ;;
esac
ROUTES_DIR="$SOURCE_ROOT/skills/code-review-workflow/routes"
ROUTE_FILE="$ROUTES_DIR/$ROUTE.md"
if [[ ! -f "$ROUTE_FILE" ]]; then
  echo "Unknown review route: $ROUTE (no routes/$ROUTE.md in code-review-workflow)" >&2
  exit 2
fi

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

# 2. 解析 gstack review SKILL.md（候选路径与 review-health-probe.sh 一致）
skills_root=""
if [[ -n "${CURSOR_SKILLS_ROOT:-}" ]]; then
  skills_root="$CURSOR_SKILLS_ROOT"
elif [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
  skills_root="$HOME/.cursor/skills"
elif [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
  skills_root="$CODEX_SKILLS_ROOT"
elif [[ -n "${CODEX_HOME:-}" ]]; then
  skills_root="$CODEX_HOME/skills"
else
  skills_root="$HOME/.codex/skills"
fi

GSTACK_SKILL=""
for candidate in \
  "${GSTACK_REVIEW_SKILL_ROOT:-}" \
  "$skills_root/gstack/review" \
  "$HOME/.claude/skills/gstack/review" \
  "$HOME/.codex/skills/gstack/review" \
  "$HOME/.cursor/skills/gstack/review"; do
  if [[ -n "$candidate" && -f "$candidate/SKILL.md" ]]; then
    GSTACK_SKILL="$candidate/SKILL.md"
    break
  fi
done
if [[ -z "$GSTACK_SKILL" ]]; then
  echo "gstack-review skill not found in any candidate path; install gstack or set GSTACK_REVIEW_SKILL_ROOT" >&2
  exit 1
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

# 4. 机械准备审查包：merge-base → 工作区（含 staged/unstaged）+ untracked 文件。
# 先流式计行，超限不装载完整 diff（避免大 diff 进内存）。
MAX_DIFF_LINES=4000
MAX_UNTRACKED_LINES=2000
DIFF_STAT="$(/usr/bin/git -C "$ROOT" diff --stat "$MERGE_BASE")"
DIFF_NAMES="$(/usr/bin/git -C "$ROOT" diff --name-status "$MERGE_BASE")"
# untracked 列表排除 .dev-flow/：dev-flow 自身 state 文件不属于审查对象，
# 且未 gitignore .dev-flow 的项目里 state 文件会挤占 untracked 内容预算。
# 用 -z 输出避免换行文件名被拆分（先存临时清单，read -d '' 精确逐条读取）。
UNTRACKED_Z="$(/usr/bin/mktemp)"
/usr/bin/git -C "$ROOT" ls-files --others --exclude-standard -z -- . ':(exclude).dev-flow' > "$UNTRACKED_Z"
DIFF_LINES="$(/usr/bin/git -C "$ROOT" diff "$MERGE_BASE" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"

PACKET_FILE="$STATE_DIR/.${SESSION_ID}.review-packet.txt"
REPORT_PATH="$STATE_DIR/.${SESSION_ID}.review-report.json"
# packet 写入：mktemp 安全创建（O_EXCL/0600）构建内容后 mv -f 原子替换——
# rename 只替换目录项，即使 PACKET_FILE 被预先做成 symlink 也不会写到 symlink 目标，
# 结构性消除 check-then-write 的 TOCTOU 窗口
PACKET_TMP="$(/usr/bin/mktemp "$STATE_DIR/.packet-XXXXXX")"
{
  echo "=== git diff --stat (merge-base -> worktree) ==="
  printf '%s\n\n' "$DIFF_STAT"
  echo "=== git diff --name-status ==="
  printf '%s\n\n' "$DIFF_NAMES"
  if [[ "$DIFF_LINES" -le "$MAX_DIFF_LINES" ]]; then
    echo "=== git diff (full, $DIFF_LINES lines; merge-base -> worktree incl. staged+unstaged) ==="
    /usr/bin/git -C "$ROOT" diff "$MERGE_BASE"
  else
    echo "=== git diff TOO LARGE ($DIFF_LINES lines > $MAX_DIFF_LINES) ==="
    echo "完整 diff 超过上限未装载。按上面 name-status 清单分文件自行 git diff 审查，"
    echo "或设置 DEV_FLOW_REVIEW_BASE 缩小范围后重跑本脚本。"
  fi
  echo ""
  echo "=== untracked files ==="
  if [[ ! -s "$UNTRACKED_Z" ]]; then
    echo "(none)"
  else
    untracked_budget="$MAX_UNTRACKED_LINES"
    # read -d '' 按 NUL 精确读文件名（含换行/空格的名字安全）；重定向输入不占子 shell，预算正确递减
    while IFS= read -r -d '' uf && [[ "$untracked_budget" -gt 0 ]]; do
      [[ -z "$uf" ]] && continue
      echo "--- untracked: $uf ---"
      /usr/bin/head -n 500 "$ROOT/$uf" 2>/dev/null || echo "(unreadable/binary)"
      echo ""
      untracked_budget=$((untracked_budget - 500))
    done < "$UNTRACKED_Z"
  fi
} > "$PACKET_TMP"
/bin/rm -f "$UNTRACKED_Z"
/bin/mv -f "$PACKET_TMP" "$PACKET_FILE"
/bin/chmod 600 "$PACKET_FILE"

PACKET_DIGEST="$(/usr/bin/shasum -a 256 "$PACKET_FILE" | /usr/bin/cut -d' ' -f1)"

# 5. 签发一次性 token 并记入 state（record-gate 将强制校验 token/digest/报告路径）
read -r FALLBACK_TOKEN ISSUED_AT <<< "$(/usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$PACKET_DIGEST" "$REPORT_PATH" "$ROUTE" "$PACKET_FILE" "$GSTACK_SKILL" "$ROUTE_FILE" <<'PY'
import json
import os
import secrets
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id, packet_digest, report_path, route, packet_path, gstack_skill, route_file = sys.argv[2:9]

def sha256_file(p):
    import hashlib
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

state = json.loads(state_path.read_text())
issued_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
token = secrets.token_hex(16)
state["review_fallback"] = {
    "token": token,
    "packet_digest": packet_digest,
    "packet_path": packet_path,
    "report_path": report_path,
    "route": route,
    # 注入文档绑定：gstack SKILL.md 与 route 契约签发时 digest，
    # record-gate 重算比对，签发后被修改则拒收（审查规范一致性）
    "gstack_skill_path": gstack_skill,
    "gstack_skill_digest": sha256_file(gstack_skill),
    "route_path": route_file,
    "route_digest": sha256_file(route_file),
    "issued_at": issued_at,
}
state["session_id"] = session_id
atomic_write(state_path, state)
print(token, issued_at)
PY
)"

# 6. 注入：指令横幅（含 token/digest/报告路径）+ gstack SKILL.md + route 契约 + 审查包 + 报告模板
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
     "status": "pass | revise | blocked",
     "reviewer_result": "<与 status 相同>",
     "evidence": "<bounded 审查摘要，含发现/严重度/位置>"
   }
5. 写完后收口：bash scripts/dev-flow-session.sh record-gate --name review --report ${REPORT_PATH}
6. status=pass 仅当 route 的全部 pass conditions 满足；未审查/timeout 不得报 pass。
7. 代码每次变更后必须重跑本脚本（packet_digest 会变，旧报告作废）。
8. fallback_token 一次性：record-gate 接受 pass 后即销毁。

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
