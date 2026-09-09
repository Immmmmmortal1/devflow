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

# XcodeBuildMCP 原子链必须包含 session_set_defaults（合法补齐空 profile 的动作）
require_text "$TOP_SKILL" 'session_set_defaults' 'XcodeBuildMCP atomic chain missing session_set_defaults'
if ! /usr/bin/grep -qF 'tool_search("XcodeBuildMCP session_set_defaults session_show_defaults build_run_device device iOS")' "$TOP_SKILL"; then
  echo "FAIL: XcodeBuildMCP tool_search query must include session_set_defaults" >&2
  exit 1
fi
if ! /usr/bin/grep -qF 'tool_search("XcodeBuildMCP session_set_defaults session_show_defaults build_run_sim simulator iOS")' "$TOP_SKILL"; then
  echo "FAIL: XcodeBuildMCP tool_search query must include the simulator build_run_sim variant" >&2
  exit 1
fi
if ! /usr/bin/grep -qF 'tool_search("XcodeBuildMCP session_set_defaults session_show_defaults build_run_device device iOS")' "$HEALTH_SKILL"; then
  echo "FAIL: environment-health-check tool_search query must include session_set_defaults" >&2
  exit 1
fi
if ! /usr/bin/grep -qF 'tool_search("XcodeBuildMCP session_set_defaults session_show_defaults build_run_sim simulator iOS")' "$HEALTH_SKILL"; then
  echo "FAIL: environment-health-check tool_search query must include the simulator build_run_sim variant" >&2
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
