#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
REPORT_FILE="$STATE_DIR/$SESSION_ID.app-launch.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/app-launch-preflight.sh status
  scripts/app-launch-preflight.sh instructions
  scripts/app-launch-preflight.sh template
  scripts/app-launch-preflight.sh record --report <path|->

This script owns the dev-flow App launch preflight boundary. It does not fabricate a launch
success. A real agent must first confirm the XcodeBuildMCP tools are callable, then call session_set_defaults,
session_show_defaults, and build_run_device|build_run_sim on the chosen target (build_run_device +
device_transport=wired for a wired physical device, build_run_sim + device_transport=simulator for an
iOS Simulator) with env
DEV_FLOW_SESSION_ID=<current session id>. The target is fixed once chosen; a failure must be
reported, not silently switched to the other target kind or a different device. Record the bounded
result with record --report <path|-> before running environment-health.
EOF
}

emit_missing_json() {
  /usr/bin/python3 - "$SESSION_ID" "$REPORT_FILE" <<'PY'
import json
import sys

session_id, report_file = sys.argv[1], sys.argv[2]
print(json.dumps({
    "status": "blocked",
    "evidence": "app_launch_report_missing;run_xcodebuildmcp_session_set_defaults_then_show_defaults_then_build_run_device_or_build_run_sim",
    "session_id": session_id,
    "expected_report": report_file,
    "required_tools": ["session_set_defaults", "session_show_defaults", "build_run_device|build_run_sim"],
    "record_command": "bash scripts/dev-flow.sh app-launch record --report <path|->",
}, ensure_ascii=False))
PY
}

validate_and_cat_report() {
  if [[ ! -f "$REPORT_FILE" ]]; then
    emit_missing_json
    return 1
  fi
  /usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]

try:
    payload = json.loads(report_path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({
        "status": "blocked",
        "evidence": f"app_launch_report_invalid_json:{exc}",
        "session_id": session_id,
        "expected_report": str(report_path),
    }, ensure_ascii=False))
    raise SystemExit(1)

def non_placeholder(value):
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value.strip().lower() not in {"unknown", "n/a", "-", ""}
    )

required = {
    "producer": "XcodeBuildMCP",
    "schema_version": 2,
    "session_id": session_id,
    "status": "available",
    "build_run_result": "success",
    "app_launched": True,
}
errors = []
for key, expected in required.items():
    if payload.get(key) != expected:
        errors.append(key)
# build_run_action 必须是真实 XcodeBuildMCP 动作之一；
# device_transport 必须与 action 交叉一致（不可伪造 simulator 为 build_run_device）。
action = payload.get("build_run_action")
if action not in ("build_run_device", "build_run_sim"):
    errors.append("build_run_action")
else:
    expected_transport = "wired" if action == "build_run_device" else "simulator"
    if payload.get("device_transport") != expected_transport:
        errors.append("device_transport")
for key in ("build_id", "device_id"):
    if not non_placeholder(payload.get(key)):
        errors.append(key)
if errors:
    print(json.dumps({
        "status": "blocked",
        "evidence": "app_launch_report_invalid_fields:" + ",".join(errors),
        "session_id": session_id,
        "expected_report": str(report_path),
    }, ensure_ascii=False))
    raise SystemExit(1)

print(json.dumps(payload, ensure_ascii=False))
PY
}

print_instructions() {
  cat <<EOF
App launch preflight for dev-flow session: $SESSION_ID

Required order:
  1. Confirm session_set_defaults / session_show_defaults / build_run_device|build_run_sim are callable
  2. XcodeBuildMCP session_set_defaults profile=$SESSION_ID createIfNotExists=true with
     workspacePath (.xcworkspace for CocoaPods), scheme, configuration, platform, and the
     explicit deviceId (physical UDID) or simulatorId (Simulator id) chosen for this session
  3. XcodeBuildMCP session_show_defaults to verify the active profile fields
  4. XcodeBuildMCP build_run_device (wired) or build_run_sim (Simulator) with env DEV_FLOW_SESSION_ID=$SESSION_ID on the chosen target
  5. Save a bounded JSON report, then run:
     bash "$(dev_flow_script_path dev-flow.sh)" app-launch record --report <path|->
  6. Run:
     bash "$(dev_flow_script_path dev-flow.sh)" environment-health run

Required report fields:
  producer=XcodeBuildMCP
  schema_version=2
  session_id=$SESSION_ID
  status=available
  build_run_action=build_run_device|build_run_sim (reflects the actual target used)
  build_run_result=success
  device_transport=wired|simulator (must cross-match: build_run_device↔wired, build_run_sim↔simulator)
  app_launched=true
  build_id=<real non-placeholder build id>
  device_id=<real non-placeholder device id (physical UDID or Simulator id)>
EOF
}

print_template() {
  local target="${1:-}"
  /usr/bin/python3 - "$SESSION_ID" "$target" <<'PY'
import json
import sys

session_id = sys.argv[1]
target = sys.argv[2] if len(sys.argv) > 2 else ""
# 目标由 resolver 的 launch_action 驱动（build_run_device→physical/wired，
# build_run_sim→simulator/simulator）；缺失报告不知道目标时默认 physical。
if target == "simulator":
    template = {
        "producer": "XcodeBuildMCP",
        "schema_version": 2,
        "session_id": session_id,
        "status": "available",
        "build_run_action": "build_run_sim",
        "build_run_result": "success",
        "device_transport": "simulator",
        "app_launched": True,
        "build_id": "<real-build-id-from-XcodeBuildMCP>",
        "device_id": "<simulator-id>",
    }
else:
    template = {
        "producer": "XcodeBuildMCP",
        "schema_version": 2,
        "session_id": session_id,
        "status": "available",
        "build_run_action": "build_run_device",
        "build_run_result": "success",
        "device_transport": "wired",
        "app_launched": True,
        "build_id": "<real-build-id-from-XcodeBuildMCP>",
        "device_id": "<physical-udid>",
    }
print(json.dumps(template, ensure_ascii=False, indent=2))
PY
}

cmd="${1:-}"
case "$cmd" in
  status)
    validate_and_cat_report
    ;;
  instructions)
    print_instructions
    ;;
  template)
    shift
    target=""
    target_provided=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          if [[ $# -lt 2 ]]; then
            echo "FAIL: --target requires a value (physical|simulator)" >&2
            exit 2
          fi
          target="$2"; target_provided=1; shift 2
          ;;
        -h|--help) echo "Usage: app-launch template [--target physical|simulator]"; exit 0 ;;
        *) echo "Unknown template argument: $1" >&2; exit 2 ;;
      esac
    done
    # 区分未提供 --target（默认 physical 兼容）与显式空值（非法，exit 2）
    if [[ "$target_provided" -eq 1 && -z "$target" ]]; then
      echo "FAIL: --target requires a value (physical|simulator)" >&2
      exit 2
    fi
    case "$target" in
      ""|physical|simulator) ;;
      *) echo "FAIL: invalid --target value: $target (must be physical|simulator)" >&2; exit 2 ;;
    esac
    print_template "$target"
    ;;
  record)
    shift
    exec bash "$(dev_flow_script_path record-app-launch-report.sh)" record "$@"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown app-launch command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
