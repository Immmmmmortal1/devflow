#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"

DEBUGBRIDGE_REPO="${DEV_FLOW_DEBUGBRIDGE_MCP_REPO:-https://github.com/Immmmmmortal1/UI-dbugbridge-mcp.git}"
DEBUGBRIDGE_TAG="${DEV_FLOW_DEBUGBRIDGE_POD_TAG:-0.1.14}"
DEBUGBRIDGE_MCP_TAG="${DEV_FLOW_DEBUGBRIDGE_MCP_TAG:-$DEBUGBRIDGE_TAG}"
PLATFORM=""
PROJECT_ROOT=""
MCP_ROOT=""
SKIP_MCP_CONFIG=0
SKIP_POD=0
RUN_POD_INSTALL=0

usage() {
  cat <<EOF
Usage:
  bash scripts/install-debugbridge-mcp.sh [--cursor | --codex | --opencode] [--project <app-root>] [--mcp-root <path>] [--run-pod-install] [--skip-mcp-config] [--skip-pod]

Install UI-dbugbridge-mcp (Mac-side DebugBridge MCP) and wire the iOS Pod when --project is set.

What it does:
  1. Clone or update UI-dbugbridge-mcp (default: sibling of devflow clone)
  2. npm run build in the MCP repo
  3. Merge ui_dbugbridge_mcp into Cursor ~/.cursor/mcp.json or Codex ~/.codex/config.toml
     For opencode: skip host MCP config merge, check if already configured in opencode config;
     still install app binding (Pod + bootstrap snippet + manifest).
  4. When --project is set: add LookDebugBridge Debug pod to Podfile and write AI bootstrap manifest

Platform notes:
  --cursor    Merge into ~/.cursor/mcp.json
  --codex     Merge into ~/.codex/config.toml
  --opencode  Skip host MCP config merge (opencode manages its own MCP config);
              check if ui_dbugbridge_mcp is already configured in opencode config;
              still install app binding (Pod + manifest)

AI agents after --project:
  - Run pod install in the app repo if Podfile changed
  - Add the Swift bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet
  - build_run_device (wired) or build_run_sim (Simulator) — the resolver's launch_action — then verify MCP ping / environment-health

Examples:
  bash scripts/install-debugbridge-mcp.sh
  bash scripts/install-debugbridge-mcp.sh --cursor --project ~/iOSworkspace/KakaPic
  bash scripts/install-debugbridge-mcp.sh --opencode --project ~/iOSworkspace/KakaPic
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
    --opencode)
      PLATFORM="opencode"
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
  if [[ -n "${OPENCODE:-}" || -d "${HOME}/.config/opencode" ]]; then
    PLATFORM="opencode"
  elif [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
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
fi

if [[ -n "$DEBUGBRIDGE_MCP_TAG" ]]; then
  git -C "$MCP_ROOT" fetch --tags origin
  if ! git -C "$MCP_ROOT" rev-parse -q --verify "refs/tags/$DEBUGBRIDGE_MCP_TAG" >/dev/null; then
    echo "Missing UI-dbugbridge-mcp tag: $DEBUGBRIDGE_MCP_TAG" >&2
    exit 1
  fi
  git -C "$MCP_ROOT" checkout --detach "$DEBUGBRIDGE_MCP_TAG"
else
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
  elif [[ "$PLATFORM" == "opencode" ]]; then
    # opencode: 不合并 host MCP config，检查是否已配置
    MCP_CONFIG_PATH=""
    OC_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode.local.json}"
    if [[ ! -f "$OC_CONFIG" ]]; then
      OC_CONFIG="$HOME/.config/opencode.json"
    fi
    if [[ -f "$OC_CONFIG" ]]; then
      if /usr/bin/python3 -c "
import json, sys
from pathlib import Path
cfg = json.loads(Path('$OC_CONFIG').read_text())
mcp = cfg.get('mcp', {})
if 'ui_dbugbridge_mcp' not in mcp:
    sys.exit(1)
" 2>/dev/null; then
        echo "== DebugBridge MCP: opencode mode =="
        echo "ui_dbugbridge_mcp already configured in $OC_CONFIG"
      else
        echo "== DebugBridge MCP: opencode mode =="
        echo "WARNING: ui_dbugbridge_mcp NOT found in $OC_CONFIG"
        echo "Please configure it manually in your opencode config:"
        echo '  "mcp": { "ui_dbugbridge_mcp": { "type": "local", "command": ["'"$NODE_PATH"'", "'"$SERVER_JS"'"], "environment": {"IPROXY_PATH": "iproxy"} } }'
      fi
    else
      echo "== DebugBridge MCP: opencode mode =="
      echo "WARNING: No opencode config found at ~/.config/opencode.json or ~/.config/opencode.local.json"
      echo "Please configure ui_dbugbridge_mcp manually in your opencode config."
    fi
  else
    MCP_CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
  fi
  if [[ -n "$MCP_CONFIG_PATH" ]]; then
    merge_output="$(
      python3 "$LIB/merge-debugbridge-mcp-config.py" \
        --platform "$PLATFORM" \
        --server-path "$SERVER_JS" \
        --node-path "$NODE_PATH" \
        --config-path "$MCP_CONFIG_PATH"
    )"
    echo "$merge_output"
  fi
fi

POD_STATUS="skipped"
PODFILE_PATH=""
POD_CHANGED="no"
SWIFT_BOOTSTRAP_REQUIRED="false"

if [[ -n "$PROJECT_ROOT" ]]; then
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
  STATE_DIR="$PROJECT_ROOT/.dev-flow"

  # 安全检查：PROJECT_ROOT 和 .dev-flow 不能是 symlink
  if [[ -L "$PROJECT_ROOT" ]]; then
    echo "ERROR: refusing to write through symlinked PROJECT_ROOT: $PROJECT_ROOT" >&2
    exit 1
  fi
  if [[ -L "$STATE_DIR" ]]; then
    echo "ERROR: refusing to write through symlinked .dev-flow: $STATE_DIR" >&2
    exit 1
  fi

  SWIFT_BOOTSTRAP='#if DEBUG
import LookDebugBridge

Task { @MainActor in
    LookDebugBridge.shared.startIfNeeded()
}
#endif'

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

  # 安全写入所有 .dev-flow 状态文件（使用 atomic_json_write safe 函数）
  /usr/bin/python3 - "$STATE_DIR" "$MCP_ROOT" "$SERVER_JS" "$DEBUGBRIDGE_TAG" "$DEBUGBRIDGE_MCP_TAG" \
    "$POD_STATUS" "$PODFILE_PATH" "$POD_CHANGED" "$SWIFT_BOOTSTRAP_REQUIRED" "$SWIFT_BOOTSTRAP" "$ROOT" <<'PY'
import json, os, sys
from pathlib import Path

state_dir = Path(sys.argv[1])
mcp_root = sys.argv[2]
server_js = sys.argv[3]
pod_tag = sys.argv[4]
mcp_tag = sys.argv[5]
pod_status = sys.argv[6]
podfile_path = sys.argv[7]
pod_changed = sys.argv[8]
swift_bootstrap_required = sys.argv[9]
swift_bootstrap = sys.argv[10]
devflow_root = Path(sys.argv[11])

sys.path.insert(0, str(devflow_root / "scripts" / "lib"))
from atomic_json_write import safe_mkdir, safe_write_text, safe_atomic_write_json

project_root = state_dir.parent
safe_mkdir(project_root, state_dir)

# 安全写入 debugbridge-mcp-root
safe_write_text(state_dir, state_dir / "debugbridge-mcp-root", mcp_root + "\n", mode=0o644)

# 安全写入 swift bootstrap snippet
safe_write_text(state_dir, state_dir / "debugbridge-app-bootstrap.swift.snippet", swift_bootstrap + "\n", mode=0o644)

# 安全写入 manifest
manifest = {
    "schema_version": 1,
    "mcp_root": mcp_root,
    "server_js": server_js,
    "pod_tag": pod_tag,
    "mcp_tag": mcp_tag,
    "pod_status": pod_status,
    "podfile": podfile_path,
    "pod_changed": pod_changed == "yes",
    "swift_bootstrap_required": swift_bootstrap_required == "true",
    "swift_bootstrap_snippet": ".dev-flow/debugbridge-app-bootstrap.swift.snippet",
    "ai_next_steps": [],
}
if pod_status == "added":
    manifest["ai_next_steps"].append("Run pod install in the app repo")
    manifest["ai_next_steps"].append("Add Swift bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet in App launch (Debug only)")
elif pod_status == "no_podfile":
    manifest["ai_next_steps"].append("No Podfile found; integrate LookDebugBridge manually or add CocoaPods first")
if pod_changed != "yes" and pod_status == "present":
    manifest["ai_next_steps"].append("Verify LookDebugBridge bootstrap code exists in Debug app launch")
manifest["ai_next_steps"].append("Ask the user to restart Cursor/Codex/opencode MCP after config merge if reloading is needed")
manifest["ai_next_steps"].append("build_run_device (wired) or build_run_sim (Simulator) — the resolver's launch_action, then MCP ping or dev-flow environment-health run")

safe_atomic_write_json(state_dir, state_dir / "debugbridge-install.json", manifest, mode=0o644)
PY
fi

cat <<EOF

== DebugBridge MCP install ==
MCP root:     $MCP_ROOT
Server:       $SERVER_JS
Platform:     $PLATFORM
MCP tag:      ${DEBUGBRIDGE_MCP_TAG:-current-branch}
Pod tag:      $DEBUGBRIDGE_TAG
Pod status:   ${POD_STATUS:-skipped}
EOF

if [[ -n "$PROJECT_ROOT" && "$SWIFT_BOOTSTRAP_REQUIRED" == "true" ]]; then
  cat <<EOF

AI / human next steps (App repo: $PROJECT_ROOT):
  1. cd "$(dirname "${PODFILE_PATH:-$PROJECT_ROOT}")" && pod install
  2. Add Debug-only LookDebugBridge bootstrap from .dev-flow/debugbridge-app-bootstrap.swift.snippet
  3. Ask the user to restart MCP host (Cursor/Codex) so ui_dbugbridge_mcp reloads
  4. build_run_device (wired) or build_run_sim (Simulator) — the resolver's launch_action → MCP ping → dev-flow environment-health run
EOF
fi
