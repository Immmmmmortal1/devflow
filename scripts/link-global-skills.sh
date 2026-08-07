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
  code-review-workflow
  commit-gate
  api-contract
  zentao-bug-gate
  requirements-closure
  localization-workflow
  runtime-debug-workflow
  environment-health-check
  ui-review
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

link_file "$ROOT/skills/requirements-closure/references/requirements-artifact-template.md" \
  "$GLOBAL_SKILLS_ROOT/requirements-closure/references/requirements-artifact-template.md"

link_file "$ROOT/skills/localization-workflow/references/localization-matrix-template.md" \
  "$GLOBAL_SKILLS_ROOT/localization-workflow/references/localization-matrix-template.md"

link_file "$ROOT/skills/runtime-debug-workflow/references/runtime-evidence-template.md" \
  "$GLOBAL_SKILLS_ROOT/runtime-debug-workflow/references/runtime-evidence-template.md"

link_file "$ROOT/skills/code-review-workflow/references/review-packet-template.md" \
  "$GLOBAL_SKILLS_ROOT/code-review-workflow/references/review-packet-template.md"

for route in \
  index.md \
  review-loop.md \
  code-quality-review.md \
  requirements-chain-review.md \
  api-contract-review.md \
  ui-parity-review.md; do
  link_file "$ROOT/skills/code-review-workflow/routes/$route" \
    "$GLOBAL_SKILLS_ROOT/code-review-workflow/routes/$route"
done

echo "Linked ${#SKILLS[@]} global skills and their bundled resources to $ROOT/skills"
