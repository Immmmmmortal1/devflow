#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"

DEBUGBRIDGE_REPO="${DEV_FLOW_DEBUGBRIDGE_MCP_REPO:-https://github.com/Immmmmmortal1/UI-dbugbridge-mcp.git}"
DEBUGBRIDGE_TAG="${DEV_FLOW_DEBUGBRIDGE_POD_TAG:-0.1.7}"
PLATFORM=""
PROJECT_ROOT=""
MCP_ROOT=""
SKIP_MCP_CONFIG=0
SKIP_POD=0
RUN_POD_INSTALL=0

usage() {
  cat <<EOF
Usage:
  bash scripts/install-debugbridge-mcp.sh [--cursor | --codex] [--project <app-root>] [--mcp-root <path>] [--run-pod-install] [--skip-mcp-config] [--skip-pod]

Install UI-dbugbridge-mcp (Mac-side DebugBridge MCP) and wire the iOS Pod when --project is set.

What it does:
  1. Clone or update UI-dbugbridge-mcp (default: sibling of devflow clone)
  2. npm run build in the MCP repo
  3. Merge ui_dbugbridge_mcp into Cursor ~/.cursor/mcp.json or Codex ~/.codex/config.toml
  4. When --project is set: add LookDebugBridge Debug pod to Podfile and write AI bootstrap manifest

AI agents after --project:
  - Run pod install in the app repo if Podfile changed
  - Add the Swift bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet
  - build_run_device on a wired physical device, then verify MCP ping / environment-health

Examples:
  bash scripts/install-debugbridge-mcp.sh
  bash scripts/install-debugbridge-mcp.sh --cursor --project ~/iOSworkspace/KakaPic
  bash scripts/install-debugbridge-mcp.sh --mcp-root ~/project/UI-dbugbridge-mcp --run-pod-install
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
    --mcp-root)
      MCP_ROOT="${2:-}"
      shift 2
      ;;
    --run-pod-install)
      RUN_POD_INSTALL=1
      shift
      ;;
    --skip-mcp-config)
      SKIP_MCP_CONFIG=1
      shift
      ;;
    --skip-pod)
      SKIP_POD=1
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

if [[ -z "$MCP_ROOT" ]]; then
  MCP_ROOT="$(cd "$ROOT/.." && pwd)/UI-dbugbridge-mcp"
fi
mkdir -p "$(dirname "$MCP_ROOT")"
MCP_ROOT="$(cd "$(dirname "$MCP_ROOT")" && pwd)/$(basename "$MCP_ROOT")"

if [[ ! -d "$MCP_ROOT/.git" ]]; then
  echo "Cloning UI-dbugbridge-mcp into $MCP_ROOT"
  git clone "$DEBUGBRIDGE_REPO" "$MCP_ROOT"
else
  echo "Updating UI-dbugbridge-mcp at $MCP_ROOT"
  git -C "$MCP_ROOT" fetch --tags origin
  current_branch="$(git -C "$MCP_ROOT" symbolic-ref -q --short HEAD || true)"
  if [[ -n "$current_branch" ]]; then
    git -C "$MCP_ROOT" pull --ff-only origin "$current_branch" || {
      echo "WARNING: could not fast-forward $MCP_ROOT; using existing checkout." >&2
    }
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required (Node.js 18+)." >&2
  exit 1
fi
NODE_PATH="$(command -v node)"

(
  cd "$MCP_ROOT"
  npm run build
)

SERVER_JS="$MCP_ROOT/src/server.js"
if [[ ! -f "$SERVER_JS" ]]; then
  echo "Missing MCP server entry: $SERVER_JS" >&2
  exit 1
fi

if [[ "$SKIP_MCP_CONFIG" -eq 0 ]]; then
  if [[ "$PLATFORM" == "cursor" ]]; then
    MCP_CONFIG_PATH="${CURSOR_MCP_CONFIG:-$HOME/.cursor/mcp.json}"
  else
    MCP_CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
  fi
  merge_output="$(
    python3 "$LIB/merge-debugbridge-mcp-config.py" \
      --platform "$PLATFORM" \
      --server-path "$SERVER_JS" \
      --node-path "$NODE_PATH" \
      --config-path "$MCP_CONFIG_PATH"
  )"
  echo "$merge_output"
fi

POD_STATUS="skipped"
PODFILE_PATH=""
POD_CHANGED="no"
SWIFT_BOOTSTRAP_REQUIRED="false"

if [[ -n "$PROJECT_ROOT" ]]; then
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
  STATE_DIR="$PROJECT_ROOT/.dev-flow"
  mkdir -p "$STATE_DIR"

  printf '%s\n' "$MCP_ROOT" >"$STATE_DIR/debugbridge-mcp-root"

  cat >"$STATE_DIR/debugbridge-app-bootstrap.swift.snippet" <<'SWIFT'
#if DEBUG
import LookDebugBridge

Task { @MainActor in
    LookDebugBridge.shared.startIfNeeded()
}
#endif
SWIFT

  if [[ "$SKIP_POD" -eq 0 ]]; then
    pod_output="$(python3 "$LIB/install-debugbridge-pod.py" "$PROJECT_ROOT" --tag "$DEBUGBRIDGE_TAG")"
    echo "$pod_output"
    PODFILE_PATH="$(printf '%s\n' "$pod_output" | sed -n 's/^podfile=//p')"
    POD_CHANGED="$(printf '%s\n' "$pod_output" | sed -n 's/^changed=//p')"
    if printf '%s\n' "$pod_output" | grep -qx 'no_podfile'; then
      POD_STATUS="no_podfile"
    elif [[ -n "$PODFILE_PATH" ]]; then
      POD_STATUS="present"
      if [[ "$POD_CHANGED" == "yes" ]]; then
        POD_STATUS="added"
        SWIFT_BOOTSTRAP_REQUIRED="true"
        if [[ "$RUN_POD_INSTALL" -eq 1 ]] && command -v pod >/dev/null 2>&1; then
          echo "Running pod install in $(dirname "$PODFILE_PATH")"
          (cd "$(dirname "$PODFILE_PATH")" && pod install)
        fi
      fi
    fi
  else
    POD_STATUS="skipped"
  fi

  python3 - <<PY
import json
from pathlib import Path

manifest = {
    "schema_version": 1,
    "mcp_root": "$MCP_ROOT",
    "server_js": "$SERVER_JS",
    "pod_tag": "$DEBUGBRIDGE_TAG",
    "pod_status": "$POD_STATUS",
    "podfile": "$PODFILE_PATH",
    "pod_changed": "$POD_CHANGED" == "yes",
    "swift_bootstrap_required": "$SWIFT_BOOTSTRAP_REQUIRED" == "true",
    "swift_bootstrap_snippet": ".dev-flow/debugbridge-app-bootstrap.swift.snippet",
    "ai_next_steps": [],
}
if "$POD_STATUS" == "added":
    manifest["ai_next_steps"].append("Run pod install in the app repo")
    manifest["ai_next_steps"].append("Add Swift bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet in App launch (Debug only)")
elif "$POD_STATUS" == "no_podfile":
    manifest["ai_next_steps"].append("No Podfile found; integrate LookDebugBridge manually or add CocoaPods first")
if "$POD_CHANGED" != "yes" and "$POD_STATUS" == "present":
    manifest["ai_next_steps"].append("Verify LookDebugBridge bootstrap code exists in Debug app launch")
manifest["ai_next_steps"].append("Restart Cursor/Codex MCP after config merge")
manifest["ai_next_steps"].append("build_run_device on wired physical device, then MCP ping or dev-flow environment-health run")

Path("$STATE_DIR/debugbridge-install.json").write_text(
    json.dumps(manifest, indent=2) + "\n",
    encoding="utf-8",
)
PY
fi

cat <<EOF

== DebugBridge MCP install ==
MCP root:     $MCP_ROOT
Server:       $SERVER_JS
Platform:     $PLATFORM
Pod status:   ${POD_STATUS:-skipped}
EOF

if [[ -n "$PROJECT_ROOT" && "$SWIFT_BOOTSTRAP_REQUIRED" == "true" ]]; then
  cat <<EOF

AI / human next steps (App repo: $PROJECT_ROOT):
  1. cd "$(dirname "${PODFILE_PATH:-$PROJECT_ROOT}")" && pod install
  2. Add Debug-only LookDebugBridge bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet
  3. Restart MCP host (Cursor/Codex) so ui_dbugbridge_mcp reloads
  4. build_run_device on wired device → MCP ping → dev-flow environment-health run
EOF
fi
