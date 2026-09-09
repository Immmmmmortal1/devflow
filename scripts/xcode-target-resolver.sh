#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"

# 只读 resolver：从 <app-root>/.xcodebuildmcp/config.yaml 读取 sessionDefaults，
# 解析相对路径，输出 bounded JSON 给 Agent 用于 XcodeBuildMCP session_set_defaults。
# 不自动扫描设备；缺配置/缺字段/路径不匹配时 blocked 并给 exact reason。
exec /usr/bin/python3 "$(dev_flow_script_path xcode-target-resolver.py)" "$@"
