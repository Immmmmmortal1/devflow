#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"

PLATFORM=""
PROJECT_ROOT=""
SKIP_MCP_CONFIG=0
MCP_CONFIG_PATH=""
WORKFLOWS="${DEV_FLOW_XCODEBUILD_WORKFLOWS:-session-management,project-discovery,device}"
TOOL_TIMEOUT_SEC="${DEV_FLOW_XCODEBUILD_TOOL_TIMEOUT_SEC:-600}"

usage() {
  cat <<EOF
Usage:
  bash scripts/install-xcodebuild-mcp.sh [--cursor | --codex] [--project <app-root>] [--config-path <path>] [--skip-mcp-config] [--workflows <csv>]

Install XcodeBuildMCP for dev-flow physical-device build/run gates.

What it does:
  1. Merge XcodeBuildMCP into Cursor ~/.cursor/mcp.json or Codex ~/.codex/config.toml
  2. Enable dev-flow workflows: session-management, project-discovery, device
  3. When --project is set: write <app>/.xcodebuildmcp/config.yaml and install manifest

Examples:
  bash scripts/install-xcodebuild-mcp.sh --codex
  bash scripts/install-xcodebuild-mcp.sh --cursor --project ~/iOSworkspace/KakaPic
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
    --config-path)
      MCP_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --skip-mcp-config)
      SKIP_MCP_CONFIG=1
      shift
      ;;
    --workflows)
      WORKFLOWS="${2:-}"
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

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required (Node.js 18+)." >&2
  exit 1
fi
NPX_PATH="$(command -v npx)"

if [[ "$SKIP_MCP_CONFIG" -eq 0 ]]; then
  if [[ -z "$MCP_CONFIG_PATH" ]]; then
    if [[ "$PLATFORM" == "cursor" ]]; then
      MCP_CONFIG_PATH="${CURSOR_MCP_CONFIG:-$HOME/.cursor/mcp.json}"
    else
      MCP_CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
    fi
  fi
  merge_output="$(
    python3 "$LIB/merge-xcodebuild-mcp-config.py" \
      --platform "$PLATFORM" \
      --npx-path "$NPX_PATH" \
      --config-path "$MCP_CONFIG_PATH" \
      --workflows "$WORKFLOWS" \
      --tool-timeout-sec "$TOOL_TIMEOUT_SEC"
  )"
  echo "$merge_output"
fi

if [[ -n "$PROJECT_ROOT" ]]; then
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
  STATE_DIR="$PROJECT_ROOT/.dev-flow"
  CONFIG_DIR="$PROJECT_ROOT/.xcodebuildmcp"
  mkdir -p "$STATE_DIR" "$CONFIG_DIR"

  IFS=',' read -r -a workflow_items <<< "$WORKFLOWS"
  {
    echo "schemaVersion: 1"
    echo "enabledWorkflows:"
    for workflow in "${workflow_items[@]}"; do
      workflow="$(echo "$workflow" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$workflow" ]] && echo "  - $workflow"
    done
  } >"$CONFIG_DIR/config.yaml"

  python3 - <<PY
import json
from pathlib import Path

manifest = {
    "schema_version": 1,
    "platform": "$PLATFORM",
    "mcp_server": "XcodeBuildMCP",
    "enabled_workflows": [w.strip() for w in "$WORKFLOWS".split(",") if w.strip()],
    "project_config": ".xcodebuildmcp/config.yaml",
    "mcp_config_path": "$MCP_CONFIG_PATH",
    "ai_next_steps": [
        "Restart Cursor/Codex MCP so XcodeBuildMCP reloads with device workflows",
        "dev-flow session start, then session_set_defaults profile=<session-id> createIfNotExists=true",
        "build_run_device on a wired physical device, then dev-flow record-app-launch record",
    ],
}
Path("$STATE_DIR/xcodebuild-mcp-install.json").write_text(
    json.dumps(manifest, indent=2) + "\n",
    encoding="utf-8",
)
PY
fi

cat <<EOF

== XcodeBuildMCP install ==
Platform:   $PLATFORM
Workflows:  $WORKFLOWS
NPX:        $NPX_PATH
EOF

if [[ -n "$PROJECT_ROOT" ]]; then
  cat <<EOF
Project:    $PROJECT_ROOT
Config:     $PROJECT_ROOT/.xcodebuildmcp/config.yaml
Manifest:   $PROJECT_ROOT/.dev-flow/xcodebuild-mcp-install.json
EOF
fi
