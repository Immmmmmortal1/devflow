#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-flow-init-project.sh [app-project-root]

Register an iOS app repo with the central dev-flow clone. Creates only:
  <app>/.dev-flow/source-root
  <app>/.dev-flow/sessions/

Gate scripts stay in the dev-flow git clone. App repos do NOT get a scripts/ copy.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  export DEV_FLOW_PROJECT_ROOT="$1"
fi

dev_flow_load_paths "$SCRIPT_PATH"

PROJECT_ROOT="$DEV_FLOW_PROJECT_ROOT"
STATE_DIR="$PROJECT_ROOT/.dev-flow"
SOURCE_FILE="$STATE_DIR/source-root"

# 安全检查：PROJECT_ROOT 和 .dev-flow 不能是 symlink
if [[ -L "$PROJECT_ROOT" ]]; then
  echo "ERROR: refusing to write through symlinked PROJECT_ROOT: $PROJECT_ROOT" >&2
  exit 1
fi
if [[ -L "$STATE_DIR" ]]; then
  echo "ERROR: refusing to write through symlinked .dev-flow: $STATE_DIR" >&2
  exit 1
fi

# 安全写入（使用 atomic_json_write safe 函数）
/usr/bin/python3 - "$PROJECT_ROOT" "$STATE_DIR" "$SOURCE_FILE" "$DEV_FLOW_SOURCE_ROOT" "$DEV_FLOW_SOURCE_ROOT" <<'PY'
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
state_dir = Path(sys.argv[2])
source_file = Path(sys.argv[3])
dev_flow_source_root = sys.argv[4]
devflow_root = Path(sys.argv[5])

sys.path.insert(0, str(devflow_root / "scripts" / "lib"))
from atomic_json_write import safe_mkdir, safe_write_text

# 安全创建 .dev-flow/sessions（trusted_root = PROJECT_ROOT，逐级 lstat 检查）
safe_mkdir(project_root, state_dir / "sessions")

# 安全写入 source-root
safe_write_text(state_dir, source_file, dev_flow_source_root + "\n", mode=0o644)
PY

echo "Initialized dev-flow project binding:"
echo "  app:    $PROJECT_ROOT"
echo "  source: $DEV_FLOW_SOURCE_ROOT"
echo
echo "Run gates from the app repo with:"
echo "  cd \"$PROJECT_ROOT\""
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" doctor"
if [[ -f "$PROJECT_ROOT/.xcodebuildmcp/config.yaml" ]]; then
  echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" xcode-target  # resolve .xcodebuildmcp/config.yaml"
else
  echo "  # No .xcodebuildmcp/config.yaml: create it or provide target fields to session_set_defaults."
fi
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" app-launch status || bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" app-launch instructions"
echo "  # after XcodeBuildMCP session_set_defaults + session_show_defaults + build_run_device|build_run_sim (resolver launch_action) succeeds:"
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" app-launch record --report <bounded-xcodebuildmcp-json|->"
echo "  bash \"$DEV_FLOW_SOURCE_ROOT/scripts/dev-flow.sh\" environment-health run"
