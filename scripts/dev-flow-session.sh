#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$ROOT/scripts/resolve-dev-flow-session-id.sh"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
STATE_DIR="$ROOT/.dev-flow/sessions"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/dev-flow-session.sh start --type bug|feature|ui_review [--task "label"]
  scripts/dev-flow-session.sh configure-gates --required <comma-separated gates>
  scripts/dev-flow-session.sh environment-health --report <path>
  scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime|ui_parity --report <path>
  scripts/dev-flow-session.sh confirm-plan [--task "label"]
  scripts/dev-flow-session.sh approve-commit [--task "label"]
  scripts/dev-flow-session.sh end
  scripts/dev-flow-session.sh status

Session selection:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, then CURSOR_CONVERSATION_ID.
  Outside Cursor, falls back to "local". Inside Cursor, a missing conversation id is an error.
Gate note:
  ui_review source repair requires review,runtime,ui_parity before confirm-plan.
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_common_args() {
  SESSION_TYPE=""
  TASK=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        SESSION_TYPE="${2:-}"
        shift 2
        ;;
      --task)
        TASK="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

write_state() {
  local action="$1"
  local session_type="${2:-}"
  local task="${3:-}"
  local required_gates="${4:-}"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$action" "$session_type" "$task" "$required_gates" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
session_id = sys.argv[2]
action = sys.argv[3]
session_type = sys.argv[4]
task = sys.argv[5]
required_gates_arg = sys.argv[6]
timestamp = sys.argv[7]

all_gates = ("figma_ui", "review", "runtime", "ui_parity")
required_gates = [item for item in required_gates_arg.split(",") if item]
if action == "start" and not required_gates:
    required_gates = ["review"]
if any(item not in all_gates for item in required_gates):
    raise SystemExit("Unknown gate. Use figma_ui, review, runtime, or ui_parity.")
if action in ("start", "configure-gates") and "review" not in required_gates:
    raise SystemExit("The review gate is required for every dev-flow commit session.")
if len(set(required_gates)) != len(required_gates):
    raise SystemExit("Duplicate required gate.")

default_gate_results = {
    "figma_ui": {"status": "not-required", "evidence": None, "recorded_at": None},
    "review": {"status": "pending", "evidence": None, "recorded_at": None},
    "runtime": {"status": "not-required", "evidence": None, "recorded_at": None},
    "ui_parity": {"status": "not-required", "evidence": None, "recorded_at": None},
}

def make_gate_results(required):
    results = json.loads(json.dumps(default_gate_results))
    for gate in required:
        results[gate]["status"] = "pending"
    return results

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        data = {}

if action == "start":
    data = {
        "session_id": session_id,
        "active": True,
        "type": session_type,
        "task": task,
        "started_at": timestamp,
        "confirmed_at": None,
        "commit_approved_at": None,
        "ended_at": None,
        "required_gates": required_gates,
        "gate_results": make_gate_results(required_gates),
        "environment_health": {
            "status": "not-run",
            "checked_at": None,
            "checks": {},
        },
    }
elif action == "configure-gates":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("confirmed_at"):
        raise SystemExit("Required gates cannot change after plan confirmation.")
    data["required_gates"] = required_gates
    data["gate_results"] = make_gate_results(required_gates)
    data["session_id"] = session_id
elif action == "confirm-plan":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    if data.get("type") == "ui_review":
        required = set(data.get("required_gates", []))
        missing = {"review", "runtime", "ui_parity"} - required
        if missing:
            raise SystemExit(
                "ui_review source repair requires gates configured before confirm-plan: "
                + ",".join(sorted(missing))
            )
    data["confirmed_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "approve-commit":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    if not data.get("confirmed_at"):
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
    required = data.get("required_gates", ["review"])
    results = data.get("gate_results", {})
    expected = {
        "figma_ui": "pass",
        "review": "pass",
        "runtime": "runtime-verified",
        "ui_parity": "accepted",
    }
    blocked = []
    for gate in required:
        actual = results.get(gate, {}).get("status")
        if actual != expected[gate]:
            blocked.append(f"{gate}={actual or 'missing'} (requires {expected[gate]})")
    if blocked:
        raise SystemExit("Required gate(s) unresolved: " + ", ".join(blocked))
    data["commit_approved_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "end":
    if not data:
        data = {"session_id": session_id, "active": False}
    data["session_id"] = session_id
    data["active"] = False
    data["ended_at"] = timestamp
else:
    raise SystemExit(f"Unsupported action: {action}")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(path)
PY
}

record_environment() {
  local report_file="$1"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$report_file" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
report_path = Path(sys.argv[3])
checked_at = sys.argv[4]

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
report = json.loads(report_path.read_text())
if report.get("producer") != "environment-health-check" or report.get("schema_version") != 1:
    raise SystemExit("Environment report was not produced by environment-health-check.")
if report.get("session_id") != session_id:
    raise SystemExit("Environment report belongs to another session.")
checks = report.get("checks")
required = ("app_launch", "debugbridge", "review_mcp", "figma_rest_api")
if not isinstance(checks, dict) or any(name not in checks for name in required):
    raise SystemExit("Environment report is missing required checks.")
if any(checks[name].get("status") not in ("available", "blocked", "not-run") for name in required):
    raise SystemExit("Environment report contains an invalid check status.")
derived_status = "available" if all(checks[name].get("status") == "available" for name in required) else "blocked"
if report.get("status") != derived_status:
    raise SystemExit("Environment report status does not match its checks.")
state["environment_health"] = {
    "status": derived_status,
    "checked_at": checked_at,
    "checks": checks,
}
state["session_id"] = session_id
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
print(state_path)
if derived_status != "available":
    raise SystemExit(1)
PY
}

record_gate() {
  local gate_name="$1"
  local report_file="$2"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$gate_name" "$report_file" "$(now_utc)" "$ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
gate_name = sys.argv[3]
report_path = Path(sys.argv[4])
recorded_at = sys.argv[5]
devflow_root = Path(sys.argv[6]).resolve()

if gate_name not in ("figma_ui", "review", "runtime", "ui_parity"):
    raise SystemExit("Unknown gate. Use figma_ui, review, runtime, or ui_parity.")
if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
if not state.get("confirmed_at"):
    read_only_review = (
        state.get("type") == "ui_review"
        and gate_name == "review"
    )
    if not read_only_review:
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
if gate_name not in state.get("required_gates", []):
    raise SystemExit(f"Gate is not required for this session: {gate_name}")
if not report_path.is_file():
    raise SystemExit("Gate report does not exist.")

report = json.loads(report_path.read_text())
if report.get("session_id") != session_id:
    raise SystemExit("Gate report belongs to another session.")
if report.get("gate") != gate_name:
    raise SystemExit("Gate report name does not match --name.")

status = report.get("status")
allowed = {
    "figma_ui": {"pass", "failed", "blocked"},
    "review": {"pass", "revise", "blocked", "failed", "unknown"},
    "runtime": {"runtime-verified", "runtime-failed", "runtime-blocked"},
    "ui_parity": {"accepted", "findings-open", "blocked"},
}
if status not in allowed[gate_name]:
    raise SystemExit(f"Invalid {gate_name} status: {status}")

def run_ui_review_validator(artifact_workspace, stage):
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit(f"ui_review {gate_name} report requires artifact_workspace.")
    workspace = Path(artifact_workspace).expanduser().resolve()
    validator = devflow_root / "scripts" / "validate-ui-review-artifacts.py"
    if not workspace.is_dir() or not validator.is_file():
        raise SystemExit("ui_review artifact workspace or validator is missing.")
    completed = subprocess.run(
        [
            "/usr/bin/python3",
            str(validator),
            "--workspace",
            str(workspace),
            "--stage",
            stage,
            "--session-id",
            session_id,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ui_review validator returned invalid output: {exc}") from exc
    if completed.returncode != 0 or payload.get("status") != "pass":
        errors = payload.get("errors") or ["validator execution failed"]
        raise SystemExit("ui_review artifact validation failed: " + "; ".join(errors))
    return workspace, payload

if not state.get("confirmed_at"):
    if not (
        report.get("producer") == "ui-review"
        and report.get("schema_version") == 1
        and report.get("route") == "ui-review-read-only"
        and report.get("source_edits") is False
        and status == "pass"
    ):
        raise SystemExit(
            "Unconfirmed ui_review may record only a ui-review-read-only pass with source_edits=false."
        )
    workspace_path, _ = run_ui_review_validator(report.get("artifact_workspace"), "parity")
    validation_report = report.get("artifact_validation_report")
    if not isinstance(validation_report, str) or not validation_report.strip():
        raise SystemExit("Read-only ui_review requires artifact_validation_report.")
    validation_path = Path(validation_report).expanduser().resolve()
    try:
        validation_path.relative_to(workspace_path)
    except ValueError:
        raise SystemExit("Read-only artifact_validation_report must be inside artifact_workspace.")
    if not validation_path.is_file():
        raise SystemExit("Read-only artifact_validation_report does not exist.")

if (
    gate_name == "review"
    and status == "pass"
    and state.get("type") == "ui_review"
    and state.get("confirmed_at")
):
    if not (
        report.get("producer") == "code-review-workflow"
        and report.get("schema_version") == 1
        and report.get("route") == "ui-parity-review"
        and report.get("source_edits") is True
        and report.get("reviewer_result") == "pass"
        and isinstance(report.get("run_id"), str)
        and report.get("run_id").strip()
        and isinstance(report.get("diff_evidence"), str)
        and report.get("diff_evidence").strip()
    ):
        raise SystemExit(
            "Repaired ui_review review=pass requires a passing ui-parity-review result with run id and diff evidence."
        )
    review_workspace, _ = run_ui_review_validator(report.get("artifact_workspace"), "repair")
    expected_review_paths = {
        "baseline_report": review_workspace / "parity-result.baseline.json",
        "parity_confirmed_report": review_workspace / "parity-confirmed.json",
        "repair_accepted_report": review_workspace / "repair-accepted.json",
    }
    for field, expected_path in expected_review_paths.items():
        raw = report.get(field)
        if not isinstance(raw, str) or not raw.strip():
            raise SystemExit(f"ui-parity-review report requires {field}.")
        candidate = Path(raw).expanduser().resolve()
        try:
            candidate.relative_to(review_workspace)
        except ValueError:
            raise SystemExit(f"{field} must be inside artifact_workspace.")
        if not candidate.is_file():
            raise SystemExit(f"{field} does not exist.")
        if candidate != expected_path:
            raise SystemExit(f"{field} does not point to the canonical ui-review artifact.")

if gate_name == "runtime" and status == "runtime-verified" and state.get("type") == "ui_review":
    if report.get("producer") != "runtime-debug-workflow" or report.get("schema_version") != 1:
        raise SystemExit(
            "ui_review runtime-verified requires producer=runtime-debug-workflow and schema_version=1."
        )
    runtime_workspace_raw = report.get("artifact_workspace")
    if not isinstance(runtime_workspace_raw, str) or not runtime_workspace_raw.strip():
        raise SystemExit("ui_review runtime-verified requires artifact_workspace.")
    runtime_workspace = Path(runtime_workspace_raw).expanduser().resolve()
    confirmed_report = report.get("parity_confirmed_report")
    if not isinstance(confirmed_report, str) or not confirmed_report.strip():
        raise SystemExit("ui_review runtime-verified requires parity_confirmed_report.")
    confirmed_path = Path(confirmed_report).expanduser().resolve()
    if not confirmed_path.is_file() or confirmed_path != runtime_workspace / "parity-confirmed.json":
        raise SystemExit("ui_review runtime parity_confirmed_report does not exist.")
    confirmed_payload = json.loads(confirmed_path.read_text())
    if confirmed_payload.get("session_id") != session_id:
        raise SystemExit("ui_review runtime parity_confirmed_report belongs to another session.")
    if confirmed_payload.get("artifact_workspace") != str(runtime_workspace):
        raise SystemExit("ui_review runtime artifact workspace mismatch.")

    def runtime_ids(value, field):
        if not isinstance(value, list):
            raise SystemExit(f"{field} must be an array.")
        result = set()
        for item in value:
            current = item if isinstance(item, str) else item.get("figma_id") if isinstance(item, dict) else None
            if not isinstance(current, str) or not current.strip() or current in result:
                raise SystemExit(f"{field} contains an invalid or duplicate id.")
            result.add(current)
        return result

    authorized_ids = runtime_ids(confirmed_payload.get("units_to_fix", []), "units_to_fix")
    authorized_ids |= runtime_ids(
        confirmed_payload.get("runtime_extras_to_remove", []), "runtime_extras_to_remove"
    )
    verified_ids = runtime_ids(report.get("verified_ids", []), "verified_ids")
    if not authorized_ids or verified_ids != authorized_ids:
        raise SystemExit("ui_review runtime verified_ids must equal the authorized repair set.")
    evidence_paths = report.get("debugbridge_evidence")
    if not isinstance(evidence_paths, list) or not evidence_paths or any(
        not isinstance(item, str) or not item.strip() for item in evidence_paths
    ):
        raise SystemExit("ui_review runtime-verified requires bounded DebugBridge evidence paths.")

if gate_name == "ui_parity" and status == "accepted":
    if report.get("producer") != "ui-review" or report.get("schema_version") != 1:
        raise SystemExit("ui_parity=accepted requires producer=ui-review and schema_version=1.")
    artifact_workspace = report.get("artifact_workspace")
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit("ui_parity=accepted requires artifact_workspace.")
    workspace_path = Path(artifact_workspace).expanduser().resolve()
    if not workspace_path.is_dir():
        raise SystemExit("ui_parity artifact_workspace must exist.")
    _, fresh_validation = run_ui_review_validator(artifact_workspace, "all")

    def bounded_report_path(raw, field):
        if not isinstance(raw, str) or not raw.strip():
            raise SystemExit(f"ui_parity=accepted requires {field} path.")
        candidate = Path(raw).expanduser().resolve()
        try:
            candidate.relative_to(workspace_path)
        except ValueError:
            raise SystemExit(f"{field} must be inside artifact_workspace.")
        if not candidate.is_file():
            raise SystemExit(f"{field} file does not exist.")
        return candidate

    confirmed_path = bounded_report_path(
        report.get("parity_confirmed_report"), "parity_confirmed_report"
    )
    validation_path = bounded_report_path(
        report.get("artifact_validation_report"), "artifact_validation_report"
    )
    accepted_report = report.get("repair_accepted_report")
    accepted_path = bounded_report_path(accepted_report, "repair_accepted_report")
    if confirmed_path != workspace_path / "parity-confirmed.json":
        raise SystemExit("parity_confirmed_report must point to canonical parity-confirmed.json.")
    if accepted_path != workspace_path / "repair-accepted.json":
        raise SystemExit("repair_accepted_report must point to canonical repair-accepted.json.")
    try:
        validation_payload = json.loads(validation_path.read_text())
        confirmed_payload = json.loads(confirmed_path.read_text())
        accepted_payload = json.loads(accepted_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid ui_parity evidence JSON: {exc}") from exc
    if confirmed_payload.get("session_id") != session_id:
        raise SystemExit("parity_confirmed_report belongs to another session.")
    if not (
        validation_payload.get("producer") == "validate-ui-review-artifacts"
        and validation_payload.get("schema_version") == 1
        and validation_payload.get("session_id") == session_id
        and validation_payload.get("artifact_workspace") == artifact_workspace
        and validation_payload.get("stage") == "all"
        and validation_payload.get("status") == "pass"
        and validation_payload.get("errors") == []
        and validation_payload.get("minimum_unit_count")
        == fresh_validation.get("minimum_unit_count")
    ):
        raise SystemExit("ui_parity requires a passing current-session all-stage artifact validation.")
    if accepted_payload.get("session_id") != session_id:
        raise SystemExit("repair_accepted_report belongs to another session.")
    if confirmed_payload.get("artifact_workspace") != artifact_workspace:
        raise SystemExit("parity_confirmed_report artifact_workspace mismatch.")
    if accepted_payload.get("artifact_workspace") != artifact_workspace:
        raise SystemExit("repair_accepted_report artifact_workspace mismatch.")
    if confirmed_payload.get("may_proceed_to_fix") is not True:
        raise SystemExit("parity_confirmed_report must set may_proceed_to_fix=true.")
    if accepted_payload.get("confirmed_by") != "human":
        raise SystemExit("repair_accepted_report requires confirmed_by=human.")
    if accepted_payload.get("all_authorized_repairs_resolved") is not True:
        raise SystemExit(
            "ui_parity=accepted requires all_authorized_repairs_resolved=true in repair_accepted_report."
        )

    def id_set(value, field):
        if not isinstance(value, list):
            raise SystemExit(f"{field} must be an array.")
        result = set()
        for item in value:
            current = item if isinstance(item, str) else item.get("figma_id") if isinstance(item, dict) else None
            if not isinstance(current, str) or not current.strip() or current in result:
                raise SystemExit(f"{field} contains an invalid or duplicate id.")
            result.add(current)
        return result

    authorized = id_set(confirmed_payload.get("units_to_fix", []), "units_to_fix")
    authorized |= id_set(
        confirmed_payload.get("runtime_extras_to_remove", []), "runtime_extras_to_remove"
    )
    accepted = id_set(accepted_payload.get("units_accepted", []), "units_accepted")
    reverted = id_set(accepted_payload.get("units_reverted", []), "units_reverted")
    rework = id_set(accepted_payload.get("units_rework", []), "units_rework")
    if not authorized:
        raise SystemExit("ui_parity=accepted requires a non-empty authorized repair set.")
    if accepted & reverted or rework:
        raise SystemExit("ui_parity=accepted requires disjoint accepted/reverted ids and no rework.")
    if accepted | reverted != authorized:
        raise SystemExit("Accepted plus reverted ids must exactly equal the authorized repair set.")

    def validate_verification_map(field, ids, expected_result):
        mapping = accepted_payload.get(field)
        if not isinstance(mapping, dict) or set(mapping) != ids:
            raise SystemExit(f"{field} keys must exactly match their disposition ids.")
        for item_id, raw_path in mapping.items():
            verify_path = bounded_report_path(raw_path, f"{field}[{item_id}]")
            try:
                payload = json.loads(verify_path.read_text())
            except json.JSONDecodeError as exc:
                raise SystemExit(f"Invalid verification JSON for {item_id}: {exc}") from exc
            if payload.get("session_id") != session_id or payload.get("figma_id") != item_id:
                raise SystemExit(f"Verification report identity mismatch for {item_id}.")
            if payload.get("result") != expected_result:
                raise SystemExit(f"Verification report result mismatch for {item_id}.")
            if expected_result == "ok" and payload.get("mark_after") != "ok":
                raise SystemExit(f"Accepted repair must have mark_after=ok for {item_id}.")
            if not payload.get("debugbridge_evidence"):
                raise SystemExit(f"Verification report lacks DebugBridge evidence for {item_id}.")

    validate_verification_map("verification_reports", accepted, "ok")
    validate_verification_map("revert_verification_reports", reverted, "reverted")

if gate_name == "figma_ui" and status == "pass":
    gates = report.get("gates")
    expected = [f"G{i}" for i in range(13)]
    if not isinstance(gates, dict) or any(gates.get(name) != "pass" for name in expected):
        raise SystemExit("figma_ui=pass requires G0 through G12 all to be pass.")
    artifact_workspace = report.get("artifact_workspace")
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit("figma_ui=pass requires artifact_workspace.")
    source_root = report.get("source_root")
    if not isinstance(source_root, str) or not source_root.strip():
        raise SystemExit("figma_ui=pass requires source_root.")
    g6_validation = report.get("g6_validation")
    if g6_validation != "pass":
        raise SystemExit("figma_ui=pass requires g6_validation=pass.")
    g6_report = report.get("g6_validation_report")
    if not isinstance(g6_report, str) or not g6_report.strip():
        raise SystemExit("figma_ui=pass requires g6_validation_report path.")
    g6_report_path = Path(g6_report).expanduser()
    if not g6_report_path.is_file():
        raise SystemExit("figma_ui=pass requires an existing g6_validation_report file.")
    try:
        g6_payload = json.loads(g6_report_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid g6_validation_report JSON: {exc}") from exc
    if g6_payload.get("status") != "pass":
        raise SystemExit("figma_ui=pass requires g6_validation_report status=pass.")

evidence = report.get("evidence")
if not isinstance(evidence, str) or not evidence.strip():
    raise SystemExit("Gate report requires bounded evidence text.")
state.setdefault("gate_results", {})[gate_name] = {
    "status": status,
    "evidence": evidence[:1000],
    "recorded_at": recorded_at,
    "report": str(report_path),
}
state["session_id"] = session_id
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
print(state_path)
PY
}

parse_environment_args() {
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report)
        REPORT_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "environment-health requires an existing --report path" >&2
    exit 2
  fi
}

parse_gate_config_args() {
  REQUIRED_GATES=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --required)
        REQUIRED_GATES="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$REQUIRED_GATES" ]]; then
    echo "configure-gates requires --required" >&2
    exit 2
  fi
}

parse_gate_record_args() {
  GATE_NAME=""
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        GATE_NAME="${2:-}"
        shift 2
        ;;
      --report)
        REPORT_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$GATE_NAME" || -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "record-gate requires --name and an existing --report path" >&2
    exit 2
  fi
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  start)
    parse_common_args "$@"
    if [[ "$SESSION_TYPE" != "bug" && "$SESSION_TYPE" != "feature" && "$SESSION_TYPE" != "ui_review" ]]; then
      echo "start requires --type bug|feature|ui_review" >&2
      exit 2
    fi
    rm -f "$STATE_DIR/$SESSION_ID.app-launch.json"
    write_state "start" "$SESSION_TYPE" "$TASK" "review"
    ;;
  configure-gates)
    parse_gate_config_args "$@"
    write_state "configure-gates" "" "" "$REQUIRED_GATES"
    ;;
  environment-health)
    parse_environment_args "$@"
    record_environment "$REPORT_FILE"
    ;;
  record-gate)
    parse_gate_record_args "$@"
    record_gate "$GATE_NAME" "$REPORT_FILE"
    ;;
  confirm-plan)
    parse_common_args "$@"
    write_state "confirm-plan" "" "$TASK"
    ;;
  approve-commit)
    parse_common_args "$@"
    write_state "approve-commit" "" "$TASK"
    ;;
  end)
    write_state "end" "" ""
    ;;
  status)
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "No dev-flow session."
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
