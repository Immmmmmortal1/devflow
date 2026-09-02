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
conditional_line="$(line_of '### 2. Activate conditional skills' "$ORCHESTRATOR")"
confirm_line="$(line_of '### 4. Confirm the implementation scope' "$ORCHESTRATOR")"
health_line="$(line_of '### 5. Run the environment health gate' "$ORCHESTRATOR")"
implement_line="$(line_of '### 6. Implement or review' "$ORCHESTRATOR")"

[[ -n "$classify_line" && -n "$conditional_line" && -n "$confirm_line" && -n "$health_line" && -n "$implement_line" ]]
(( conditional_line > classify_line ))
(( confirm_line > conditional_line ))
(( health_line > confirm_line ))
(( health_line < implement_line ))

for capability in 'App launch' DebugBridge 'Review MCP' figma-rest-api; do
  /usr/bin/grep -qF "$capability" "$ORCHESTRATOR"
  /usr/bin/grep -qF "$capability" "$HEALTH_SKILL"
done

/usr/bin/grep -qF 'Required checks depend on the session level' "$ORCHESTRATOR"
/usr/bin/grep -qF '`standard` — `app_launch` + `review_mcp`' "$ORCHESTRATOR"
/usr/bin/grep -qF '`heavy` — all four' "$ORCHESTRATOR"
/usr/bin/grep -qF '`blocked` or `not-run`' "$ORCHESTRATOR"
/usr/bin/grep -qF 'does not participate in route classification' "$ORCHESTRATOR"
/usr/bin/grep -qF 'every capability required by the current session level' "$HEALTH_SKILL"
/usr/bin/grep -qF 'bash /path/to/devflow/scripts/dev-flow.sh environment-health run' "$ORCHESTRATOR"

echo "PASS: environment-health-check runs after confirm-plan and before implementation"
