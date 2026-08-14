#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$ROOT/scripts/resolve-dev-flow-session-id.sh"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
REPORT_FILE="$ROOT/.dev-flow/sessions/$SESSION_ID.app-launch.json"

if [[ ! -f "$REPORT_FILE" ]]; then
  echo "No app launch report for session $SESSION_ID. Run record-app-launch-report.sh after build_run_device." >&2
  exit 1
fi

cat "$REPORT_FILE"
