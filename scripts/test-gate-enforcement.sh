#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/app-launch-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID}" <<'PY'
import json, sys
print(json.dumps({"producer":"XcodeBuildMCP","schema_version":1,"session_id":sys.argv[1],
                  "status":"available","build_run_device":"success",
                  "device_transport":"wired","app_launched":True,
                  "build_id":"build-test-1","device_id":"device-test-1"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/app-launch-probe"

run_for() {
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=gate-test /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=gate-test \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --level heavy --task "gate test" >/dev/null

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=gate-test \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null

run_for configure-gates --required review,figma_ui,runtime >/dev/null
run_for confirm-plan >/dev/null

write_report() {
  local name="$1"
  local status="$2"
  /usr/bin/python3 - "$TMP_ROOT/$name.json" "$status" "$TMP_ROOT" <<'PY'
import json
import sys
from pathlib import Path

name = Path(sys.argv[1]).stem
status = sys.argv[2]
tmp_root = Path(sys.argv[3])
report = {
    "producer": "code-review-workflow" if name == "review" else "test",
    "schema_version": 1,
    "session_id": "gate-test",
    "gate": name,
    "status": status,
    "evidence": f"{name} {status}",
}
# review gate 要求 producer=code-review-workflow + reviewer_result 与 status 一致
if name == "review":
    report["reviewer_result"] = status
if name == "figma_ui":
    report["gates"] = {f"G{i}": "pass" for i in range(13)}
    fixture = tmp_root / "g6-fixture"
    source = fixture / "source"
    gates = fixture / "gates"
    runtime = fixture / "runtime"
    gates.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    source.mkdir(parents=True, exist_ok=True)
    gates.joinpath("G6-assets.json").write_text(
        json.dumps(
            {
                "rules": ["collapsed non-interactive visual units must use exported assets in runtime"],
                "assets": [
                    {
                        "figma_id": "2985:24400",
                        "local_asset": "lovon_checked",
                        "collapse": True,
                    }
                ],
                "status": "pass",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    runtime.joinpath("sample-runtime-detail.json").write_text(
        json.dumps(
            {
                "anchor": "figma.2985_24400",
                "node": {
                    "className": "UIImageView",
                    "accessibilityIdentifier": "figma.2985_24400",
                    "imageSize": {"width": 370, "height": 60},
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    source.joinpath("CheckedStripView.swift").write_text(
        'let image = UIImage(named: "lovon_checked")\n'
        'view.accessibilityIdentifier = "figma.2985_24400"\n',
        encoding="utf-8",
    )
    g6_report = tmp_root / "g6-validation.json"
    g6_report.write_text(
        json.dumps(
            {
                "workspace": str(fixture),
                "source_root": str(source),
                "collapsed_count": 1,
                "status": "pass",
                "errors": [],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    report["artifact_workspace"] = str(fixture)
    report["source_root"] = str(source)
    report["g6_validation"] = "pass"
    report["g6_validation_report"] = str(g6_report)
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
/usr/bin/python3 - "$TMP_ROOT/figma_ui.json" "$TMP_ROOT/figma_ui-missing-g6.json" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text())
for key in ("g6_validation", "g6_validation_report", "artifact_workspace", "source_root"):
    report.pop(key, None)
Path(sys.argv[2]).write_text(json.dumps(report) + "\n")
PY
if run_for record-gate --name figma_ui --report "$TMP_ROOT/figma_ui-missing-g6.json" >/dev/null 2>&1; then
  echo "FAIL: figma_ui pass without g6_validation should be rejected" >&2
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

# requirements index.json 在业务项目根且含 pending-human-approval 时 confirm-plan 被拒
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=req-blocked \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "req blocked" >/dev/null
/bin/mkdir -p "$TMP_ROOT/.dev-flow/requirements"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/requirements/index.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "requirements": [{"id": "req-1", "status": "pending-human-approval"}],
}) + "\n")
PY
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=req-blocked \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=req-blocked \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null 2>&1; then
  echo "FAIL: confirm-plan accepted with pending-human-approval requirements" >&2
  exit 1
fi
# requirements 全部批准后 confirm-plan 应通过
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/requirements/index.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "requirements": [{"id": "req-1", "status": "approved"}],
}) + "\n")
PY
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=req-blocked \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null

echo "PASS: G0-G12, review, and runtime gates block commit approval until resolved"
