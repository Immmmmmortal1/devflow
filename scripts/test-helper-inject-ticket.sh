#!/usr/bin/env bash
# 测试辅助：注入 review_ticket 到 session state 并创建 ticket artifact。
# Source only；提供 inject_review_ticket 函数。
#
# 用法：
#   source "$ROOT/scripts/test-helper-inject-ticket.sh"
#   inject_review_ticket <session_id> <adapter> <config_digest> <route> <state_file> [<tmp_root>]
#   # 输出：ticket_token ticket_digest（空格分隔，供 test 填报告用）
#
# 注意：ticket 的 worktree_digest 从 tmp_root 的 git repo 实时计算。
# record-gate 会重算 worktree_digest 进行对比，因此测试期间不能修改 tracked/untracked 文件。
# 非 git 仓库会直接 fail（与生产行为一致）。

inject_review_ticket() {
  local session_id="$1"
  local adapter="$2"
  local config_digest="$3"
  local route="${4:-code-quality-review}"
  local state_file="$5"
  local tmp_root="${6:-$(dirname "$(dirname "$state_file")")}"

  # 计算真实 worktree digest（与 issue-review-ticket.sh 共享同一实现）
  # 非 git 仓库会 fail（与生产行为一致，不提供 fallback）
  local wt_info
  wt_info="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$tmp_root")"

  /usr/bin/python3 - "$session_id" "$adapter" "$config_digest" "$route" "$state_file" "$tmp_root" "$wt_info" <<'PY'
import hashlib
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

session_id, adapter, config_digest, route, state_file, tmp_root = sys.argv[1:7]
wt_info = json.loads(sys.argv[7])
state_path = Path(state_file)
state = json.loads(state_path.read_text())

token = secrets.token_hex(16)
ticket_path = state_path.parent / f".{session_id}.review-ticket.json"
ticket = {
    "session_id": session_id,
    "ticket_token": token,
    "selected_adapter": adapter,
    "config_digest": config_digest,
    "route": route,
    "base_ref": wt_info["base_ref"],
    "merge_base": wt_info["merge_base"],
    "worktree_digest": wt_info["worktree_digest"],
    "tracked_digest": wt_info["tracked_digest"],
    "untracked_digest": wt_info["untracked_digest"],
    "issued_at": "2026-09-08T00:00:00Z",
    "consumed": False,
}
ticket_json = json.dumps(ticket, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
ticket_digest = "sha256:" + hashlib.sha256(ticket_json.encode("utf-8")).hexdigest()
ticket["ticket_digest"] = ticket_digest

# 写 ticket artifact（0600, 拒 symlink）
if ticket_path.is_symlink():
    raise SystemExit(f"refusing to write ticket through symlink: {ticket_path}")
fd, tmp = tempfile.mkstemp(dir=str(ticket_path.parent), prefix=".ticket-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(ticket, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, str(ticket_path))
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise

# 写 state.review_ticket
state["review_ticket"] = {
    "token": token,
    "ticket_digest": ticket_digest,
    "ticket_path": str(ticket_path),
    "selected_adapter": adapter,
    "config_digest": config_digest,
    "route": route,
    "base_ref": wt_info["base_ref"],
    "merge_base": wt_info["merge_base"],
    "worktree_digest": wt_info["worktree_digest"],
    "tracked_digest": wt_info["tracked_digest"],
    "untracked_digest": wt_info["untracked_digest"],
    "issued_at": "2026-09-08T00:00:00Z",
    "consumed": False,
}
# 原子写 state
if state_path.is_symlink():
    raise SystemExit("refusing to write state through symlink")
fd, tmp = tempfile.mkstemp(dir=str(state_path.parent), prefix=".state-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, str(state_path))
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print(token, ticket_digest)
PY
}

# 测试辅助：注入 result artifact + 生成 gate report（模拟 record-review-result.sh）
# 用法：inject_result_artifact <session_id> <state_file> <tmp_root> <status> <run_id> <evidence>
# 输出：result_artifact_path result_artifact_digest（空格分隔）
inject_result_artifact() {
  local session_id="$1"
  local state_file="$2"
  local tmp_root="$3"
  local status="$4"
  local run_id="$5"
  local evidence="$6"

  /usr/bin/python3 - "$session_id" "$state_file" "$tmp_root" "$status" "$run_id" "$evidence" <<'PY'
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

session_id, state_file, tmp_root, status, run_id, evidence = sys.argv[1:7]
state_path = Path(state_file)
state = json.loads(state_path.read_text())
rt = state["review_ticket"]

result_path = state_path.parent / f".{session_id}.review-result.json"
result = {
    "producer": "code-review-workflow",
    "session_id": session_id,
    "adapter": rt["selected_adapter"],
    "config_digest": rt["config_digest"],
    "ticket_digest": rt["ticket_digest"],
    "route": rt["route"],
    "worktree_digest": rt.get("worktree_digest", "sha256:ee18908c9d3bd11ef6328edc8c69787476bfca66c1c875729cf026d31fbf532c"),
    "run_id": run_id,
    "adapter_result_ref": f"test-host-ref-{run_id}",
    "adapter_result_digest": "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest(),
    "status": status,
    "reviewer_result": status,
    "evidence": evidence,
}
if result_path.is_symlink():
    raise SystemExit("refusing to write result through symlink")
fd, tmp = tempfile.mkstemp(dir=str(result_path.parent), prefix=".result-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, str(result_path))
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise

digest = "sha256:" + hashlib.sha256(result_path.read_bytes()).hexdigest()
print(str(result_path), digest)
PY
}
