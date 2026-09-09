#!/usr/bin/env bash
# Review backend resolver bash 库 — 被 install-review-backend.sh / review-health-probe.sh /
# dev-flow-doctor.sh 共用。Source only。
#
# 提供两类能力：
#   1. review_resolve — 调用 review_backend_resolver.py 执行三层优先级解析，输出 selection JSON
#   2. review_probe_adapter — 探活指定 adapter（agent/orchestrator/gstack 三种探针）
#
# 稳定 adapter IDs：agent/openai-reviewer / mcp/orchestrator / skill/gstack

# shellcheck source=lib/reviewer-readiness.sh
# reviewer-readiness.sh 由调用方在 source 本库前已 source（或通过 dev_flow_script_path 解析）。

# review_resolve [--adapter ID] [--host HOST] [--project-root PATH] [--user-config PATH] [--project-config PATH]
# 输出 selection JSON 到 stdout。fail closed 时输出 blocked JSON 并返回 1。
review_resolve() {
  local resolver_py
  resolver_py="$(dev_flow_script_path lib/review_backend_resolver.py)"
  /usr/bin/python3 "$resolver_py" resolve "$@"
}

# review_probe_adapter <adapter_id> [adapter_config_json]
# 探活指定 adapter。adapter_config_json 可含 root/skill_path 等字段，覆盖默认探测路径。
# 返回 0=可用（stdout=evidence），1=不可用（stdout=reason）。
review_probe_adapter() {
  local adapter_id="$1"
  local adapter_config="${2:-}"
  case "$adapter_id" in
    agent/openai-reviewer)
      review_probe_agent "$adapter_config"
      ;;
    mcp/orchestrator)
      review_probe_orchestrator "$adapter_config"
      ;;
    skill/gstack)
      review_probe_gstack "$adapter_config"
      ;;
    *)
      echo "unknown_adapter"
      return 1
      ;;
  esac
}

# agent/openai-reviewer 探针：opencode.json 配置存在性检查（不硬查 env key）
# agent config path 优先级（全局统一）：
#   1. DEV_FLOW_OPENCODE_CONFIG / OPENCODE_CONFIG 显式环境变量
#   2. adapter 持久化 config_path
#   3. 默认路径 ~/.config/opencode/opencode.json
review_probe_agent() {
  local adapter_config="${1:-}"
  local config_path
  # source reviewer-readiness.sh（如果还没 source）
  if ! command -v reviewer_ready >/dev/null 2>&1; then
    # shellcheck source=lib/reviewer-readiness.sh
    source "$(dev_flow_script_path lib/reviewer-readiness.sh)"
  fi
  # 优先级 1: 显式环境变量（reviewer_resolve_opencode_config 已实现 env > default）
  config_path="$(reviewer_resolve_opencode_config)"
  local env_default_path="${HOME}/.config/opencode/opencode.json"
  # 优先级 2: 若环境变量未指定（config_path == 默认路径），尝试 adapter 持久化 config_path
  if [[ "$config_path" == "$env_default_path" && -n "$adapter_config" ]]; then
    local adapter_cp
    adapter_cp="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("config_path",""))' <<< "$adapter_config" 2>/dev/null || true)"
    if [[ -n "$adapter_cp" ]]; then
      config_path="$adapter_cp"
    fi
  fi
  reviewer_ready "$config_path"
}

# mcp/orchestrator 探针：orchestrator doctor / wrapper+venv 存在性
# adapter_config 可含 root 字段覆盖探测路径（用户级 host profile 自定义 root 生效）
review_probe_orchestrator() {
  local adapter_config="${1:-}"
  local orchestrator_root=""
  # 从 adapter_config 提取 root（如有），优先于环境变量
  if [[ -n "$adapter_config" ]]; then
    orchestrator_root="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("root",""))' <<< "$adapter_config" 2>/dev/null || true)"
  fi
  if [[ -z "$orchestrator_root" ]]; then
    orchestrator_root="${ORCHESTRATOR_MCP_ROOT:-}"
  fi
  if [[ -z "$orchestrator_root" && -n "${DEV_FLOW_PROJECT_ROOT:-}" && -f "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root" ]]; then
    orchestrator_root="$(tr -d '[:space:]' < "$DEV_FLOW_PROJECT_ROOT/.dev-flow/orchestrator-mcp-root")"
  fi
  if [[ -z "$orchestrator_root" ]]; then
    # 兜底：devflow clone 同级 orchestrator-mcp
    orchestrator_root="$SOURCE_ROOT/../../orchestrator-mcp"
  fi

  local doctor="$orchestrator_root/scripts/orchestrator-doctor.sh"
  if [[ -x "$doctor" ]] && "$doctor" >/dev/null 2>&1; then
    echo "orchestrator_doctor_ok"
    return 0
  fi
  if [[ -x "$orchestrator_root/codex-stdio-wrapper.sh" && -x "$orchestrator_root/.venv/bin/python" ]]; then
    echo "orchestrator_wrapper_venv_present"
    return 0
  fi
  echo "orchestrator_unavailable"
  return 1
}

# skill/gstack 探针：使用共享 resolve_gstack_skill_path（与 run-review-fallback.sh 一致）
# adapter_config 可含 skill_path 字段覆盖探测路径（用户级 host profile 自定义 root 生效）
# 显式 skill_path：存在且可读才用；失效直接 blocked，不 fallback 到默认候选。
review_probe_gstack() {
  local adapter_config="${1:-}"
  # 从 adapter_config 提取 skill_path（如有），优先于共享解析
  if [[ -n "$adapter_config" ]]; then
    local config_skill_path
    config_skill_path="$(/usr/bin/python3 -c 'import json,sys;p=json.loads(sys.stdin.read()).get("skill_path","");print(p)' <<< "$adapter_config" 2>/dev/null || true)"
    if [[ -n "$config_skill_path" ]]; then
      # 显式 skill_path：存在且可读才用；失效直接 blocked，不 fallback 到默认候选
      if [[ -f "$config_skill_path" && -r "$config_skill_path" ]]; then
        # skill_path 指向 SKILL.md，提取目录
        echo "gstack_skill_present;$(dirname "$config_skill_path")"
        return 0
      fi
      echo "gstack_skill_missing"
      return 1
    fi
  fi
  # 无显式 skill_path，回退到共享解析
  local skill_path
  if skill_path="$(resolve_gstack_skill_path 2>/dev/null)"; then
    echo "gstack_skill_present;${skill_path}"
    return 0
  fi
  echo "gstack_skill_missing"
  return 1
}

# review_resolve_and_probe — 解析 + 探活 primary，必要时按策略探活 fallback。
# 输出 JSON：{selected_adapter, selection_reason, config_digest, probe_status, probe_evidence, ...}
# 用于 review-health-probe.sh：确定环境门 review_mcp 的 transport + fallback。
# 探活在当前 shell 上下文执行（能访问 dev_flow_script_path + 各 probe 函数）。
# adapter config 从 selection JSON 的 adapters 字段提取，传给 probe（用户级 host profile 自定义 root 生效）
review_resolve_and_probe() {
  local selection_json
  selection_json="$(review_resolve "$@")" || return 1

  # 从 selection JSON 提取字段（Python 解析，bash 无法可靠处理 JSON）
  local primary_adapter fallback_policy fallback_order_str config_digest selection_reason adapters_json
  primary_adapter="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])' <<< "$selection_json")" || return 1
  fallback_policy="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("fallback_policy","deny"))' <<< "$selection_json")" || return 1
  fallback_order_str="$(/usr/bin/python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).get("fallback_order",[])))' <<< "$selection_json")" || return 1
  config_digest="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("config_digest",""))' <<< "$selection_json")" || return 1
  selection_reason="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("selection_reason",""))' <<< "$selection_json")" || return 1
  # 提取 adapters 字段（JSON 字符串），供 probe 使用
  adapters_json="$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("adapters",{})))' <<< "$selection_json")" || return 1

  # 提取指定 adapter 的 config JSON
  get_adapter_config() {
    local adapter_id="$1"
    /usr/bin/python3 -c 'import json,sys;adapters=json.loads(sys.stdin.read());cfg=adapters.get(sys.argv[1],{});print(json.dumps(cfg) if cfg else "")' "$adapter_id" <<< "$adapters_json" 2>/dev/null || true
  }

  # 探活 primary（传入 adapter config，使自定义 root/skill_path/config_path 生效）
  local probe_evidence probe_status selected_adapter final_reason adapter_cfg
  selected_adapter="$primary_adapter"
  final_reason="$selection_reason"
  adapter_cfg="$(get_adapter_config "$primary_adapter")"
  if probe_evidence="$(review_probe_adapter "$primary_adapter" "$adapter_cfg" 2>/dev/null)"; then
    probe_status="available"
  else
    probe_status="unavailable"
    # primary 不可用 + 允许 fallback → 按顺序探活 fallback
    if [[ "$fallback_policy" == "allow" ]]; then
      local fb fb_cfg
      while IFS= read -r fb; do
        [[ -z "$fb" ]] && continue
        fb_cfg="$(get_adapter_config "$fb")"
        if probe_evidence="$(review_probe_adapter "$fb" "$fb_cfg" 2>/dev/null)"; then
          selected_adapter="$fb"
          final_reason="primary_unavailable;fallback=$fb"
          probe_status="available"
          break
        fi
      done <<< "$fallback_order_str"
    fi
  fi

  # 输出最终 JSON（合并 selection + probe 结果）
  /usr/bin/python3 - "$selection_json" "$selected_adapter" "$final_reason" "$config_digest" "$probe_status" "$probe_evidence" <<'PYEOF'
import json
import sys

selection = json.loads(sys.argv[1])
result = dict(selection)
result["selected_adapter"] = sys.argv[2]
result["selection_reason"] = sys.argv[3]
result["config_digest"] = sys.argv[4]
result["probe_status"] = sys.argv[5]
result["probe_evidence"] = sys.argv[6]
print(json.dumps(result, ensure_ascii=False))
PYEOF
}
