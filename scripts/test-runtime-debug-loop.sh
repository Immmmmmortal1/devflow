#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/SKILL.md"

require_text() {
  local pattern="$1"
  local message="$2"
  if ! grep -Eq "$pattern" "$SKILL"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_text 'Runtime debug loop' 'missing runtime UI and Console debugging section'
require_text 'automated development loop|automatic development loop|自动开发闭环' 'missing automated development loop positioning'
require_text 'implement.*build.*device|实现.*构建.*真机' 'missing implementation-to-device execution chain'
require_text 'fix.*rerun|修正.*重新|修复.*再次' 'missing automatic fix-and-rerun expectation'
require_text 'human decision|用户决定|人工决策' 'missing explicit human-only blocker boundary'
require_text 'get_debug_page|tap_element' 'missing autonomous UI interaction guidance'
require_text 'read_xcode_console|wait_xcode_console' 'missing on-demand Xcode Console guidance'
require_text '#if DEBUG|DEBUG-only' 'missing compile-time Debug logging boundary'
require_text 'redact|脱敏' 'missing sensitive-data redaction requirement'
require_text 'truncate|截断|bounded' 'missing bounded payload requirement'
require_text 'do not persist|不持久化|不另存' 'missing no-duplicate-log-storage requirement'
require_text 'confirm-gate' 'runtime diagnostics must not bypass source-edit approval'

echo "PASS: dev-flow runtime debug loop contract"
