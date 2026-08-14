#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-skills-common.sh
source "$ROOT/scripts/link-skills-common.sh"

PLATFORM=""
PROJECT_ROOT=""
SKILLS_ONLY=0
SKIP_DEBUGBRIDGE=0
SKIP_REVIEW=0
RUN_POD_INSTALL=0
DEBUGBRIDGE_MCP_ROOT=""
REVIEW_BACKEND=""
ORCHESTRATOR_ROOT=""

usage() {
  cat <<EOF
Usage:
  bash scripts/install-dev-flow.sh [--cursor | --codex] [--project <app-root>] [--skills-only] [--skip-debugbridge] [--skip-review] [--run-pod-install] [--debugbridge-mcp-root <path>] [--review-backend orchestrator|gstack] [--orchestrator-root <path>]

One-shot dev-flow installer for humans and AI agents.

What it does:
  1. Symlink dev-flow skills into the local Codex or Cursor skills directory
  2. Prompt for review backend: orchestrator-mcp or gstack-review (or pass --review-backend)
  3. Install UI-dbugbridge-mcp (Mac MCP + optional iOS LookDebugBridge Pod wiring)
  4. Optionally bind an iOS app repo (creates only <app>/.dev-flow/, no scripts/ copy)
  5. Run dev-flow doctor when --project is provided

Examples:
  bash scripts/install-dev-flow.sh --project ~/iOSworkspace/KakaPic
  bash scripts/install-dev-flow.sh --cursor --project .
  bash scripts/install-dev-flow.sh --skills-only

AI agents:
  - Run from the devflow git clone root after git pull
  - Pass --project as the iOS app workspace root (where .xcodeproj / .xcworkspace lives)
  - Do NOT copy gate scripts into the app repo; gate scripts stay in this devflow clone
  - After install, run gates via: bash "$ROOT/scripts/dev-flow.sh" ...
  - When Podfile changed: run pod install and add Debug bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet
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
    --skip-debugbridge)
      SKIP_DEBUGBRIDGE=1
      shift
      ;;
    --skip-review)
      SKIP_REVIEW=1
      shift
      ;;
    --run-pod-install)
      RUN_POD_INSTALL=1
      shift
      ;;
    --debugbridge-mcp-root)
      DEBUGBRIDGE_MCP_ROOT="${2:-}"
      shift 2
      ;;
    --review-backend)
      REVIEW_BACKEND="${2:-}"
      shift 2
      ;;
    --orchestrator-root)
      ORCHESTRATOR_ROOT="${2:-}"
      shift 2
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

if [[ "$SKIP_REVIEW" -eq 0 ]]; then
  review_args=(--"$PLATFORM" --skills-root "$SKILLS_ROOT")
  if [[ -n "$REVIEW_BACKEND" ]]; then
    review_args+=(--review-backend "$REVIEW_BACKEND")
  fi
  if [[ -n "$ORCHESTRATOR_ROOT" ]]; then
    review_args+=(--orchestrator-root "$ORCHESTRATOR_ROOT")
  fi
  if [[ -n "$PROJECT_ROOT" ]]; then
    review_args+=(--project "$PROJECT_ROOT")
  fi
  bash "$ROOT/scripts/install-review-backend.sh" "${review_args[@]}"
fi

if [[ "$SKIP_DEBUGBRIDGE" -eq 0 ]]; then
  debugbridge_args=(--"$PLATFORM")
  if [[ -n "$DEBUGBRIDGE_MCP_ROOT" ]]; then
    debugbridge_args+=(--mcp-root "$DEBUGBRIDGE_MCP_ROOT")
  fi
  if [[ -n "$PROJECT_ROOT" ]]; then
    debugbridge_args+=(--project "$PROJECT_ROOT")
  fi
  if [[ "$RUN_POD_INSTALL" -eq 1 ]]; then
    debugbridge_args+=(--run-pod-install)
  fi
  bash "$ROOT/scripts/install-debugbridge-mcp.sh" "${debugbridge_args[@]}"
fi

if [[ "$SKILLS_ONLY" -eq 1 ]]; then
  echo
  echo "Skills-only install complete."
  echo "Bind an app later with:"
  echo "  bash \"$ROOT/scripts/install-dev-flow.sh\" --project /path/to/YourApp"
  exit 0
fi

if [[ -z "$PROJECT_ROOT" ]]; then
  echo
  echo "Skills + DebugBridge MCP install complete. No app project bound."
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

DebugBridge:
  - MCP repo path recorded in .dev-flow/debugbridge-mcp-root
  - Pod/bootstrap manifest: .dev-flow/debugbridge-install.json
  - If pod changed: pod install + add .dev-flow/debugbridge-app-bootstrap.swift.snippet in Debug launch

Review backend:
  - Manifest: .dev-flow/review-backend.json
  - orchestrator-mcp path (if chosen): .dev-flow/orchestrator-mcp-root

Figma token: set FIGMA_REST_TOKEN or FIGMA_ACCESS_TOKEN in the environment.
EOF
