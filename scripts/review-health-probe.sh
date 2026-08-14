#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$ROOT/scripts/resolve-dev-flow-session-id.sh"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?

transport="none"
fallback=""
skill_path=""
status="blocked"

doctor="${ORCHESTRATOR_MCP_ROOT:-$ROOT/../../orchestrator-mcp}/scripts/orchestrator-doctor.sh"
if [[ -x "$doctor" ]] && "$doctor" >/dev/null 2>&1; then
  transport="mcp"
  status="available"
else
  for candidate in \
    "${GSTACK_REVIEW_SKILL_ROOT:-}" \
    "$HOME/.claude/skills/gstack/review" \
    "$HOME/.codex/skills/gstack/review" \
    "$HOME/.cursor/skills/gstack/review"; do
    if [[ -n "$candidate" && -f "$candidate/SKILL.md" ]]; then
      transport="fallback"
      fallback="gstack-review"
      skill_path="$candidate"
      status="available"
      break
    fi
  done
fi

/usr/bin/python3 - "$SESSION_ID" "$status" "$transport" "$fallback" "$skill_path" <<'PY'
import json
import sys

session_id, status, transport, fallback, skill_path = sys.argv[1:6]
payload = {
    "producer": "review-health-probe",
    "schema_version": 1,
    "session_id": session_id,
    "status": status,
    "transport": transport,
    "fallback": fallback or None,
}
if skill_path:
    payload["skill_path"] = skill_path
print(json.dumps(payload, ensure_ascii=False))
PY

if [[ "$status" == "available" ]]; then
  exit 0
fi
exit 1
