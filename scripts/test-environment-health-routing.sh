#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="$ROOT/SKILL.md"
HEALTH_SKILL="$ROOT/skills/environment-health-check/SKILL.md"

[[ -x "$ROOT/scripts/environment-health-check.sh" ]]

line_of() {
  /usr/bin/grep -nF "$1" "$2" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

classify_line="$(line_of '### 1. Classify the route' "$ORCHESTRATOR")"
health_line="$(line_of '### 2. Run the first gate for the selected route' "$ORCHESTRATOR")"
conditional_line="$(line_of '### 3. Activate conditional skills' "$ORCHESTRATOR")"

[[ -n "$classify_line" && -n "$health_line" && -n "$conditional_line" ]]
(( health_line > classify_line ))
(( health_line < conditional_line ))

for capability in 'App launch' DebugBridge 'Review MCP' figma-rest-api; do
  /usr/bin/grep -qF "$capability" "$ORCHESTRATOR"
  /usr/bin/grep -qF "$capability" "$HEALTH_SKILL"
done

/usr/bin/grep -qF 'All four checks must return `available`' "$ORCHESTRATOR"
/usr/bin/grep -qF '`blocked` or `not-run`' "$ORCHESTRATOR"
/usr/bin/grep -qF 'does not participate in route classification' "$ORCHESTRATOR"
/usr/bin/grep -qF 'every capability must be `available`' "$HEALTH_SKILL"
/usr/bin/grep -qF 'bash scripts/environment-health-check.sh run' "$ORCHESTRATOR"

echo "PASS: environment-health-check is the first gate after route classification"
