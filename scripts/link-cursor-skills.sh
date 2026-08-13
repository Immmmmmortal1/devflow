#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-skills-common.sh
source "$ROOT/scripts/link-skills-common.sh"

if [[ -n "${CURSOR_SKILLS_ROOT:-}" ]]; then
  SKILLS_ROOT="$CURSOR_SKILLS_ROOT"
else
  SKILLS_ROOT="$HOME/.cursor/skills"
fi

link_skills_devflow_package "$ROOT" "$SKILLS_ROOT"
linked_count="$(link_skills_tree "$ROOT" "$SKILLS_ROOT")"

echo "Linked dev-flow package and ${linked_count} skills under $SKILLS_ROOT"
echo "Source of truth: $ROOT"
