#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
  GLOBAL_SKILLS_ROOT="$CODEX_SKILLS_ROOT"
elif [[ -n "${CODEX_HOME:-}" ]]; then
  GLOBAL_SKILLS_ROOT="$CODEX_HOME/skills"
else
  GLOBAL_SKILLS_ROOT="$HOME/.codex/skills"
fi

SKILLS=(
  feature-workflow
  bug-workflow
  code-grounded
  confirm-gate
  commit-gate
)

for skill in "${SKILLS[@]}"; do
  source_file="$ROOT/skills/$skill/SKILL.md"
  global_dir="$GLOBAL_SKILLS_ROOT/$skill"
  global_file="$global_dir/SKILL.md"

  if [[ ! -f "$source_file" ]]; then
    echo "Missing repository skill: $source_file" >&2
    exit 1
  fi

  mkdir -p "$global_dir"

  if [[ -L "$global_file" ]]; then
    current_target="$(readlink "$global_file")"
    if [[ "$current_target" == "$source_file" ]]; then
      continue
    fi
    /usr/bin/trash "$global_file"
  elif [[ -e "$global_file" ]]; then
    if ! cmp -s "$source_file" "$global_file"; then
      echo "Refusing to replace diverged global skill: $global_file" >&2
      exit 2
    fi
    /usr/bin/trash "$global_file"
  fi

  ln -s "$source_file" "$global_file"
done

echo "Linked ${#SKILLS[@]} global skills to $ROOT/skills"
