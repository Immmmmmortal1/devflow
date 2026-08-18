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
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=parity-test /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=parity-test \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type ui_review --task "parity gate" >/dev/null

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=parity-test \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null

if run_for confirm-plan >/dev/null 2>&1; then
  echo "FAIL: ui_review confirm-plan passed without runtime/ui_parity gates" >&2
  exit 1
fi

run_for configure-gates --required review,runtime,ui_parity >/dev/null
run_for confirm-plan >/dev/null

# Build bounded authorization, verification, and acceptance evidence.
/bin/mkdir -p "$TMP_ROOT/artifacts/groups/2985_1"
/usr/bin/python3 - "$TMP_ROOT/artifacts" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
base = {
    "producer": "ui-review",
    "schema_version": 1,
    "session_id": "parity-test",
    "artifact_workspace": str(root),
}
def write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload) + "\n")

write(root / "manifest.json", {
    **base,
    "canonical_figma_url": "https://figma.example/file?node-id=2985-1",
    "root_node_id": "2985:0",
    "screen_state": "default",
})
write(root / "structure" / "screen-classification.json", {
    **base, "expected_base_layout": "UIScrollView",
})
write(root / "structure" / "minimum-unit-index.json", {
    **base,
    "units": [{"figma_id": "2985:1", "group_id": "2985_1", "name": "icon", "unit_kind": "image"}],
})
write(root / "structure" / "structure-sweep-complete.json", {
    **base, "status": "pass", "minimum_unit_count": 1,
})
write(root / "structure" / "structure-review.json", {
    **base, "status": "pass", "run_id": "structure-run-1",
    "role": "structure", "verdict": "pass", "reviewed_at": "2026-08-13T00:00:00Z",
    "summary": "structure review pass",
})
write(root / "groups" / "2985_1" / "detail.json", {
    **base, "group_id": "2985_1", "split_status": "complete",
    "minimum_units": [{
        "figma_id": "2985:1", "group_id": "2985_1", "name": "icon", "unit_kind": "image",
        "anchor": "figma.2985_1", "is_minimum_unit": True, "asset_collapse_eligible": True,
        "has_localizable_text": False, "has_interaction": False,
        "split_status": "complete", "pending_child_ids": [],
    }],
})
write(root / "groups" / "2985_1" / "detail-review.json", {
    **base, "group_id": "2985_1", "status": "pass", "run_id": "detail-run-2985-1",
    "role": "detail", "verdict": "pass", "reviewed_at": "2026-08-13T00:00:00Z",
    "summary": "detail review pass",
})
image_evidence = {
    "runtime_path": "runtime/2985_1.json",
    "figma_sha256": "a" * 64,
    "source_asset_sha256": "b" * 64,
    "runtime_asset_name": "icon",
    "expected_frame": {"x": 0, "y": 0, "width": 24, "height": 24},
    "measured_frame": {"x": 0, "y": 0, "width": 24, "height": 24},
    "tolerance": {"origin_pt": 0.5, "size_pt": 0.5},
}
screen = {
    "background": {
        "observation_status": "observed", "mark": "ok",
        "evidence": {"runtime_path": "runtime/root.json", "expected": [1, 1, 1, 1], "measured": [1, 1, 1, 1]},
    },
    "base_layout": {
        "observation_status": "observed", "mark": "ok",
        "evidence": {"runtime_path": "runtime/root.json", "expected": "UIScrollView", "measured": "UIScrollView"},
    },
}
baseline = {
    **base,
    "units": [{
        "figma_id": "2985:1", "unit_kind": "image", "observation_status": "observed",
        "mark": "wrong", "findings": ["asset hash mismatch"], "evidence": image_evidence,
    }],
    "screen": screen,
    "runtime_extras": [],
    "totals": {"ok": 0, "wrong": 1, "missing": 0},
}
write(root / "parity-result.baseline.json", baseline)
(root / "parity-result.baseline.md").write_text("# Baseline\n")
digests = {
    "json": hashlib.sha256((root / "parity-result.baseline.json").read_bytes()).hexdigest(),
    "md": hashlib.sha256((root / "parity-result.baseline.md").read_bytes()).hexdigest(),
}
current = {
    **baseline,
    "units": [{
        **baseline["units"][0],
        "mark": "ok",
        "evidence": {**image_evidence, "source_asset_sha256": "a" * 64},
    }],
    "totals": {"ok": 1, "wrong": 0, "missing": 0},
    "baseline_sha256": digests,
}
write(root / "parity-result.json", current)
confirmed = {
    **base,
    "confirmed_by": "human",
    "may_proceed_to_fix": True,
    "units_to_fix": ["2985:1"],
    "runtime_extras_to_remove": [],
    "approval_token": "parity-confirm-token",
}
(root / "parity-confirmed.json").write_text(json.dumps(confirmed) + "\n")
verify = {
    **base,
    "figma_id": "2985:1",
    "result": "ok",
    "mark_after": "ok",
    "debugbridge_evidence": ["runtime/2985_1.json"],
}
verify_path = root / "groups" / "2985_1" / "repair-verify.json"
verify_path.write_text(json.dumps(verify) + "\n")
open_acceptance = {
    **base,
    "confirmed_by": "human",
    "units_accepted": [],
    "units_rework": [{"figma_id": "2985:1", "reason": "still wrong"}],
    "units_reverted": [],
    "verification_reports": {},
    "revert_verification_reports": {},
    "all_authorized_repairs_resolved": False,
}
(root / "repair-accepted-open.json").write_text(json.dumps(open_acceptance) + "\n")
acceptance = {
    **base,
    "confirmed_by": "human",
    "units_accepted": ["2985:1"],
    "units_rework": [],
    "units_reverted": [],
    "verification_reports": {"2985:1": str(verify_path)},
    "revert_verification_reports": {},
    "all_authorized_repairs_resolved": True,
    "approval_token": "parity-accept-token",
}
(root / "repair-accepted.json").write_text(json.dumps(acceptance) + "\n")
PY

/usr/bin/python3 "$ROOT/scripts/validate-ui-review-artifacts.py" \
  --workspace "$TMP_ROOT/artifacts" --stage all --session-id parity-test \
  --report "$TMP_ROOT/artifacts/artifact-validation.json" >/dev/null

write_gate_report() {
  local path="$1"
  local gate="$2"
  local status="$3"
  /usr/bin/python3 - "$path" "$gate" "$status" "$TMP_ROOT/artifacts" <<'PY'
import json
import sys
from pathlib import Path
path, gate, status, workspace = sys.argv[1:]
report = {
    "producer": "test",
    "schema_version": 1,
    "session_id": "parity-test",
    "gate": gate,
    "status": status,
    "evidence": f"{gate} {status}",
}
if gate == "runtime":
    report.update({
        "producer": "runtime-debug-workflow",
        "artifact_workspace": str(Path(workspace).resolve()),
        "parity_confirmed_report": str(Path(workspace) / "parity-confirmed.json"),
        "verified_ids": ["2985:1"],
        "debugbridge_evidence": ["runtime/2985_1.json"],
    })
elif gate == "review":
    workspace_path = Path(workspace)
    report.update({
        "producer": "code-review-workflow",
        "route": "ui-parity-review",
        "source_edits": True,
        "reviewer_result": "pass",
        "run_id": "review-run-1",
        "diff_evidence": "curated diff for 2985:1",
        "artifact_workspace": str(workspace_path.resolve()),
        "baseline_report": str(workspace_path / "parity-result.baseline.json"),
        "parity_confirmed_report": str(workspace_path / "parity-confirmed.json"),
        "repair_accepted_report": str(workspace_path / "repair-accepted.json"),
    })
Path(path).write_text(json.dumps(report) + "\n")
PY
}

write_gate_report "$TMP_ROOT/review.json" review pass
/usr/bin/python3 - "$TMP_ROOT/review.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["producer"] = "test"
payload.pop("route")
path.write_text(json.dumps(payload) + "\n")
PY
if run_for record-gate --name review --report "$TMP_ROOT/review.json" >/dev/null 2>&1; then
  echo "FAIL: repaired ui_review accepted a generic review report" >&2
  exit 1
fi
write_gate_report "$TMP_ROOT/review.json" review pass
run_for record-gate --name review --report "$TMP_ROOT/review.json" >/dev/null

write_gate_report "$TMP_ROOT/runtime.json" runtime runtime-verified
run_for record-gate --name runtime --report "$TMP_ROOT/runtime.json" >/dev/null

/usr/bin/python3 - "$TMP_ROOT/ui_parity-open.json" "$TMP_ROOT/artifacts" <<'PY'
import json, sys
from pathlib import Path
workspace = Path(sys.argv[2]).resolve()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "ui-review", "schema_version": 1, "session_id": "parity-test",
    "gate": "ui_parity", "status": "accepted", "evidence": "open repairs",
    "artifact_workspace": str(workspace),
    "parity_confirmed_report": str(workspace / "parity-confirmed.json"),
    "repair_accepted_report": str(workspace / "repair-accepted-open.json"),
    "artifact_validation_report": str(workspace / "artifact-validation.json"),
}) + "\n")
PY
if run_for record-gate --name ui_parity --report "$TMP_ROOT/ui_parity-open.json" >/dev/null 2>&1; then
  echo "FAIL: ui_parity=accepted with unresolved repairs should be rejected" >&2
  exit 1
fi

/usr/bin/python3 - "$TMP_ROOT/ui_parity.json" "$TMP_ROOT/artifacts" <<'PY'
import json, sys
from pathlib import Path
workspace = Path(sys.argv[2]).resolve()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "ui-review", "schema_version": 1, "session_id": "parity-test",
    "gate": "ui_parity", "status": "accepted", "evidence": "all accepted",
    "artifact_workspace": str(workspace),
    "parity_confirmed_report": str(workspace / "parity-confirmed.json"),
    "repair_accepted_report": str(workspace / "repair-accepted.json"),
    "artifact_validation_report": str(workspace / "artifact-validation.json"),
}) + "\n")
PY

# A hand-written pass report cannot hide malformed live artifacts; record-gate reruns the validator.
/bin/cp "$TMP_ROOT/artifacts/parity-result.json" "$TMP_ROOT/parity-result.valid.json"
/usr/bin/python3 - "$TMP_ROOT/artifacts/parity-result.json" "$TMP_ROOT/artifacts/artifact-validation.json" <<'PY'
import json, sys
from pathlib import Path
current = Path(sys.argv[1])
payload = json.loads(current.read_text())
payload["units"] = []
payload["totals"] = {"ok": 0, "wrong": 0, "missing": 0}
current.write_text(json.dumps(payload) + "\n")
stub = {
    "producer": "validate-ui-review-artifacts",
    "schema_version": 1,
    "session_id": "parity-test",
    "artifact_workspace": str(current.parent.resolve()),
    "stage": "all",
    "minimum_unit_count": 1,
    "status": "pass",
    "errors": [],
}
Path(sys.argv[2]).write_text(json.dumps(stub) + "\n")
PY
if run_for record-gate --name ui_parity --report "$TMP_ROOT/ui_parity.json" >/dev/null 2>&1; then
  echo "FAIL: hand-written validator pass hid malformed parity artifacts" >&2
  exit 1
fi
/bin/mv "$TMP_ROOT/parity-result.valid.json" "$TMP_ROOT/artifacts/parity-result.json"
/usr/bin/python3 "$ROOT/scripts/validate-ui-review-artifacts.py" \
  --workspace "$TMP_ROOT/artifacts" --stage all --session-id parity-test \
  --report "$TMP_ROOT/artifacts/artifact-validation.json" >/dev/null

if run_for approve-commit >/dev/null 2>&1; then
  echo "FAIL: approve-commit reached before ui_parity accepted" >&2
  exit 1
fi

# 写入人工批准 token + digest，供 ui_parity=accepted 强校验匹配（测试绕过 TTY 交互直接写 state）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/parity-test.json" "$TMP_ROOT/artifacts" <<'PY'
import hashlib, json, sys
from pathlib import Path
state_path = Path(sys.argv[1])
workspace = Path(sys.argv[2])
state = json.loads(state_path.read_text())
state["human_approval_tokens"] = {"confirm": "parity-confirm-token", "accept": "parity-accept-token"}
state["human_approved_at"] = {"confirm": "2026-08-18T00:00:00Z", "accept": "2026-08-18T00:00:01Z"}
# digest 绑定：与 parity-confirmed.json / repair-accepted.json 当前内容 sha256 一致
state["human_approval_digests"] = {
    "confirm": hashlib.sha256((workspace / "parity-confirmed.json").read_bytes()).hexdigest(),
    "accept": hashlib.sha256((workspace / "repair-accepted.json").read_bytes()).hexdigest(),
}
state_path.write_text(json.dumps(state) + "\n")
PY

run_for record-gate --name ui_parity --report "$TMP_ROOT/ui_parity.json" >/dev/null
run_for approve-commit >/dev/null

/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/parity-test.json" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
assert data["gate_results"]["ui_parity"]["status"] == "accepted"
assert data["gate_results"]["review"]["status"] == "pass"
assert data["gate_results"]["runtime"]["status"] == "runtime-verified"
assert data["commit_approved_at"] is not None
PY

# Read-only ui_review may record its bounded review result without confirm-plan, but cannot commit.
DEV_FLOW_SESSION_ID=parity-read-only \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type ui_review --task "read only" >/dev/null
DEV_FLOW_SESSION_ID=parity-read-only \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/app-launch-probe" \
  DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD=/usr/bin/true \
  DEV_FLOW_FIGMA_REST_HEALTH_CMD=/usr/bin/true \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null

/usr/bin/python3 - "$TMP_ROOT/artifacts" "$TMP_ROOT/read-only-artifacts" <<'PY'
import hashlib
import json
import shutil
import sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
shutil.copytree(source, target)
for path in target.rglob("*.json"):
    payload = json.loads(path.read_text())
    payload["session_id"] = "parity-read-only"
    if payload.get("artifact_workspace"):
        payload["artifact_workspace"] = str(target.resolve())
    path.write_text(json.dumps(payload) + "\n")
baseline = target / "parity-result.baseline.json"
current_path = target / "parity-result.json"
current = json.loads(current_path.read_text())
current["baseline_sha256"] = {
    "json": hashlib.sha256(baseline.read_bytes()).hexdigest(),
    "md": hashlib.sha256((target / "parity-result.baseline.md").read_bytes()).hexdigest(),
}
current_path.write_text(json.dumps(current) + "\n")
PY
/usr/bin/python3 "$ROOT/scripts/validate-ui-review-artifacts.py" \
  --workspace "$TMP_ROOT/read-only-artifacts" --stage parity --session-id parity-read-only \
  --report "$TMP_ROOT/read-only-artifacts/artifact-validation.json" >/dev/null

/usr/bin/python3 - "$TMP_ROOT/read-only-review.json" "$TMP_ROOT/read-only-artifacts" <<'PY'
import json, sys
from pathlib import Path
workspace = Path(sys.argv[2]).resolve()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "ui-review",
    "schema_version": 1,
    "session_id": "parity-read-only",
    "gate": "review",
    "route": "ui-review-read-only",
    "source_edits": False,
    "status": "pass",
    "reviewer_result": "pass",
    "artifact_workspace": str(workspace),
    "artifact_validation_report": str(workspace / "artifact-validation.json"),
    "evidence": "whole-page parity artifacts validated",
}) + "\n")
PY
/usr/bin/python3 - "$TMP_ROOT/read-only-review.json" "$TMP_ROOT/read-only-review-invalid.json" <<'PY'
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text())
payload.pop("artifact_workspace")
payload.pop("artifact_validation_report")
Path(sys.argv[2]).write_text(json.dumps(payload) + "\n")
PY
if DEV_FLOW_SESSION_ID=parity-read-only \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" record-gate \
  --name review --report "$TMP_ROOT/read-only-review-invalid.json" >/dev/null 2>&1; then
  echo "FAIL: read-only ui_review passed without artifact validation" >&2
  exit 1
fi
DEV_FLOW_SESSION_ID=parity-read-only \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" record-gate \
  --name review --report "$TMP_ROOT/read-only-review.json" >/dev/null
if DEV_FLOW_SESSION_ID=parity-read-only \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" approve-commit >/dev/null 2>&1; then
  echo "FAIL: read-only ui_review reached commit without confirm-plan" >&2
  exit 1
fi

echo "PASS: ui_review requires runtime/ui_parity and validates bounded human acceptance"
