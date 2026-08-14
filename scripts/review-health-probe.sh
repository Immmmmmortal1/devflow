#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?

transport="none"
fallback=""
skill_path=""
status="blocked"

orchestrator_root="${ORCHESTRATOR_MCP_ROOT:-}"
if [[ -z "$orchestrator_root" && -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root" ]]; then
  orchestrator_root="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root")"
fi
if [[ -z "$orchestrator_root" ]]; then
  orchestrator_root="$SOURCE_ROOT/../../orchestrator-mcp"
fi

doctor="$orchestrator_root/scripts/orchestrator-doctor.sh"
orchestrator_ready=0
if [[ -x "$doctor" ]] && "$doctor" >/dev/null 2>&1; then
  orchestrator_ready=1
elif [[ -x "$orchestrator_root/codex-stdio-wrapper.sh" && -x "$orchestrator_root/.venv/bin/python" ]]; then
  orchestrator_ready=1
fi

if [[ "$orchestrator_ready" -eq 1 ]]; then
  transport="mcp"
  status="available"
else
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

  for candidate in \
    "${GSTACK_REVIEW_SKILL_ROOT:-}" \
    "$skills_root/gstack/review" \
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
