#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="$ROOT/SKILL.md"
RUNTIME_SKILL="$ROOT/skills/runtime-debug-workflow/SKILL.md"

require_text() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_text "$ORCHESTRATOR" 'runtime-debug-workflow' 'dev-flow must delegate runtime validation'
require_text "$ORCHESTRATOR" 'automated development loop' 'missing automated development loop positioning'
require_text "$ORCHESTRATOR" 'runtime-verified|runtime-failed|runtime-blocked' 'missing runtime result contract'

if grep -Eq 'get_debug_page|tap_element|read_app_logs|wait_app_logs|inspect_ui' "$ORCHESTRATOR"; then
  echo "FAIL: runtime tool procedures must not be duplicated in dev-flow" >&2
  exit 1
fi

require_text "$RUNTIME_SKILL" 'XcodeBuildMCP' 'missing physical-device build/run guidance'
require_text "$RUNTIME_SKILL" 'get_debug_page|tap_element' 'missing autonomous UI interaction guidance'
require_text "$RUNTIME_SKILL" 'inspect_ui' 'missing UIWindow/UIView inspection guidance'
require_text "$RUNTIME_SKILL" 'read_app_logs|wait_app_logs' 'missing current-run App log-pool guidance'
require_text "$RUNTIME_SKILL" '#if DEBUG|DEBUG-only' 'missing compile-time Debug logging boundary'
require_text "$RUNTIME_SKILL" 'redact|脱敏' 'missing sensitive-data redaction requirement'
require_text "$RUNTIME_SKILL" 'bounded|truncate|截断' 'missing bounded payload requirement'
require_text "$RUNTIME_SKILL" 'cursor|persisted|persistent|不持久化' 'missing no-duplicate-log-storage requirement'
require_text "$RUNTIME_SKILL" 'confirm-gate' 'runtime diagnostics must not bypass source-edit approval'
require_text "$RUNTIME_SKILL" 'Rebuild and rerun|rebuild.*rerun|重新' 'missing rebuild-and-rerun loop'

echo "PASS: dev-flow delegates runtime validation to runtime-debug-workflow"
