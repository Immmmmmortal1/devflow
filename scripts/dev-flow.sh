#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/dev-flow.sh [--project <app-root>] <command> [args...]

Commands:
  init [app-root]                 Bind an app repo to this dev-flow clone
  doctor [app-root]               Verify source + project binding
  session ...                     dev-flow-session.sh ...
  environment-health run          environment-health-check.sh run
  record-app-launch record [...]  record-app-launch-report.sh record [...]

Gate scripts always run from the dev-flow clone. Session state lives in the app repo
under .dev-flow/sessions/. Run commands from the app root or pass --project.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      export DEV_FLOW_PROJECT_ROOT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

dev_flow_load_paths "$SCRIPT_PATH"

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  init)
    exec bash "$(dev_flow_script_path dev-flow-init-project.sh)" "$@"
    ;;
  doctor)
    exec bash "$(dev_flow_script_path dev-flow-doctor.sh)" "$@"
    ;;
  session)
    exec bash "$(dev_flow_script_path dev-flow-session.sh)" "$@"
    ;;
  environment-health)
    exec bash "$(dev_flow_script_path environment-health-check.sh)" "$@"
    ;;
  record-app-launch)
    exec bash "$(dev_flow_script_path record-app-launch-report.sh)" "$@"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
