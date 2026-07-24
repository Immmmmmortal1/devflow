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
  api-contract
  reference-parity
  zentao-bug-gate
)

link_file() {
  local source_file="$1"
  local global_file="$2"
  local global_dir
  global_dir="$(dirname "$global_file")"

  if [[ ! -f "$source_file" ]]; then
    echo "Missing repository skill resource: $source_file" >&2
    exit 1
  fi

  mkdir -p "$global_dir"

  if [[ -L "$global_file" ]]; then
    current_target="$(readlink "$global_file")"
    if [[ "$current_target" == "$source_file" ]]; then
      return
    fi
    /usr/bin/trash "$global_file"
  elif [[ -e "$global_file" ]]; then
    if ! cmp -s "$source_file" "$global_file"; then
      echo "Refusing to replace diverged global skill resource: $global_file" >&2
      exit 2
    fi
    /usr/bin/trash "$global_file"
  fi

  ln -s "$source_file" "$global_file"
}

for skill in "${SKILLS[@]}"; do
  source_file="$ROOT/skills/$skill/SKILL.md"
  global_dir="$GLOBAL_SKILLS_ROOT/$skill"
  global_file="$global_dir/SKILL.md"

  link_file "$source_file" "$global_file"
done

link_file "$ROOT/skills/reference-parity/examples/purchase-verify-reference-keys.json" \
  "$GLOBAL_SKILLS_ROOT/reference-parity/examples/purchase-verify-reference-keys.json"

echo "Linked ${#SKILLS[@]} global skills and their bundled resources to $ROOT/skills"
