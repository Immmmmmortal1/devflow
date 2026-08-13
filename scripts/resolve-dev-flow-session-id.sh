#!/usr/bin/env bash
# Resolve the current DevFlow session id.
# Precedence:
#   1. DEV_FLOW_SESSION_ID
#   2. CODEX_THREAD_ID
#   3. CURSOR_CONVERSATION_ID
#   4. "local" outside Cursor
#
# Inside Cursor (CURSOR_AGENT=1), falling through to "local" is rejected so concurrent
# chats cannot overwrite a shared local.json.

resolve_dev_flow_session_id() {
  local sid=""

  if [[ -n "${DEV_FLOW_SESSION_ID:-}" ]]; then
    sid="$DEV_FLOW_SESSION_ID"
  elif [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    sid="$CODEX_THREAD_ID"
  elif [[ -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
    sid="$CURSOR_CONVERSATION_ID"
  elif [[ "${CURSOR_AGENT:-}" == "1" ]]; then
    echo "Missing DevFlow session id in Cursor. Expected CURSOR_CONVERSATION_ID or DEV_FLOW_SESSION_ID." >&2
    return 2
  else
    sid="local"
  fi

  if [[ ! "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "Invalid dev-flow session id: $sid" >&2
    return 2
  fi

  printf '%s\n' "$sid"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_dev_flow_session_id
fi
