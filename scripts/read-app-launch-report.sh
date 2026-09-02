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

if [[ ! -f "$REPORT_FILE" ]]; then
  echo "No app launch report for session $SESSION_ID." >&2
  echo "Run: bash \"$(dev_flow_script_path dev-flow.sh)\" app-launch instructions" >&2
  echo "Then record the bounded XcodeBuildMCP result with:" >&2
  echo "  bash \"$(dev_flow_script_path dev-flow.sh)\" app-launch record --report <path|->" >&2
  exit 1
fi

cat "$REPORT_FILE"
