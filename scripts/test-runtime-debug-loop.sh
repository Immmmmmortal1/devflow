#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP_SKILL="$ROOT/SKILL.md"
RUNTIME_SKILL="$ROOT/skills/runtime-debug-workflow/SKILL.md"
HEALTH_SKILL="$ROOT/skills/environment-health-check/SKILL.md"

require_text() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_text "$TOP_SKILL" 'runtime-debug-workflow' 'dev-flow must delegate runtime validation'
require_text "$TOP_SKILL" 'automated development loop' 'missing automated development loop positioning'
require_text "$TOP_SKILL" 'runtime-verified|runtime-failed|runtime-blocked' 'missing runtime result contract'

if grep -Eq 'get_debug_page|tap_element|read_app_logs|wait_app_logs|inspect_ui' "$TOP_SKILL"; then
  echo "FAIL: runtime tool procedures must not be duplicated in dev-flow" >&2
  exit 1
fi

# XcodeBuildMCP 原子链必须包含 session_set_defaults → session_show_defaults → build_run_device|build_run_sim
#（session_set_defaults 是合法补齐空 profile 的动作；不再依赖 tool_search 暴露工具）
require_text "$TOP_SKILL" 'session_set_defaults' 'XcodeBuildMCP atomic chain missing session_set_defaults'
require_text "$TOP_SKILL" 'session_show_defaults' 'XcodeBuildMCP atomic chain missing session_show_defaults'
require_text "$TOP_SKILL" 'build_run_device' 'XcodeBuildMCP atomic chain missing build_run_device'
require_text "$TOP_SKILL" 'build_run_sim' 'XcodeBuildMCP atomic chain missing build_run_sim'
require_text "$HEALTH_SKILL" 'session_set_defaults' 'environment-health-check atomic chain missing session_set_defaults'
require_text "$HEALTH_SKILL" 'session_show_defaults' 'environment-health-check atomic chain missing session_show_defaults'
require_text "$HEALTH_SKILL" 'build_run_device' 'environment-health-check atomic chain missing build_run_device'
require_text "$HEALTH_SKILL" 'build_run_sim' 'environment-health-check atomic chain missing build_run_sim'

# 仓库正式流程文件中不得残留 tool_search（强制依赖已移除，改用"确认可调用"语义）
for flow_file in "$TOP_SKILL" "$HEALTH_SKILL" "$RUNTIME_SKILL" "$ROOT/README.md" \
  "$ROOT/scripts/app-launch-preflight.sh" "$ROOT/scripts/install-dev-flow.sh" \
  "$ROOT/scripts/install-xcodebuild-mcp.sh"; do
  if /usr/bin/grep -qF 'tool_search' "$flow_file"; then
    echo "FAIL: $flow_file must not retain tool_search dependency" >&2
    exit 1
  fi
done

# app-launch-preflight.sh 必须保留 simulator 分支（build_run_sim + simulator transport），
# 不能只硬编码 build_run_device+wired
if ! /usr/bin/grep -qF 'build_run_sim' "$ROOT/scripts/app-launch-preflight.sh"; then
  echo "FAIL: app-launch-preflight.sh must retain simulator branch (build_run_sim)" >&2
  exit 1
fi
if ! /usr/bin/grep -qF '"device_transport": "simulator"' "$ROOT/scripts/app-launch-preflight.sh"; then
  echo "FAIL: app-launch-preflight.sh template must include simulator transport" >&2
  exit 1
fi
# 缺失报告的 required_tools 必须提示两种 launch action（不知道目标时）
if ! /usr/bin/grep -qF 'build_run_device|build_run_sim' "$ROOT/scripts/app-launch-preflight.sh"; then
  echo "FAIL: app-launch-preflight.sh missing report must list both launch actions" >&2
  exit 1
fi

# 不得再有"绝对禁止模拟器"旧语义；但必须保留禁止 silent fallback / 自动换设备语义
if /usr/bin/grep -qF 'do not switch to simulator as a workaround' "$TOP_SKILL"; then
  echo "FAIL: SKILL.md still has absolute simulator ban wording" >&2
  exit 1
fi
require_text "$TOP_SKILL" 'unconfirmed simulator fallback' 'missing silent-fallback prohibition'
require_text "$ROOT/rules/global-rules.md" '选定目标（有线真机或显式指定模拟器）' 'global rules must allow explicit Simulator target'
require_text "$ROOT/skills/ui-review/SKILL.md" 'chosen target \(wired physical device or explicit Simulator\)' 'ui-review must allow explicit Simulator target'

require_text "$RUNTIME_SKILL" 'XcodeBuildMCP' 'missing on-device build/run guidance'
require_text "$RUNTIME_SKILL" 'get_debug_page|tap_element' 'missing autonomous UI interaction guidance'
require_text "$RUNTIME_SKILL" 'inspect_ui' 'missing UIWindow/UIView inspection guidance'
require_text "$RUNTIME_SKILL" 'read_app_logs|wait_app_logs' 'missing current-run App log-pool guidance'
require_text "$RUNTIME_SKILL" '#if DEBUG|DEBUG-only' 'missing compile-time Debug logging boundary'
require_text "$RUNTIME_SKILL" 'redact|脱敏' 'missing sensitive-data redaction requirement'
require_text "$RUNTIME_SKILL" 'bounded|truncate|截断' 'missing bounded payload requirement'
require_text "$RUNTIME_SKILL" 'cursor|persisted|persistent|不持久化' 'missing no-duplicate-log-storage requirement'
require_text "$RUNTIME_SKILL" 'confirm-gate' 'runtime diagnostics must not bypass source-edit approval'
require_text "$RUNTIME_SKILL" 'Rebuild and rerun|rebuild.*rerun|重新' 'missing rebuild-and-rerun loop'

echo "PASS: dev-flow delegates runtime validation to runtime-debug-workflow"
