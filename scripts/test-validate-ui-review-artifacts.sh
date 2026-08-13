#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT
WORKSPACE="$TMP_ROOT/artifacts"

/usr/bin/python3 - "$WORKSPACE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
(root / "structure").mkdir(parents=True)
for group in ("g1", "g2"):
    (root / "groups" / group).mkdir(parents=True)
base = {
    "producer": "ui-review",
    "schema_version": 1,
    "session_id": "validator-test",
    "artifact_workspace": str(root),
}
def write(path, payload):
    path.write_text(json.dumps(payload, indent=2) + "\n")

write(root / "manifest.json", {
    **base,
    "canonical_figma_url": "https://figma.example/file?node-id=1-1",
    "root_node_id": "1:1",
    "screen_state": "default",
})
write(root / "structure" / "screen-classification.json", {
    **base,
    "expected_base_layout": "UIScrollView",
})
write(root / "structure" / "structure-review.json", {
    **base,
    "status": "pass",
    "run_id": "structure-run-1",
    "role": "structure",
    "verdict": "pass",
    "reviewed_at": "2026-08-13T00:00:00Z",
    "summary": "structure review pass",
})
write(root / "structure" / "minimum-unit-index.json", {
    **base,
    "units": [
        {"figma_id": "1:2", "group_id": "g1", "name": "title", "unit_kind": "text"},
        {"figma_id": "1:3", "group_id": "g2", "name": "icon", "unit_kind": "image"},
    ],
})
write(root / "structure" / "structure-sweep-complete.json", {
    **base,
    "status": "pass",
    "minimum_unit_count": 2,
})
write(root / "groups" / "g1" / "detail.json", {
    **base,
    "group_id": "g1",
    "split_status": "complete",
    "minimum_units": [{
        "figma_id": "1:2",
        "group_id": "g1",
        "name": "title",
        "unit_kind": "text",
        "anchor": "figma.1_2",
        "is_minimum_unit": True,
        "asset_collapse_eligible": False,
        "has_localizable_text": True,
        "has_interaction": False,
        "split_status": "complete",
        "pending_child_ids": [],
    }],
})
write(root / "groups" / "g1" / "detail-review.json", {
    **base,
    "group_id": "g1",
    "status": "pass",
    "run_id": "detail-run-g1",
    "role": "detail",
    "verdict": "pass",
    "reviewed_at": "2026-08-13T00:00:01Z",
    "summary": "detail review pass",
})
write(root / "groups" / "g2" / "detail.json", {
    **base,
    "group_id": "g2",
    "split_status": "complete",
    "minimum_units": [{
        "figma_id": "1:3",
        "group_id": "g2",
        "name": "icon",
        "unit_kind": "image",
        "anchor": "figma.1_3",
        "is_minimum_unit": True,
        "asset_collapse_eligible": True,
        "has_localizable_text": False,
        "has_interaction": False,
        "split_status": "complete",
        "pending_child_ids": [],
    }],
})
write(root / "groups" / "g2" / "detail-review.json", {
    **base,
    "group_id": "g2",
    "status": "pass",
    "run_id": "detail-run-g2",
    "role": "detail",
    "verdict": "pass",
    "reviewed_at": "2026-08-13T00:00:02Z",
    "summary": "detail review pass",
})

text_evidence = {
    "runtime_path": "runtime/title.json",
    "expected": {
        "font_name": "Helvetica", "font_size": 16, "color_rgba": [0, 0, 0, 1],
        "origin": {"x": 10, "y": 20},
    },
    "measured": {
        "font_name": "Helvetica", "font_size": 16, "color_rgba": [0, 0, 0, 1],
        "origin": {"x": 10, "y": 20},
    },
    "tolerance": {"origin_pt": 0.5, "font_size_pt": 0.1, "color_channel": 1 / 255},
    "layout": {
        "number_of_lines": 0,
        "hardcoded_width": False,
        "hardcoded_height": False,
        "localization_safe": True,
    },
}
image_evidence = {
    "runtime_path": "runtime/icon.json",
    "figma_sha256": "a" * 64,
    "source_asset_sha256": "b" * 64,
    "runtime_asset_name": "icon",
    "expected_frame": {"x": 10, "y": 60, "width": 24, "height": 24},
    "measured_frame": {"x": 10, "y": 60, "width": 24, "height": 24},
    "tolerance": {"origin_pt": 0.5, "size_pt": 0.5},
}
unit_rows = [
    {
        "figma_id": "1:2", "unit_kind": "text", "observation_status": "observed",
        "mark": "ok", "evidence": text_evidence,
    },
    {
        "figma_id": "1:3", "unit_kind": "image", "observation_status": "observed",
        "mark": "wrong", "findings": ["asset hash mismatch"], "evidence": image_evidence,
    },
]
baseline = {
    **base,
    "units": unit_rows,
    "screen": {
        "background": {
            "observation_status": "observed", "mark": "ok",
            "evidence": {"runtime_path": "runtime/root.json", "expected": [1, 1, 1, 1], "measured": [1, 1, 1, 1]},
        },
        "base_layout": {
            "observation_status": "observed", "mark": "ok",
            "evidence": {"runtime_path": "runtime/root.json", "expected": "UIScrollView", "measured": "UIScrollView"},
        },
    },
    "runtime_extras": [],
    "totals": {"ok": 1, "wrong": 1, "missing": 0},
}
write(root / "parity-result.baseline.json", baseline)
(root / "parity-result.baseline.md").write_text("# Baseline\n")
digests = {
    "json": hashlib.sha256((root / "parity-result.baseline.json").read_bytes()).hexdigest(),
    "md": hashlib.sha256((root / "parity-result.baseline.md").read_bytes()).hexdigest(),
}
current = {
    **baseline,
    "units": [
        unit_rows[0],
        {
            **unit_rows[1],
            "mark": "ok",
            "evidence": {**image_evidence, "source_asset_sha256": "a" * 64},
        },
    ],
    "totals": {"ok": 2, "wrong": 0, "missing": 0},
    "baseline_sha256": digests,
}
write(root / "parity-result.json", current)

write(root / "parity-confirmed.json", {
    **base,
    "confirmed_by": "human",
    "may_proceed_to_fix": True,
    "units_to_fix": ["1:3"],
    "runtime_extras_to_remove": [],
})
verify_path = root / "groups" / "g2" / "repair-verify.json"
write(verify_path, {
    **base,
    "figma_id": "1:3",
    "result": "ok",
    "mark_after": "ok",
    "debugbridge_evidence": ["runtime/icon-after.json"],
})
write(root / "repair-accepted.json", {
    **base,
    "confirmed_by": "human",
    "units_accepted": ["1:3"],
    "units_rework": [],
    "units_reverted": [],
    "verification_reports": {"1:3": str(verify_path)},
    "revert_verification_reports": {},
    "all_authorized_repairs_resolved": True,
})
PY

/bin/bash "$ROOT/scripts/validate-ui-review-artifacts.sh" \
  --workspace "$WORKSPACE" --stage all --session-id validator-test >/dev/null

expect_fail() {
  local label="$1"
  local stage="${2:-all}"
  if /bin/bash "$ROOT/scripts/validate-ui-review-artifacts.sh" \
    --workspace "$WORKSPACE" --stage "$stage" --session-id validator-test >/dev/null 2>&1; then
    echo "FAIL: $label passed validation" >&2
    exit 1
  fi
}

/bin/cp "$WORKSPACE/parity-result.baseline.json" "$TMP_ROOT/baseline.valid.json"
/bin/cp "$WORKSPACE/parity-result.json" "$TMP_ROOT/current.valid.json"
/bin/cp "$WORKSPACE/parity-confirmed.json" "$TMP_ROOT/confirmed.valid.json"
/bin/cp "$WORKSPACE/repair-accepted.json" "$TMP_ROOT/accepted.valid.json"
/bin/cp "$WORKSPACE/groups/g2/repair-verify.json" "$TMP_ROOT/verify.valid.json"
/bin/cp "$WORKSPACE/groups/g1/detail-review.json" "$TMP_ROOT/detail-review-g1.valid.json"
/bin/cp "$WORKSPACE/groups/g2/detail.json" "$TMP_ROOT/detail-g2.valid.json"
/bin/cp "$WORKSPACE/structure/structure-review.json" "$TMP_ROOT/structure-review.valid.json"

# Stamped detail-review without Review MCP run_id cannot pass split.
/usr/bin/python3 - "$WORKSPACE/groups/g1/detail-review.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload.pop("run_id", None)
payload["status"] = "pass"
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "detail-review missing run_id" split
/bin/cp "$TMP_ROOT/detail-review-g1.valid.json" "$WORKSPACE/groups/g1/detail-review.json"

# Localizable-text composite collapsed as image minimum unit must fail.
/usr/bin/python3 - "$WORKSPACE/groups/g2/detail.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
unit = payload["minimum_units"][0]
unit["has_localizable_text"] = True
unit["asset_collapse_eligible"] = True
unit["unit_kind"] = "image"
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "image collapse with localizable text" split
/bin/cp "$TMP_ROOT/detail-g2.valid.json" "$WORKSPACE/groups/g2/detail.json"

# Figma dump TEXT-descendant cross-check rejects collapsed image parents.
/usr/bin/python3 - "$WORKSPACE" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
(root / "figma").mkdir(parents=True, exist_ok=True)
(root / "figma" / "root.depth4.json").write_text(json.dumps({
    "nodes": {
        "1:1": {
            "document": {
                "id": "1:1",
                "type": "FRAME",
                "children": [{
                    "id": "1:3",
                    "type": "GROUP",
                    "children": [{"id": "1:9", "type": "TEXT", "characters": "hi"}],
                }],
            }
        }
    }
}) + "\n")
PY
expect_fail "figma dump TEXT descendants under collapsed image" split
/bin/rm -rf -- "$WORKSPACE/figma"

# Structure review without MCP evidence fails split.
/usr/bin/python3 - "$WORKSPACE/structure/structure-review.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload.pop("run_id", None)
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "structure-review missing run_id" split
/bin/cp "$TMP_ROOT/structure-review.valid.json" "$WORKSPACE/structure/structure-review.json"

# Missing baseline coverage.
/usr/bin/python3 - "$WORKSPACE/parity-result.baseline.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["units"] = payload["units"][:1]
payload["totals"] = {"ok": 1, "wrong": 0, "missing": 0}
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "parity baseline with a missing unit"
/bin/cp "$TMP_ROOT/baseline.valid.json" "$WORKSPACE/parity-result.baseline.json"

# Incomplete current parity coverage.
/usr/bin/python3 - "$WORKSPACE/parity-result.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["units"] = payload["units"][:1]
payload["totals"] = {"ok": 1, "wrong": 0, "missing": 0}
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "current parity result with a missing unit"
/bin/cp "$TMP_ROOT/current.valid.json" "$WORKSPACE/parity-result.json"

# unobserved is not a parity mark.
/usr/bin/python3 - "$WORKSPACE/parity-result.baseline.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["units"][0]["observation_status"] = "unobserved"
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "unobserved parity unit"
/bin/cp "$TMP_ROOT/baseline.valid.json" "$WORKSPACE/parity-result.baseline.json"

# Empty evidence shells cannot satisfy normalized compare evidence.
/usr/bin/python3 - "$WORKSPACE/parity-result.baseline.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["units"][0]["evidence"] = {"runtime_path": "runtime/title.json"}
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "incomplete text comparison evidence"
/bin/cp "$TMP_ROOT/baseline.valid.json" "$WORKSPACE/parity-result.baseline.json"

# Authorization cannot invent an id outside baseline findings.
/usr/bin/python3 - "$WORKSPACE/parity-confirmed.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["units_to_fix"] = ["9:9"]
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "authorization outside baseline findings"
/bin/cp "$TMP_ROOT/confirmed.valid.json" "$WORKSPACE/parity-confirmed.json"

# accepted repair requires both result=ok and mark_after=ok.
/usr/bin/python3 - "$WORKSPACE/groups/g2/repair-verify.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
payload = json.loads(path.read_text())
payload["mark_after"] = "wrong"
path.write_text(json.dumps(payload) + "\n")
PY
expect_fail "accepted repair with mark_after wrong"
/bin/cp "$TMP_ROOT/verify.valid.json" "$WORKSPACE/groups/g2/repair-verify.json"

# Verified revert is a valid resolved disposition and restores the baseline mark.
/usr/bin/python3 - "$WORKSPACE" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
base = {
    "producer": "ui-review", "schema_version": 1, "session_id": "validator-test",
    "artifact_workspace": str(root),
}
current_path = root / "parity-result.json"
current = json.loads(current_path.read_text())
current["units"][1]["mark"] = "wrong"
current["totals"] = {"ok": 1, "wrong": 1, "missing": 0}
current_path.write_text(json.dumps(current) + "\n")
revert_path = root / "groups" / "g2" / "revert-verify.json"
revert_path.write_text(json.dumps({
    **base,
    "figma_id": "1:3",
    "result": "reverted",
    "mark_after": "wrong",
    "debugbridge_evidence": ["runtime/icon-reverted.json"],
}) + "\n")
accepted_path = root / "repair-accepted.json"
accepted_path.write_text(json.dumps({
    **base,
    "confirmed_by": "human",
    "units_accepted": [],
    "units_rework": [],
    "units_reverted": ["1:3"],
    "verification_reports": {},
    "revert_verification_reports": {"1:3": str(revert_path)},
    "all_authorized_repairs_resolved": True,
}) + "\n")
PY
/bin/bash "$ROOT/scripts/validate-ui-review-artifacts.sh" \
  --workspace "$WORKSPACE" --stage all --session-id validator-test >/dev/null

echo "PASS: ui-review validator enforces G2 split evidence, coverage, authorization, acceptance, and revert"
