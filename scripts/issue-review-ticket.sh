#!/usr/bin/env bash
# 统一 review dispatch ticket 签发入口。
#
# 在 ANY review dispatch（agent/mcp/fallback）前由受控脚本签发随机 token 和
# ticket artifact。agent/mcp/fallback 都必须消费 ticket 并在报告带
# ticket_token/ticket_digest、selected_adapter/config_digest、result_artifact。
# record-gate 验证 ticket 归属当前 session、adapter/config/route/worktree_digest、
# token/digest、未消费状态；成功后原子标记 consumed，不能复用。
#
# 诚实声明：本地完整性门用于防误操作/漂移/重放，不是对拥有本机写权限攻击者的密码学证明。
# record-gate 只接受受控 result artifact，降低误填风险。
#
# Usage: bash scripts/issue-review-ticket.sh [--route <route>] [--session-id <id>]
#
# 输出 ticket JSON 到 stdout，并写入 state.review_ticket + artifact 文件。
# 如果存在未消费/未作废的 ticket，拒绝覆盖——先运行 cancel-review-ticket.sh。
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
# shellcheck source=lib/dev-flow-rules.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-rules.sh"
# shellcheck source=lib/route-whitelist.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/route-whitelist.sh"
dev_flow_rules_init

ROUTE="code-quality-review"
SESSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --route)
      ROUTE="${2:-}"
      shift 2
      ;;
    --session-id)
      SESSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/issue-review-ticket.sh [--route code-quality-review] [--session-id <id>]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# route 白名单校验
if ! validate_route_name "$ROUTE" "$SOURCE_ROOT"; then
  exit 2
fi

# session id 解析：--session-id 覆盖 > resolve_dev_flow_session_id
if [[ -n "$SESSION_OVERRIDE" ]]; then
  if [[ ! "$SESSION_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid session id: $SESSION_OVERRIDE" >&2
    exit 2
  fi
  SESSION_ID="$SESSION_OVERRIDE"
else
  SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
fi
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

# 双层规则机制：ticket 签发会写 state，与门禁 action 同样强制项目规则 fresh
dev_flow_rules_verify_project_fresh "$STATE_FILE"

# 计算统一 worktree digest（merge-base→HEAD tracked diff + untracked files）
PROJECT_ROOT="${DEV_FLOW_PROJECT_ROOT:-$(dirname "$(dirname "$STATE_DIR")")}"
WT_INFO="$(/usr/bin/python3 "$SOURCE_ROOT/scripts/lib/worktree_digest.py" "$PROJECT_ROOT")"

# 签发 ticket
TICKET_FILE="$STATE_DIR/.${SESSION_ID}.review-ticket.json"

/usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$ROUTE" "$TICKET_FILE" "$WT_INFO" "$PROJECT_ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
route = sys.argv[3]
ticket_path = Path(sys.argv[4])
wt_info = json.loads(sys.argv[5])
trusted_root = sys.argv[6]
source_root = sys.argv[7]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

state = json.loads(state_path.read_text())

# ── 拒绝覆盖未消费/未作废的 ticket ──
existing = state.get("review_ticket")
if existing:
    if not existing.get("consumed") and not existing.get("cancelled"):
        raise SystemExit(
            "an unconsumed review ticket already exists in this session. "
            "Run scripts/cancel-review-ticket.sh to cancel it before issuing a new one."
        )

# 必须有 review_selection（environment-health-check 产出）
selection = state.get("review_selection") or {}
if not selection.get("selected_adapter"):
    raise SystemExit(
        "review ticket requires review_selection. "
        "Run scripts/environment-health-check.sh run before issuing a review ticket."
    )
if not selection.get("config_digest"):
    raise SystemExit("review_selection has no config_digest. Re-run environment-health-check.sh.")

selected_adapter = selection["selected_adapter"]
config_digest = selection["config_digest"]

# 生成随机 token（32 char hex = 128 bit entropy）
token = secrets.token_hex(16)
issued_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# 构造 ticket artifact
ticket = {
    "session_id": session_id,
    "ticket_token": token,
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

# 计算 ticket_digest（ticket artifact 自身的 sha256，用于防篡改）
ticket_json = json.dumps(ticket, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
ticket_digest = "sha256:" + hashlib.sha256(ticket_json.encode("utf-8")).hexdigest()
ticket["ticket_digest"] = ticket_digest

# 原子写 ticket artifact（0600, 拒 symlink）
safe_atomic_write_json(trusted_root, ticket_path, ticket)

# 写 state.review_ticket（不覆盖已锁定的 selection）
state["review_ticket"] = {
    "token": token,
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

# 输出 ticket info（agent 用来填报告）
print(json.dumps({
    "ticket_token": token,
    "ticket_digest": ticket_digest,
    "ticket_path": str(ticket_path),
    "selected_adapter": selected_adapter,
    "config_digest": config_digest,
    "route": route,
    "base_ref": wt_info["base_ref"],
    "merge_base": wt_info["merge_base"],
    "worktree_digest": wt_info["worktree_digest"],
}, ensure_ascii=False, indent=2))
PY
