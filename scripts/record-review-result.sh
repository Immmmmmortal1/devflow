#!/usr/bin/env bash
# 受控 review result artifact 写入器。
# 从 stdin 接收实际 adapter 审查结果 JSON，合并 ticket 信息，原子写 result artifact，
# 然后输出 gate report JSON（含 result_artifact 路径 + digest）到 stdout。
#
# 这是 agent/mcp/fallback 三条路径的统一受控入口：
# record-gate 只接受携带有效 result_artifact 的报告，降低误填风险。
# 诚实声明：本地完整性门用于防误操作/漂移/重放，不是对拥有本机写权限攻击者的密码学证明。
# 独立审查事实的真实性由宿主编排层负责（host task ref + handoff digest 记录），
# 拥有本机/仓库写权限者不在威胁模型内。
#
# Usage: bash scripts/record-review-result.sh [--session-id <id>] < result.json
# stdin JSON 必需字段: {status, reviewer_result, run_id, evidence, adapter_result_ref, adapter_result_digest, findings?}
#   - adapter_result_ref: 宿主 task id / orchestrator run id / gstack packet-run ref
#   - adapter_result_digest: 规范化原始 handoff 文本/文件 digest (sha256:...)
#   - run_id 必须与 adapter_result_ref 规则一致（run_id 是 dispatch 级标识，ref 是宿主级标识）
# stdout: gate report JSON（写到 record-gate 的报告路径）
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
# shellcheck source=lib/route-whitelist.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/route-whitelist.sh"

SESSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      SESSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/record-review-result.sh [--session-id <id>] < result.json"
      echo "  stdin: {status, reviewer_result, run_id, evidence, adapter_result_ref, adapter_result_digest, findings?}"
      echo "  stdout: gate report JSON with result_artifact + result_artifact_digest"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

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
RESULT_ARTIFACT="$STATE_DIR/.${SESSION_ID}.review-result.json"
REPORT_PATH="$STATE_DIR/.${SESSION_ID}.review-report.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No active session: $STATE_FILE" >&2
  exit 1
fi

# 从 stdin 读取 adapter 结果到临时文件（避免 ARG_MAX；不用 argv 传大 JSON）
RESULT_TMP="$(/usr/bin/mktemp)"
trap 'rm -f "$RESULT_TMP"' EXIT
cat > "$RESULT_TMP"

/usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$RESULT_ARTIFACT" "$REPORT_PATH" "$RESULT_TMP" "$DEV_FLOW_SOURCE_ROOT" "$DEV_FLOW_PROJECT_ROOT" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
result_artifact_path = Path(sys.argv[3])
report_path = Path(sys.argv[4])
result_tmp_path = Path(sys.argv[5])
source_root = Path(sys.argv[6])  # devflow git clone root — 用于导入 lib
project_root = Path(sys.argv[7])  # 当前项目根 — trusted_root 基准
# trusted_root 必须是项目的 .dev-flow（不是 source_root/.dev-flow），
# 确保 result artifact/report 真实写到当前项目 sessions 且 safe_atomic_write_json 通过
trusted_root = project_root / ".dev-flow"
sys.path.insert(0, os.path.join(str(source_root), 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

state = json.loads(state_path.read_text())

# 必须有 review_ticket
rt = state.get("review_ticket")
if not rt or not rt.get("token"):
    raise SystemExit("no review_ticket in session state; run scripts/issue-review-ticket.sh first.")
if rt.get("consumed"):
    raise SystemExit("review_ticket is already consumed; re-issue before recording result.")
if rt.get("cancelled"):
    raise SystemExit("review_ticket is cancelled; re-issue before recording result.")

# 从临时文件读取 adapter 结果（避免 ARG_MAX）
try:
    adapter_result = json.loads(result_tmp_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as e:
    raise SystemExit(f"stdin is not valid JSON: {e}")

# 校验必需字段
required = ["status", "reviewer_result", "run_id", "evidence",
            "adapter_result_ref", "adapter_result_digest"]
for field in required:
    if not adapter_result.get(field):
        raise SystemExit(f"adapter result missing required field: {field}")

status = adapter_result["status"]
if status not in ("pass", "revise", "blocked"):
    raise SystemExit(f"invalid status: {status} (must be pass/revise/blocked)")

reviewer_result = adapter_result["reviewer_result"]
expected_result = {"pass": "pass", "revise": "revise", "blocked": "blocked"}.get(status)
if reviewer_result != expected_result:
    raise SystemExit(f"status={status} requires reviewer_result={expected_result} (got {reviewer_result!r})")

# 校验 adapter_result_ref 和 adapter_result_digest 格式
adapter_result_ref = adapter_result["adapter_result_ref"]
if not isinstance(adapter_result_ref, str) or not adapter_result_ref.strip():
    raise SystemExit("adapter_result_ref must be a non-empty string (host task id / orchestrator run id / gstack packet-run ref)")

adapter_result_digest = adapter_result["adapter_result_digest"]
if not isinstance(adapter_result_digest, str) or not adapter_result_digest.startswith("sha256:"):
    raise SystemExit("adapter_result_digest must be a sha256-prefixed string (canonicalized original handoff text/file digest)")
# 统一 digest 格式校验：sha256: 前缀 + 严格 64 位小写十六进制
_hex_part = adapter_result_digest[len("sha256:"):]
if len(_hex_part) != 64:
    raise SystemExit(f"adapter_result_digest must have exactly 64 hex chars after 'sha256:' (got {len(_hex_part)})")
if not all(c in "0123456789abcdef" for c in _hex_part):
    raise SystemExit("adapter_result_digest must contain only lowercase hex chars after 'sha256:'")

# 合并 ticket 信息构建 result artifact
ticket_token = rt["token"]
ticket_digest = rt["ticket_digest"]
selected_adapter = rt["selected_adapter"]
config_digest = rt["config_digest"]
route = rt["route"]
worktree_digest = rt.get("worktree_digest", rt.get("diff_digest", ""))

result_artifact = {
    "producer": "code-review-workflow",
    "session_id": session_id,
    "adapter": selected_adapter,
    "config_digest": config_digest,
    "ticket_digest": ticket_digest,
    "route": route,
    "worktree_digest": worktree_digest,
    "run_id": adapter_result["run_id"],
    "adapter_result_ref": adapter_result_ref,
    "adapter_result_digest": adapter_result_digest,
    "status": status,
    "reviewer_result": reviewer_result,
    "evidence": adapter_result["evidence"],
}
if adapter_result.get("findings"):
    result_artifact["findings"] = adapter_result["findings"]

# 原子写 result artifact
safe_atomic_write_json(trusted_root, result_artifact_path, result_artifact)
result_artifact_digest = sha256_file(result_artifact_path)

# 构建 gate report
review_path_map = {
    "agent/openai-reviewer": "reviewer",
    "mcp/orchestrator": "mcp",
    "skill/gstack": "fallback",
}
gate_report = {
    "producer": "code-review-workflow",
    "schema_version": 1,
    "session_id": session_id,
    "gate": "review",
    "route": route,
    "review_path": review_path_map.get(selected_adapter, "reviewer"),
    "status": status,
    "reviewer_result": reviewer_result,
    "evidence": adapter_result["evidence"],
    "run_id": adapter_result["run_id"],
    "adapter_result_ref": adapter_result_ref,
    "adapter_result_digest": adapter_result_digest,
    "diff_evidence": worktree_digest,
    "selected_adapter": selected_adapter,
    "config_digest": config_digest,
    "ticket_token": ticket_token,
    "ticket_digest": ticket_digest,
    "result_artifact": str(result_artifact_path),
    "result_artifact_digest": result_artifact_digest,
}
if adapter_result.get("findings"):
    gate_report["findings"] = adapter_result["findings"]

# 写 gate report
safe_atomic_write_json(trusted_root, report_path, gate_report)

print(json.dumps(gate_report, ensure_ascii=False, indent=2))
PY
