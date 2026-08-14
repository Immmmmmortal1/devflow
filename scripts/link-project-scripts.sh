#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-project-scripts-common.sh
source "$ROOT/scripts/link-project-scripts-common.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/link-project-scripts.sh <target-project-root>

Symlink dev-flow gate scripts into the target iOS project's scripts/ directory.
Skills install (link-global-skills.sh / link-cursor-skills.sh) does NOT copy these
scripts; each app repo must run this step after cloning or updating devflow.

Example:
  bash /path/to/devflow/scripts/link-project-scripts.sh ~/iOSworkspace/KakaPic
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$1" && pwd)"
linked_count="$(link_project_scripts_tree "$ROOT" "$PROJECT_ROOT")"

echo "Linked ${linked_count} dev-flow scripts into $PROJECT_ROOT/scripts"
echo "Source of truth: $ROOT"
echo "Next: bash scripts/dev-flow-doctor.sh (from the target project root)"
