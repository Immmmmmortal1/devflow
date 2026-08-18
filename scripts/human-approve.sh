#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/human-approve.sh approve --stage confirm|accept --artifact <path> [--task "label"]
  scripts/human-approve.sh status

Record a human approval token for the current dev-flow session. approve requires
an interactive TTY so the yes/no prompt is typed by a human, not piped in.
--artifact binds the token to the artifact's SHA-256: if the artifact content
changes after approval, record-gate ui_parity will reject the token (agent cannot
tamper with the artifact after human approval and reuse the token).

Session selection matches scripts/resolve-dev-flow-session-id.sh.
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift

case "$cmd" in
  approve)
    STAGE=""
    TASK=""
    ARTIFACT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stage)
          STAGE="${2:-}"
          shift 2
          ;;
        --task)
          TASK="${2:-}"
          shift 2
          ;;
        --artifact)
          ARTIFACT="${2:-}"
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    # --stage 必须是 confirm 或 accept
    if [[ "$STAGE" != "confirm" && "$STAGE" != "accept" ]]; then
      echo "approve requires --stage confirm|accept" >&2
      exit 2
    fi
    # --artifact 必填：token 绑定到 artifact 内容 sha256，批准后篡改 artifact 会被 record-gate 拒绝
    if [[ -z "$ARTIFACT" ]]; then
      echo "approve requires --artifact <path> pointing to the artifact being approved" >&2
      exit 2
    fi
    if [[ ! -f "$ARTIFACT" ]]; then
      echo "approve --artifact path does not exist: $ARTIFACT" >&2
      exit 2
    fi
    # 非 TTY 拒绝：人工批准必须在交互终端输入，禁止管道/重定向喂入 yes
    if [[ ! -t 0 ]]; then
      echo "human approval must be typed on an interactive terminal" >&2
      exit 2
    fi
    # 生成一次性 token + 计算 artifact SHA-256（token 与 artifact 内容绑定）
    read -r TOKEN DIGEST <<< "$(/usr/bin/python3 -c '
import hashlib, secrets, sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
print(secrets.token_hex(16), hashlib.sha256(data).hexdigest())
' "$ARTIFACT")"
    printf 'Session: %s\nStage:   %s\n' "$SESSION_ID" "$STAGE"
    if [[ -n "$TASK" ]]; then
      printf 'Task:    %s\n' "$TASK"
    fi
    printf 'Artifact: %s\nSHA-256:  %s\n' "$ARTIFACT" "$DIGEST"
    printf 'Type "yes" to record human approval: '
    read -r answer
    # 大小写不敏感比较 yes（兼容 bash 3.2，不用 nocasematch）
    case "$answer" in
      [yY][eE][sS]) ;;
      *)
        echo "Approval cancelled." >&2
        exit 1
        ;;
    esac
    /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$STAGE" "$TOKEN" "$DIGEST" "$(now_utc)" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
stage = sys.argv[3]
token = sys.argv[4]
digest = sys.argv[5]
timestamp = sys.argv[6]

if not state_path.is_file():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
# human_approval_tokens: stage -> token
# human_approval_digests: stage -> 批准时 artifact 内容的 sha256（防篡改）
# human_approved_at: stage -> UTC ISO 时间戳
tokens = state.setdefault("human_approval_tokens", {})
if not isinstance(tokens, dict):
    raise SystemExit("human_approval_tokens is corrupted; expected an object.")
tokens[stage] = token
digests = state.setdefault("human_approval_digests", {})
if not isinstance(digests, dict):
    raise SystemExit("human_approval_digests is corrupted; expected an object.")
digests[stage] = digest
approved_at = state.setdefault("human_approved_at", {})
if not isinstance(approved_at, dict):
    raise SystemExit("human_approved_at is corrupted; expected an object.")
approved_at[stage] = timestamp
state["session_id"] = session_id
# 原子化写入：先写临时文件再 os.replace，权限 0600 防止其他用户读取 token
payload = json.dumps(state, ensure_ascii=False, indent=2) + "\n"
fd, tmp_path = tempfile.mkstemp(
    dir=str(state_path.parent), prefix=state_path.name + ".", suffix=".tmp"
)
try:
    with os.fdopen(fd, "w") as handle:
        handle.write(payload)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, str(state_path))
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
print(f"Approval recorded for stage {stage}")
PY
    ;;
  status)
    /usr/bin/python3 - "$STATE_FILE" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
if not state_path.is_file():
    print("No dev-flow session.")
    raise SystemExit(0)
state = json.loads(state_path.read_text())
tokens = state.get("human_approval_tokens") or {}
digests = state.get("human_approval_digests") or {}
approved_at = state.get("human_approved_at") or {}
if not tokens:
    print("No human approvals recorded for this session.")
else:
    print(json.dumps({
        "human_approval_tokens": tokens,
        "human_approval_digests": digests,
        "human_approved_at": approved_at,
    }, indent=2))
PY
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
