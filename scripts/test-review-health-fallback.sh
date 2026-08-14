#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/scripts" "$TMP_ROOT/bin" "$TMP_ROOT/fake-gstack/review"
/bin/cp "$ROOT/scripts/environment-health-check.sh" "$TMP_ROOT/scripts/environment-health-check.sh"
/bin/cp "$ROOT/scripts/dev-flow-session.sh" "$TMP_ROOT/scripts/dev-flow-session.sh"
/bin/cp "$ROOT/scripts/resolve-dev-flow-session-id.sh" "$TMP_ROOT/scripts/resolve-dev-flow-session-id.sh"
/bin/cp "$ROOT/scripts/read-app-launch-report.sh" "$TMP_ROOT/scripts/read-app-launch-report.sh"
/bin/cp "$ROOT/scripts/record-app-launch-report.sh" "$TMP_ROOT/scripts/record-app-launch-report.sh"
/bin/cp "$ROOT/scripts/review-health-probe.sh" "$TMP_ROOT/scripts/review-health-probe.sh"
/bin/chmod +x "$TMP_ROOT/scripts/"*.sh

/bin/mkdir -p "$TMP_ROOT/home/.codex/skills/figma-rest-api/scripts"
printf '%s\n' '# figma' > "$TMP_ROOT/home/.codex/skills/figma-rest-api/SKILL.md"
printf '%s\n' '#!/usr/bin/env python3' > "$TMP_ROOT/home/.codex/skills/figma-rest-api/scripts/figma_rest.py"
/bin/chmod +x "$TMP_ROOT/home/.codex/skills/figma-rest-api/scripts/figma_rest.py"
export HOME="$TMP_ROOT/home"
export FIGMA_REST_TOKEN=test-token

printf '%s\n' '# gstack review' > "$TMP_ROOT/fake-gstack/review/SKILL.md"

cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/app-launch-probe"

cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

DEV_FLOW_SESSION_ID=fallback-session \
  ORCHESTRATOR_MCP_ROOT="$TMP_ROOT/missing-orchestrator" \
  GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/fake-gstack/review" \
  /bin/bash "$TMP_ROOT/scripts/review-health-probe.sh" >/dev/null

if ! output="$(
  DEV_FLOW_SESSION_ID=fallback-session \
    ORCHESTRATOR_MCP_ROOT="$TMP_ROOT/missing-orchestrator" \
    GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/fake-gstack/review" \
    /bin/bash "$TMP_ROOT/scripts/review-health-probe.sh"
)"; then
  echo "FAIL: review-health-probe did not accept gstack fallback" >&2
  exit 1
fi

/usr/bin/python3 - "$output" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["status"] == "available", payload
assert payload["transport"] == "fallback", payload
assert payload["fallback"] == "gstack-review", payload
PY

DEV_FLOW_SESSION_ID=fallback-session \
  /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" start --type feature --task "review fallback" >/dev/null

DEV_FLOW_SESSION_ID=fallback-session \
  HOME="$TMP_ROOT/home" \
  FIGMA_REST_TOKEN=test-token \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  ORCHESTRATOR_MCP_ROOT="$TMP_ROOT/missing-orchestrator" \
  GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/fake-gstack/review" \
  /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run >/dev/null || true

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/fallback-session.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text())
evidence = state["environment_health"]["checks"]["review_mcp"]["evidence"]
assert state["environment_health"]["checks"]["review_mcp"]["status"] == "available", state
assert "fallback=gstack-review" in evidence, evidence
PY

if DEV_FLOW_SESSION_ID=blocked-session \
  HOME="$TMP_ROOT/home" \
  ORCHESTRATOR_MCP_ROOT="$TMP_ROOT/missing-orchestrator" \
  GSTACK_REVIEW_SKILL_ROOT="$TMP_ROOT/missing-gstack" \
  /bin/bash "$TMP_ROOT/scripts/review-health-probe.sh" >/dev/null 2>&1; then
  echo "FAIL: review-health-probe should block when MCP and gstack are both missing" >&2
  exit 1
fi

echo "PASS: review MCP health falls back to gstack-review"
