#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
REPORT_FILE="$STATE_DIR/$SESSION_ID.app-launch.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/record-app-launch-report.sh record --report <path>

Record a bounded XcodeBuildMCP build_run_device success report for the current dev-flow
session. --report is REQUIRED: pass a real build_run_device result path (or - for stdin).
This script never fabricates a success payload on its own.

The report JSON must include producer=XcodeBuildMCP, schema_version=1, the current
session_id, status=available, build_run_device=success, device_transport=wired, and
app_launched=true. It must also carry build_id and device_id reflecting the actual
build and device used (placeholders "unknown"/"n/a"/"-"/"" are rejected, case-insensitive).

Session selection matches scripts/resolve-dev-flow-session-id.sh.
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [[ "${1:-}" != "record" ]]; then
  usage >&2
  exit 2
fi
shift

source_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      source_path="${2:-}"
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

mkdir -p "$STATE_DIR"

/usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" "$source_path" "$(now_utc)" <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]
source_path = sys.argv[3]
timestamp = sys.argv[4]

REQUIRED = {
    "producer": "XcodeBuildMCP",
    "schema_version": 1,
    "status": "available",
    "build_run_device": "success",
    "device_transport": "wired",
}


def validate_payload(payload):
    if not isinstance(payload, dict):
        raise SystemExit("App launch report must be a JSON object.")
    for key, expected in REQUIRED.items():
        if payload.get(key) != expected:
            raise SystemExit(f"Invalid app launch report field: {key}")
    if payload.get("session_id") != session_id:
        raise SystemExit("App launch report session_id does not match the current session.")
    if payload.get("app_launched") is not True:
        raise SystemExit("app_launched must be true.")
    # build_id / device_id 是动态值，不能放进 REQUIRED 精确匹配；
    # 这里单独做非空 + 非占位值校验，防止伪造"XcodeBuildMCP 真机启动成功"。
    placeholders = {"unknown", "n/a", "-", ""}
    for field in ("build_id", "device_id"):
        value = payload.get(field)
        if not isinstance(value, str) or value.strip() == "":
            raise SystemExit(f"App launch report missing required field: {field}")
        # 先 strip 再 lower，避免 " N/A " 这类带空格的占位值绕过校验
        normalized = value.strip().lower()
        if normalized in placeholders:
            raise SystemExit(
                f"App launch report field {field} uses placeholder value: {value!r}"
            )
    if session_id == "local" and os.environ.get("CURSOR_AGENT") == "1":
        raise SystemExit(
            "Cannot record app launch for session_id 'local' inside Cursor. "
            "Run dev-flow session start and pass DEV_FLOW_SESSION_ID via build_run_device env."
        )


# 无 --report 时拒绝生成成功 payload，调用方必须提供真实 build_run_device 来源。
if not source_path:
    raise SystemExit(
        "record requires --report <path> or - (stdin) with a real XcodeBuildMCP build_run_device result"
    )

if source_path == "-":
    raw = sys.stdin.read()
else:
    raw = Path(source_path).read_text()
try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Invalid JSON in app launch report: {exc}") from exc
validate_payload(payload)
if "recorded_at" not in payload:
    payload["recorded_at"] = timestamp

if session_id == "local" and os.environ.get("CURSOR_AGENT") == "1":
    raise SystemExit(
        "Cannot record app launch for session_id 'local' inside Cursor. "
        "Run dev-flow session start and pass DEV_FLOW_SESSION_ID via build_run_device env."
    )

report_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
print(report_path)
PY
