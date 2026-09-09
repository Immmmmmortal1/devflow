#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-flow-doctor.sh [app-project-root]

Verify the central dev-flow clone and the current app project binding.
Gate scripts live only in the devflow git clone; app repos keep .dev-flow/ state only.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  export DEV_FLOW_PROJECT_ROOT="$1"
fi

dev_flow_load_paths "$SCRIPT_PATH"

required=(
  DEV_FLOW_SCRIPTS_VERSION
  dev-flow.sh
  dev-flow-init-project.sh
  install-debugbridge-mcp.sh
  install-xcodebuild-mcp.sh
  install-review-backend.sh
  resolve-dev-flow-session-id.sh
  dev-flow-session.sh
  app-launch-preflight.sh
  environment-health-check.sh
  record-app-launch-report.sh
  read-app-launch-report.sh
  review-health-probe.sh
)

missing=()
for script_name in "${required[@]}"; do
  if [[ ! -f "$DEV_FLOW_SCRIPTS_DIR/$script_name" ]]; then
    missing+=("$script_name")
  fi
done

echo "App project:    $DEV_FLOW_PROJECT_ROOT"
echo "Dev-flow source: $DEV_FLOW_SOURCE_ROOT"
echo "Session state:  $DEV_FLOW_STATE_DIR"

if ((${#missing[@]} > 0)); then
  echo "Missing in dev-flow source:" >&2
  printf '  - scripts/%s\n' "${missing[@]}" >&2
  echo "Fix: git pull your devflow clone." >&2
  exit 1
fi

if [[ ! -d "$DEV_FLOW_STATE_DIR" ]]; then
  echo "Project is not initialized." >&2
  echo "Fix:" >&2
  echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow-init-project.sh\" \"$DEV_FLOW_PROJECT_ROOT\"" >&2
  exit 1
fi

if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/source-root" ]]; then
  bound_source="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/source-root")"
  if [[ "$bound_source" != "$DEV_FLOW_SOURCE_ROOT" ]]; then
    echo "WARNING: .dev-flow/source-root points elsewhere:" >&2
    echo "  bound:   $bound_source" >&2
    echo "  running: $DEV_FLOW_SOURCE_ROOT" >&2
    echo "Rebind with dev-flow-init-project.sh after git pull." >&2
    exit 1
  fi
fi

if ! /usr/bin/grep -q 'app-launch-preflight.sh' "$DEV_FLOW_SCRIPTS_DIR/environment-health-check.sh"; then
  echo "Stale dev-flow source: environment-health-check.sh is too old." >&2
  echo "Fix: git pull your devflow clone." >&2
  exit 1
fi

debugbridge_root=""
if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-mcp-root" ]]; then
  debugbridge_root="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-mcp-root")"
fi

if [[ -n "$debugbridge_root" ]]; then
  if [[ ! -f "$debugbridge_root/src/server.js" ]]; then
    echo "WARNING: DebugBridge MCP root is bound but server.js is missing:" >&2
    echo "  $debugbridge_root" >&2
    echo "Fix: bash \"$DEV_FLOW_SOURCE_ROOT/scripts/install-debugbridge-mcp.sh\" --project \"$DEV_FLOW_PROJECT_ROOT\"" >&2
    exit 1
  fi
  if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-install.json" ]]; then
    bootstrap_required="$(DEV_FLOW_INSTALL_JSON="$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-install.json" python3 - <<'PY'
import json
import os
payload = json.load(open(os.environ["DEV_FLOW_INSTALL_JSON"], encoding="utf-8"))
print("yes" if payload.get("swift_bootstrap_required") else "no")
PY
)"
    if [[ "$bootstrap_required" == "yes" ]]; then
      echo "NOTE: LookDebugBridge Pod was added; AI/human must still run pod install and add Swift bootstrap." >&2
    fi
  fi
  echo "DebugBridge MCP: $debugbridge_root"
else
  echo "NOTE: DebugBridge MCP not bound for this app. Run install-dev-flow.sh or install-debugbridge-mcp.sh --project ..." >&2
fi

if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/review-backend.local.json" || -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/review-backend.json" || -f "$HOME/.config/dev-flow/config.json" ]]; then
  # 使用 review-backend resolver 解析当前有效配置（三层优先级 + v1 lazy 兼容）
  review_selection="$(DEV_FLOW_PROJECT_ROOT="$DEV_FLOW_PROJECT_ROOT" /usr/bin/python3 "$DEV_FLOW_SCRIPTS_DIR/lib/review_backend_resolver.py" resolve 2>/dev/null || true)"
  if [[ -n "$review_selection" ]]; then
    review_backend="$(/usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("selected_adapter","unknown"))' <<< "$review_selection" 2>/dev/null || echo "unknown")"
    review_source="$(/usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("source","unknown"))' <<< "$review_selection" 2>/dev/null || echo "unknown")"
    echo "Review adapter: $review_backend (source: $review_source)"
    # 探活 primary adapter
    # shellcheck source=lib/reviewer-readiness.sh
    source "$DEV_FLOW_SCRIPTS_DIR/lib/reviewer-readiness.sh"
    # shellcheck source=lib/review-backend-resolver.sh
    source "$DEV_FLOW_SCRIPTS_DIR/lib/review-backend-resolver.sh"
    # 从 selection JSON 提取完整 adapter config（自定义 root/skill_path/config_path 生效）
    doctor_adapter_cfg="$(/usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);a=d.get("adapters",{});cfg=a.get(sys.argv[1],{});print(json.dumps(cfg) if cfg else "")' "$review_backend" <<< "$review_selection" 2>/dev/null || true)"
    if probe_evidence="$(review_probe_adapter "$review_backend" "$doctor_adapter_cfg" 2>/dev/null)"; then
      echo "  Probe: available ($probe_evidence)"
    else
      echo "  WARNING: primary adapter 探活失败 ($probe_evidence)" >&2
      echo "  审查门禁可能阻塞；检查 adapter 配置或改用 fallback。" >&2
    fi
    # orchestrator 额外检查 root
    if [[ "$review_backend" == "mcp/orchestrator" && -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root" ]]; then
      orch_root="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root")"
      if [[ ! -x "$orch_root/codex-stdio-wrapper.sh" ]]; then
        echo "WARNING: orchestrator-mcp root is bound but not installed:" >&2
        echo "  $orch_root" >&2
        exit 1
      fi
      echo "Orchestrator MCP: $orch_root"
    fi
  else
    echo "NOTE: review config exists but resolver failed. Run install-review-backend.sh to reconfigure." >&2
  fi
else
  echo "NOTE: review backend not configured. Run install-review-backend.sh to choose an adapter." >&2
fi

# Xcode target config（.xcodebuildmcp/config.yaml）：项目级真相源。
# XcodeBuildMCP 2.x 只读 cwd/.xcodebuildmcp/config.yaml；MCP defaults 为空时，
# Agent 应先跑 xcode-target resolver 把项目配置写进 task-scoped named profile。
xcode_target_config="$DEV_FLOW_PROJECT_ROOT/.xcodebuildmcp/config.yaml"
if [[ -f "$xcode_target_config" ]]; then
  echo "Xcode target config: $xcode_target_config"
  echo "  Run 'bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" xcode-target' to resolve it for session_set_defaults."
else
  echo "NOTE: No .xcodebuildmcp/config.yaml in app root." >&2
  echo "  XcodeBuildMCP defaults are empty; provide target fields or create the config with session_set_defaults --persist." >&2
fi

LIB="$DEV_FLOW_SCRIPTS_DIR/lib"
xcodebuild_bound=0
if [[ -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/xcodebuild-mcp-install.json" ]]; then
  xcodebuild_bound=1
fi

xcodebuild_verify="$(
  python3 "$LIB/verify-xcodebuild-mcp-config.py" --platform auto --project-root "$DEV_FLOW_PROJECT_ROOT" 2>/dev/null || true
)"
xcodebuild_status="$(printf '%s\n' "$xcodebuild_verify" | sed -n 's/^status=//p' | head -n1)"
xcodebuild_workflows="$(printf '%s\n' "$xcodebuild_verify" | sed -n 's/^workflows=//p' | head -n1)"

if [[ "$xcodebuild_status" == "ok" ]]; then
  echo "XcodeBuildMCP: configured (${xcodebuild_workflows:-workflows present})"
elif [[ "$xcodebuild_bound" -eq 1 ]]; then
  echo "WARNING: XcodeBuildMCP install manifest exists but MCP client config is missing or incomplete." >&2
  printf '%s\n' "$xcodebuild_verify" | sed -n 's/^detail=//p' >&2 || true
  echo "Fix: bash \"$DEV_FLOW_SOURCE_ROOT/scripts/install-xcodebuild-mcp.sh\" --project \"$DEV_FLOW_PROJECT_ROOT\"" >&2
  exit 1
else
  echo "NOTE: XcodeBuildMCP not verified. Run install-dev-flow.sh or install-xcodebuild-mcp.sh --project ..." >&2
fi

if [[ "$xcodebuild_bound" -eq 1 ]]; then
  if [[ ! -f "$DEV_FLOW_PROJECT_ROOT/.xcodebuildmcp/config.yaml" ]]; then
    echo "WARNING: xcodebuild install manifest exists but .xcodebuildmcp/config.yaml is missing." >&2
    echo "Fix: bash \"$DEV_FLOW_SOURCE_ROOT/scripts/install-xcodebuild-mcp.sh\" --project \"$DEV_FLOW_PROJECT_ROOT\"" >&2
    exit 1
  fi
  echo "XcodeBuild project config: $DEV_FLOW_PROJECT_ROOT/.xcodebuildmcp/config.yaml"
fi

echo "PASS: central dev-flow source is current; app project binding is ready."
