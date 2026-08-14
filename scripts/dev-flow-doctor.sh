#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-flow-doctor.sh [project-root]

Validate that the current iOS project has the dev-flow scripts required by the
installed skills. Run from the app repo root, or pass the project path explicitly.

Checks:
  - core gate scripts exist
  - environment-health-check supports session app-launch + review fallback probes
  - optional: scripts are symlinks back to the devflow clone
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
  PROJECT_ROOT="$(cd "$1" && pwd)"
else
  PROJECT_ROOT="$(pwd)"
fi

SCRIPTS_DIR="$PROJECT_ROOT/scripts"
EXPECTED_VERSION=""
if [[ -f "$SCRIPTS_DIR/DEV_FLOW_SCRIPTS_VERSION" ]]; then
  EXPECTED_VERSION="$(tr -d '[:space:]' < "$SCRIPTS_DIR/DEV_FLOW_SCRIPTS_VERSION")"
fi

required=(
  resolve-dev-flow-session-id.sh
  dev-flow-session.sh
  environment-health-check.sh
  record-app-launch-report.sh
  read-app-launch-report.sh
  review-health-probe.sh
)

missing=()
stale=()
for script_name in "${required[@]}"; do
  target="$SCRIPTS_DIR/$script_name"
  if [[ ! -f "$target" ]]; then
    missing+=("$script_name")
    continue
  fi
  if [[ "$script_name" == "environment-health-check.sh" ]]; then
    if ! /usr/bin/grep -q 'review-health-probe.sh' "$target"; then
      stale+=("environment-health-check.sh (missing review-health-probe default)")
    fi
    if ! /usr/bin/grep -q 'read-app-launch-report.sh' "$target"; then
      stale+=("environment-health-check.sh (missing session app-launch adapter)")
    fi
  fi
done

echo "Project: $PROJECT_ROOT"
if [[ -n "$EXPECTED_VERSION" ]]; then
  echo "Installed scripts version: $EXPECTED_VERSION"
else
  echo "Installed scripts version: unknown (missing scripts/DEV_FLOW_SCRIPTS_VERSION)"
  stale+=("DEV_FLOW_SCRIPTS_VERSION")
fi

if ((${#missing[@]} > 0)); then
  echo "Missing scripts:"
  printf '  - %s\n' "${missing[@]}"
fi
if ((${#stale[@]} > 0)); then
  echo "Stale or incomplete scripts:"
  printf '  - %s\n' "${stale[@]}"
fi

if ((${#missing[@]} == 0 && ${#stale[@]} == 0)); then
  echo "PASS: dev-flow project scripts are present and current."
  exit 0
fi

echo
echo "Fix: update your devflow clone, then run:"
echo "  bash /path/to/devflow/scripts/link-project-scripts.sh \"$PROJECT_ROOT\""
exit 1
