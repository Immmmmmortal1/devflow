#!/usr/bin/env bash
# Shared dev-flow skill linking helpers. Source from link-*-skills.sh; do not execute directly.

link_skills_devflow_package() {
  local source_root="$1"
  local skills_root="$2"
  local package_link="$skills_root/dev-flow"

  if [[ ! -f "$source_root/SKILL.md" ]]; then
    echo "Missing dev-flow router skill: $source_root/SKILL.md" >&2
    exit 1
  fi

  mkdir -p "$skills_root"

  if [[ -L "$package_link" ]]; then
    current_target="$(readlink "$package_link")"
    if [[ "$current_target" == "$source_root" ]]; then
      :
    else
      /usr/bin/trash "$package_link"
      ln -s "$source_root" "$package_link"
    fi
  elif [[ -e "$package_link" ]]; then
    echo "Refusing to replace non-symlink dev-flow package path: $package_link" >&2
    exit 2
  else
    ln -s "$source_root" "$package_link"
  fi
}

link_skills_tree() {
  local source_root="$1"
  local skills_root="$2"

  local skills=(
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
    figma-ui-gates
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

  for skill in "${skills[@]}"; do
    link_file "$source_root/skills/$skill/SKILL.md" "$skills_root/$skill/SKILL.md"
  done

  link_file "$source_root/skills/requirements-closure/references/requirements-artifact-template.md" \
    "$skills_root/requirements-closure/references/requirements-artifact-template.md"

  link_file "$source_root/skills/localization-workflow/references/localization-matrix-template.md" \
    "$skills_root/localization-workflow/references/localization-matrix-template.md"

  link_file "$source_root/skills/runtime-debug-workflow/references/runtime-evidence-template.md" \
    "$skills_root/runtime-debug-workflow/references/runtime-evidence-template.md"

  link_file "$source_root/skills/code-review-workflow/references/review-packet-template.md" \
    "$skills_root/code-review-workflow/references/review-packet-template.md"

  for route in \
    index.md \
    review-loop.md \
    code-quality-review.md \
    requirements-chain-review.md \
    api-contract-review.md \
    ui-parity-review.md; do
    link_file "$source_root/skills/code-review-workflow/routes/$route" \
      "$skills_root/code-review-workflow/routes/$route"
  done

  echo "${#skills[@]}"
}
