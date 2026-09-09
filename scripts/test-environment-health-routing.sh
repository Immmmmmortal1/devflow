#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP_SKILL="$ROOT/SKILL.md"
HEALTH_SKILL="$ROOT/skills/environment-health-check/SKILL.md"

[[ -x "$ROOT/scripts/environment-health-check.sh" ]]

line_of() {
  /usr/bin/grep -nF "$1" "$2" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

classify_line="$(line_of '### 1. Classify the route' "$TOP_SKILL")"
conditional_line="$(line_of '### 2. Activate conditional skills' "$TOP_SKILL")"
confirm_line="$(line_of '### 4. Confirm the implementation scope' "$TOP_SKILL")"
health_line="$(line_of '### 5. Run the environment health gate' "$TOP_SKILL")"
implement_line="$(line_of '### 6. Implement or review' "$TOP_SKILL")"

[[ -n "$classify_line" && -n "$conditional_line" && -n "$confirm_line" && -n "$health_line" && -n "$implement_line" ]]
(( conditional_line > classify_line ))
(( confirm_line > conditional_line ))
(( health_line > confirm_line ))
(( health_line < implement_line ))

for capability in 'App launch' DebugBridge '审查角色' figma-rest-api; do
  /usr/bin/grep -qF "$capability" "$TOP_SKILL"
  /usr/bin/grep -qF "$capability" "$HEALTH_SKILL"
done

# capability 模型：required capabilities 从 required_gates 派生；非 required = not-required。
/usr/bin/grep -qF 'required capabilities are derived from the session' "$TOP_SKILL"
/usr/bin/grep -qF 'non-required capabilities are recorded as `not-required`' "$TOP_SKILL"
/usr/bin/grep -qF 'does not participate in route classification' "$TOP_SKILL"
/usr/bin/grep -qF 'participate in the overall status' "$HEALTH_SKILL"
/usr/bin/grep -qF 'bash /path/to/devflow/scripts/dev-flow.sh environment-health run' "$TOP_SKILL"

echo "PASS: environment-health-check runs after confirm-plan and before implementation"
