#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-skills-common.sh
source "$ROOT/scripts/link-skills-common.sh"

if [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
  SKILLS_ROOT="$CODEX_SKILLS_ROOT"
elif [[ -n "${CODEX_HOME:-}" ]]; then
  SKILLS_ROOT="$CODEX_HOME/skills"
else
  SKILLS_ROOT="$HOME/.codex/skills"
fi

link_skills_devflow_package "$ROOT" "$SKILLS_ROOT"
linked_count="$(link_skills_tree "$ROOT" "$SKILLS_ROOT")"

echo "Linked dev-flow package and ${linked_count} skills under $SKILLS_ROOT"
echo "Source of truth: $ROOT"
echo "Also run link-project-scripts.sh for each iOS app repo (skills alone do not update app scripts/)."
