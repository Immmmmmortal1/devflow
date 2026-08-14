#!/usr/bin/env bash
# Shared helpers for linking dev-flow scripts into a target iOS project.
# Source from link-project-scripts.sh; do not execute directly.

link_project_script() {
  local source_file="$1"
  local target_file="$2"
  local target_dir

  if [[ ! -f "$source_file" ]]; then
    echo "Missing dev-flow script: $source_file" >&2
    exit 1
  fi

  target_dir="$(dirname "$target_file")"
  mkdir -p "$target_dir"

  if [[ -L "$target_file" ]]; then
    local current_target
    current_target="$(readlink "$target_file")"
    if [[ "$current_target" == "$source_file" ]]; then
      return 0
    fi
    /usr/bin/trash "$target_file"
  elif [[ -e "$target_file" ]]; then
    if cmp -s "$source_file" "$target_file"; then
      /usr/bin/trash "$target_file"
    else
      echo "Refusing to replace diverged project script: $target_file" >&2
      echo "Remove it manually or rerun with --force after backup." >&2
      exit 2
    fi
  fi

  ln -s "$source_file" "$target_file"
}

link_project_scripts_tree() {
  local source_root="$1"
  local project_root="$2"
  local script_name target_file

  local scripts=(
    DEV_FLOW_SCRIPTS_VERSION
    resolve-dev-flow-session-id.sh
    dev-flow-session.sh
    environment-health-check.sh
    record-app-launch-report.sh
    read-app-launch-report.sh
    review-health-probe.sh
    dev-flow-doctor.sh
    validate-g6-asset-binding.sh
    validate-g6-asset-binding.py
    validate-ui-review-artifacts.sh
    validate-ui-review-artifacts.py
  )

  for script_name in "${scripts[@]}"; do
    target_file="$project_root/scripts/$script_name"
    link_project_script "$source_root/scripts/$script_name" "$target_file"
  done

  printf '%s\n' "${#scripts[@]}"
}
