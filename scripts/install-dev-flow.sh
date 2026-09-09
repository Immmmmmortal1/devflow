#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=link-skills-common.sh
source "$ROOT/scripts/link-skills-common.sh"

PLATFORM=""
PROJECT_ROOT=""
SKILLS_ONLY=0
SKIP_DEBUGBRIDGE=0
SKIP_XCODEBUILD=0
SKIP_REVIEW=0
RUN_POD_INSTALL=0
DEBUGBRIDGE_MCP_ROOT=""
REVIEW_BACKEND=""
ORCHESTRATOR_ROOT=""

usage() {
  cat <<EOF
Usage:
  bash scripts/install-dev-flow.sh [--cursor | --codex | --opencode] [--project <app-root>] [--skills-only] [--skip-xcodebuild] [--skip-debugbridge] [--skip-review] [--run-pod-install] [--debugbridge-mcp-root <path>] [--review-backend reviewer|orchestrator|gstack] [--orchestrator-root <path>]

One-shot dev-flow installer for humans and AI agents.

What it does:
  1. Symlink dev-flow skills into the local Codex / Cursor / opencode skills directory
  2. Prompt for review backend: 审查角色（@openai-reviewer）、orchestrator-mcp 或 gstack-review (or pass --review-backend)
  3. Install XcodeBuildMCP (device + session-management + project-discovery workflows)
  4. Install UI-dbugbridge-mcp (Mac MCP + optional iOS LookDebugBridge Pod wiring)
  5. Optionally bind an iOS app repo (creates only <app>/.dev-flow/, no scripts/ copy)
  6. Run dev-flow doctor when --project is provided

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
    --opencode)
      PLATFORM="opencode"
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
    --skip-xcodebuild)
      SKIP_XCODEBUILD=1
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
  if [[ -n "${DEV_FLOW_HOST:-}" ]]; then
    PLATFORM="$DEV_FLOW_HOST"
  elif [[ -n "${OPENCODE:-}" ]]; then
    PLATFORM="opencode"
  elif [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
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
elif [[ "$PLATFORM" == "opencode" ]]; then
  SKILLS_ROOT="${OPENCODE_SKILLS_ROOT:-$HOME/.config/opencode/skills}"
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

# --skills-only：只链接 skills，跳过 review/xcode/debug 安装和项目绑定
if [[ "$SKILLS_ONLY" -eq 1 ]]; then
  echo
  echo "Skills-only install complete."
  echo "Bind an app later with:"
  echo "  bash \"$ROOT/scripts/install-dev-flow.sh\" --project /path/to/YourApp"
  exit 0
fi

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

if [[ "$SKIP_XCODEBUILD" -eq 0 ]]; then
  xcodebuild_args=(--"$PLATFORM")
  if [[ -n "$PROJECT_ROOT" ]]; then
    xcodebuild_args+=(--project "$PROJECT_ROOT")
  fi
  bash "$ROOT/scripts/install-xcodebuild-mcp.sh" "${xcodebuild_args[@]}"
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
  bash "$ROOT/scripts/dev-flow.sh" xcode-target  # resolve .xcodebuildmcp/config.yaml (if present)
  bash "$ROOT/scripts/dev-flow.sh" app-launch status || bash "$ROOT/scripts/dev-flow.sh" app-launch instructions
  # after XcodeBuildMCP session_set_defaults + session_show_defaults + build_run_device|build_run_sim (resolver launch_action) succeeds:
  bash "$ROOT/scripts/dev-flow.sh" app-launch record --report <bounded-xcodebuildmcp-json|->
  bash "$ROOT/scripts/dev-flow.sh" environment-health run

DebugBridge:
  - MCP repo path recorded in .dev-flow/debugbridge-mcp-root
  - Pod/bootstrap manifest: .dev-flow/debugbridge-install.json
  - If pod changed: pod install + add .dev-flow/debugbridge-app-bootstrap.swift.snippet in Debug launch

Review backend:
  - Config: .dev-flow/review-backend.local.json (project) or ~/.config/dev-flow/config.json (user)
  - 审查角色（agent/openai-reviewer）：需 opencode.json 含 agent openai-reviewer 及 provider/apiKey 配置（无额外文件）
  - orchestrator-mcp：path recorded in .dev-flow/orchestrator-mcp-root
  - gstack-review（skill/gstack）：skill 路径记录在 config 的 adapters 段

XcodeBuildMCP:
  - Manifest: .dev-flow/xcodebuild-mcp-install.json
  - Project config: .xcodebuildmcp/config.yaml
  - Ask the user to restart MCP host if reloading is needed, then tool_search → session_set_defaults → session_show_defaults → build_run_device|build_run_sim (resolver launch_action) on the chosen target

Figma token: set FIGMA_REST_TOKEN or FIGMA_ACCESS_TOKEN in the environment.
EOF
