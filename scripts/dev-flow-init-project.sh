#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-flow-init-project.sh [app-project-root]

Register an iOS app repo with the central dev-flow clone. Creates only:
  <app>/.dev-flow/source-root
  <app>/.dev-flow/sessions/

Gate scripts stay in the dev-flow git clone. App repos do NOT get a scripts/ copy.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  export DEV_FLOW_PROJECT_ROOT="$1"
fi

dev_flow_load_paths "$SCRIPT_PATH"

PROJECT_ROOT="$DEV_FLOW_PROJECT_ROOT"
STATE_DIR="$PROJECT_ROOT/.dev-flow"
SOURCE_FILE="$STATE_DIR/source-root"

mkdir -p "$STATE_DIR/sessions"
printf '%s\n' "$DEV_FLOW_SOURCE_ROOT" >"$SOURCE_FILE"

echo "Initialized dev-flow project binding:"
echo "  app:    $PROJECT_ROOT"
echo "  source: $DEV_FLOW_SOURCE_ROOT"
echo
echo "Run gates from the app repo with:"
echo "  cd \"$PROJECT_ROOT\""
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" doctor"
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" record-app-launch record"
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" environment-health run"
