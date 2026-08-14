#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-flow-doctor.sh [app-project-root]

Verify the central dev-flow clone and the current app project binding.
Gate scripts live only in the devflow git clone; app repos keep .dev-flow/ state only.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  export DEV_FLOW_PROJECT_ROOT="$1"
fi

dev_flow_load_paths "$SCRIPT_PATH"

required=(
  DEV_FLOW_SCRIPTS_VERSION
  dev-flow.sh
  dev-flow-init-project.sh
  resolve-dev-flow-session-id.sh
  dev-flow-session.sh
  environment-health-check.sh
  record-app-launch-report.sh
  read-app-launch-report.sh
  review-health-probe.sh
)

missing=()
for script_name in "${required[@]}"; do
  if [[ ! -f "$DEV_FLOW_SCRIPTS_DIR/$script_name" ]]; then
    missing+=("$script_name")
  fi
done

echo "App project:    $DEV_FLOW_PROJECT_ROOT"
echo "Dev-flow source: $DEV_FLOW_SOURCE_ROOT"
echo "Session state:  $DEV_FLOW_STATE_DIR"

if ((${#missing[@]} > 0)); then
  echo "Missing in dev-flow source:" >&2
  printf '  - scripts/%s\n' "${missing[@]}" >&2
  echo "Fix: git pull your devflow clone." >&2
  exit 1
fi

if [[ ! -d "$DEV_FLOW_STATE_DIR" ]]; then
  echo "Project is not initialized." >&2
  echo "Fix:" >&2
  echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow-init-project.sh\" \"$DEV_FLOW_PROJECT_ROOT\"" >&2
  exit 1
fi

if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/source-root" ]]; then
  bound_source="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/source-root")"
  if [[ "$bound_source" != "$DEV_FLOW_SOURCE_ROOT" ]]; then
    echo "WARNING: .dev-flow/source-root points elsewhere:" >&2
    echo "  bound:   $bound_source" >&2
    echo "  running: $DEV_FLOW_SOURCE_ROOT" >&2
    echo "Rebind with dev-flow-init-project.sh after git pull." >&2
    exit 1
  fi
fi

if ! /usr/bin/grep -q 'read-app-launch-report.sh' "$DEV_FLOW_SCRIPTS_DIR/environment-health-check.sh"; then
  echo "Stale dev-flow source: environment-health-check.sh is too old." >&2
  echo "Fix: git pull your devflow clone." >&2
  exit 1
fi

echo "PASS: central dev-flow source is current; app project binding is ready."
