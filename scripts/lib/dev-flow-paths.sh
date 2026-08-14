#!/usr/bin/env bash
# Resolve dev-flow source (git clone) vs app project roots. Source only.

resolve_dev_flow_project_root() {
  local dir=""

  if [[ -n "${DEV_FLOW_PROJECT_ROOT:-}" ]]; then
    (cd "$DEV_FLOW_PROJECT_ROOT" && pwd)
    return 0
  fi

  dir="${PWD}"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/.dev-flow/source-root" || -d "$dir/.dev-flow/sessions" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  printf '%s\n' "${PWD}"
}

dev_flow_load_paths() {
  local invoking_script="$1"
  local script_dir=""

  script_dir="$(cd "$(dirname "$invoking_script")" && pwd)"
  DEV_FLOW_SOURCE_ROOT="$(cd "$script_dir/.." && pwd)"
  DEV_FLOW_SCRIPTS_DIR="$DEV_FLOW_SOURCE_ROOT/scripts"
  DEV_FLOW_PROJECT_ROOT="$(resolve_dev_flow_project_root)"
  DEV_FLOW_STATE_DIR="$DEV_FLOW_PROJECT_ROOT/.dev-flow/sessions"

  # Back-compat names used across gate scripts.
  ROOT="$DEV_FLOW_PROJECT_ROOT"
  SOURCE_ROOT="$DEV_FLOW_SOURCE_ROOT"
  STATE_DIR="$DEV_FLOW_STATE_DIR"
}

dev_flow_script_path() {
  printf '%s/%s' "$DEV_FLOW_SCRIPTS_DIR" "$1"
}
