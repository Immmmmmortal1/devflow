#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-skills-common.sh
source "$ROOT/scripts/link-skills-common.sh"

PLATFORM=""
PROJECT_ROOT=""
SKILLS_ONLY=0

usage() {
  cat <<EOF
Usage:
  bash scripts/install-dev-flow.sh [--cursor | --codex] [--project <app-root>] [--skills-only]

One-shot dev-flow installer for humans and AI agents.

What it does:
  1. Symlink dev-flow skills into the local Codex or Cursor skills directory
  2. Optionally bind an iOS app repo (creates only <app>/.dev-flow/, no scripts/ copy)
  3. Run dev-flow doctor when --project is provided

Examples:
  bash scripts/install-dev-flow.sh --project ~/iOSworkspace/KakaPic
  bash scripts/install-dev-flow.sh --cursor --project .
  bash scripts/install-dev-flow.sh --skills-only

AI agents:
  - Run from the devflow git clone root after git pull
  - Pass --project as the iOS app workspace root (where .xcodeproj / .xcworkspace lives)
  - Do NOT copy gate scripts into the app repo; gate scripts stay in this devflow clone
  - After install, run gates via: bash "$ROOT/scripts/dev-flow.sh" ...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cursor)
      PLATFORM="cursor"
      shift
      ;;
    --codex)
      PLATFORM="codex"
      shift
      ;;
    --project)
      PROJECT_ROOT="${2:-}"
      shift 2
      ;;
    --skills-only)
      SKILLS_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PLATFORM" ]]; then
  if [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
    PLATFORM="cursor"
  else
    PLATFORM="codex"
  fi
fi

if [[ "$PLATFORM" == "cursor" ]]; then
  if [[ -n "${CURSOR_SKILLS_ROOT:-}" ]]; then
    SKILLS_ROOT="$CURSOR_SKILLS_ROOT"
  else
    SKILLS_ROOT="$HOME/.cursor/skills"
  fi
else
  if [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
    SKILLS_ROOT="$CODEX_SKILLS_ROOT"
  elif [[ -n "${CODEX_HOME:-}" ]]; then
    SKILLS_ROOT="$CODEX_HOME/skills"
  else
    SKILLS_ROOT="$HOME/.codex/skills"
  fi
fi

link_skills_devflow_package "$ROOT" "$SKILLS_ROOT"
linked_count="$(link_skills_tree "$ROOT" "$SKILLS_ROOT")"

echo "== dev-flow install =="
echo "Platform:      $PLATFORM"
echo "Skills linked: $linked_count under $SKILLS_ROOT"
echo "Source root:   $ROOT"

if [[ "$SKILLS_ONLY" -eq 1 ]]; then
  echo
  echo "Skills-only install complete."
  echo "Bind an app later with:"
  echo "  bash \"$ROOT/scripts/install-dev-flow.sh\" --project /path/to/YourApp"
  exit 0
fi

if [[ -z "$PROJECT_ROOT" ]]; then
  echo
  echo "Skills install complete. No app project bound."
  echo "Next, bind your iOS app repo:"
  echo "  bash \"$ROOT/scripts/install-dev-flow.sh\" --project /path/to/YourApp"
  exit 0
fi

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
bash "$ROOT/scripts/dev-flow-init-project.sh" "$PROJECT_ROOT"
bash "$ROOT/scripts/dev-flow-doctor.sh" "$PROJECT_ROOT"

cat <<EOF

Install complete.

App project:  $PROJECT_ROOT
Dev-flow root: $ROOT

Daily commands (run from the app repo):
  cd "$PROJECT_ROOT"
  bash "$ROOT/scripts/dev-flow.sh" doctor
  bash "$ROOT/scripts/dev-flow.sh" session start --type bug --task "short label"
  # after XcodeBuildMCP build_run_device succeeds:
  bash "$ROOT/scripts/dev-flow.sh" record-app-launch record
  bash "$ROOT/scripts/dev-flow.sh" environment-health run

Figma token: set FIGMA_REST_TOKEN or FIGMA_ACCESS_TOKEN in the environment.
EOF
