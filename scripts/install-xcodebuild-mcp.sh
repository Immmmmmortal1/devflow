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
  bash scripts/install-xcodebuild-mcp.sh [--cursor | --codex | --opencode] [--project <app-root>] [--config-path <path>] [--skip-mcp-config] [--workflows <csv>]

Install XcodeBuildMCP for dev-flow physical-device build/run gates.

What it does:
  1. Merge XcodeBuildMCP into Cursor ~/.cursor/mcp.json or Codex ~/.codex/config.toml
     For opencode: skip host MCP config merge (opencode manages MCP config separately);
     still generate project profile (.xcodebuildmcp/config.yaml + install manifest).
  2. Enable dev-flow workflows: session-management, project-discovery, device
  3. When --project is set: write <app>/.xcodebuildmcp/config.yaml and install manifest

Platform notes:
  --cursor    Merge into ~/.cursor/mcp.json
  --codex     Merge into ~/.codex/config.toml
  --opencode  Skip host MCP config merge (opencode manages its own MCP config);
              still write .xcodebuildmcp/config.yaml and .dev-flow manifest

Examples:
  bash scripts/install-xcodebuild-mcp.sh --codex
  bash scripts/install-xcodebuild-mcp.sh --cursor --project ~/iOSworkspace/KakaPic
  bash scripts/install-xcodebuild-mcp.sh --opencode --project ~/iOSworkspace/KakaPic
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
  if [[ -n "${OPENCODE:-}" || -d "${HOME}/.config/opencode" ]]; then
    PLATFORM="opencode"
  elif [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
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

# opencode: 跳过 host MCP config 合并（opencode 自行管理 MCP 配置），
# 仍生成项目 profile
if [[ "$PLATFORM" == "opencode" ]]; then
  SKIP_MCP_CONFIG=1
  echo "== XcodeBuildMCP: opencode mode =="
  echo "Skipping host MCP config merge (opencode manages MCP config separately)."
  echo "Ensure XcodeBuildMCP is configured in your opencode config (opencode.json/opencode.local.json)."
fi

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

  # 安全检查：PROJECT_ROOT 和 .dev-flow 不能是 symlink
  if [[ -L "$PROJECT_ROOT" ]]; then
    echo "ERROR: refusing to write through symlinked PROJECT_ROOT: $PROJECT_ROOT" >&2
    exit 1
  fi
  if [[ -L "$STATE_DIR" ]]; then
    echo "ERROR: refusing to write through symlinked .dev-flow: $STATE_DIR" >&2
    exit 1
  fi

  # 安全写入 config.yaml 和 manifest（使用 atomic_json_write safe 函数）
  IFS=',' read -r -a workflow_items <<< "$WORKFLOWS"
  config_yaml="schemaVersion: 1\nenabledWorkflows:\n"
  for workflow in "${workflow_items[@]}"; do
    workflow="$(echo "$workflow" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$workflow" ]] && config_yaml="${config_yaml}  - ${workflow}\n"
  done

  /usr/bin/python3 - "$STATE_DIR" "$CONFIG_DIR" "$config_yaml" "$STATE_DIR/xcodebuild-mcp-install.json" \
    "$PLATFORM" "$WORKFLOWS" "$MCP_CONFIG_PATH" "$ROOT" <<'PY'
import json, os, sys
from pathlib import Path

state_dir = Path(sys.argv[1])
config_dir = Path(sys.argv[2])
config_yaml = sys.argv[3]
manifest_path = Path(sys.argv[4])
platform = sys.argv[5]
workflows = sys.argv[6]
mcp_config_path = sys.argv[7]
devflow_root = Path(sys.argv[8])

sys.path.insert(0, str(devflow_root / "scripts" / "lib"))
from atomic_json_write import safe_mkdir, safe_write_text, safe_atomic_write_json

# 安全创建目录（trusted_root = PROJECT_ROOT，逐级 lstat 检查）
project_root = state_dir.parent
safe_mkdir(project_root, state_dir)
safe_mkdir(project_root, config_dir)

# 安全写入 config.yaml
safe_write_text(config_dir, config_dir / "config.yaml", config_yaml, mode=0o644)

# 安全写入 manifest
manifest = {
    "schema_version": 1,
    "platform": platform,
    "mcp_server": "XcodeBuildMCP",
    "enabled_workflows": [w.strip() for w in workflows.split(",") if w.strip()],
    "project_config": ".xcodebuildmcp/config.yaml",
    "mcp_config_path": mcp_config_path,
    "ai_next_steps": [
        "Ask the user to restart Cursor/Codex/opencode MCP so XcodeBuildMCP reloads with device workflows",
        "dev-flow session start, then confirm session_set_defaults / session_show_defaults / build_run_device|build_run_sim are callable",
        "session_set_defaults profile=<session-id> createIfNotExists=true with workspacePath/scheme/configuration/platform/deviceId (physical) or simulatorId (simulator)",
        "session_show_defaults to verify the profile, then build_run_device (wired) or build_run_sim (Simulator) on the chosen target with DEV_FLOW_SESSION_ID",
        "dev-flow app-launch record --report <bounded-xcodebuildmcp-json|->, then environment-health run",
    ],
}
safe_atomic_write_json(state_dir, manifest_path, manifest, mode=0o644)
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
