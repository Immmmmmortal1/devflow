#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/usr/bin/trash "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/scripts"
/bin/cp "$ROOT/scripts/dev-flow-session.sh" "$TMP_ROOT/scripts/dev-flow-session.sh"
/bin/cp "$ROOT/scripts/environment-health-check.sh" "$TMP_ROOT/scripts/environment-health-check.sh"

run_for() {
  DEV_FLOW_SESSION_ID=gate-test /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" "$@"
}

DEV_FLOW_SESSION_ID=gate-test \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" start --type feature --task "gate test" >/dev/null

DEV_FLOW_SESSION_ID=gate-test \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$TMP_ROOT/scripts/environment-health-check.sh" run >/dev/null

run_for configure-gates --required review,figma_ui,runtime >/dev/null
run_for confirm-plan >/dev/null

write_report() {
  local name="$1"
  local status="$2"
  /usr/bin/python3 - "$TMP_ROOT/$name.json" "$status" <<'PY'
import json
import sys
from pathlib import Path

name = Path(sys.argv[1]).stem
status = sys.argv[2]
report = {
    "producer": "test",
    "schema_version": 1,
    "session_id": "gate-test",
    "gate": name,
    "status": status,
    "evidence": f"{name} {status}",
}
if name == "figma_ui":
    report["gates"] = {f"G{i}": "pass" for i in range(13)}
Path(sys.argv[1]).write_text(json.dumps(report) + "\n")
PY
}

write_report review pass
run_for record-gate --name review --report "$TMP_ROOT/review.json" >/dev/null

write_report figma_ui pass
if ! /usr/bin/python3 - "$TMP_ROOT/figma_ui.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
report = json.loads(path.read_text())
report["gates"]["G12"] = "blocked"
path.write_text(json.dumps(report) + "\n")
PY
then
  echo "FAIL: malformed figma report fixture unexpectedly failed" >&2
  exit 1
fi
if run_for record-gate --name figma_ui --report "$TMP_ROOT/figma_ui.json" >/dev/null 2>&1; then
  echo "FAIL: incomplete G0-G12 result reached the session" >&2
  exit 1
fi
write_report figma_ui pass
run_for record-gate --name figma_ui --report "$TMP_ROOT/figma_ui.json" >/dev/null

write_report runtime runtime-failed
run_for record-gate --name runtime --report "$TMP_ROOT/runtime.json" >/dev/null
if run_for approve-commit >/dev/null 2>&1; then
  echo "FAIL: failed runtime gate reached approve-commit" >&2
  exit 1
fi

write_report runtime runtime-verified
run_for record-gate --name runtime --report "$TMP_ROOT/runtime.json" >/dev/null
run_for approve-commit >/dev/null

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/gate-test.json" <<'PY'
import json
import sys
data = json.loads(open(sys.argv[1]).read())
assert data["gate_results"]["figma_ui"]["status"] == "pass"
assert data["gate_results"]["review"]["status"] == "pass"
assert data["gate_results"]["runtime"]["status"] == "runtime-verified"
assert data["commit_approved_at"] is not None
PY

echo "PASS: G0-G12, review, and runtime gates block commit approval until resolved"
