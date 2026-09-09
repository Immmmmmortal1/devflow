#!/usr/bin/env bash
# 审查角色（agent/openai-reviewer）可用性判定 + gstack skill 路径解析。Source only。
# 被 review-backend-resolver.sh / install-review-backend.sh / review-health-probe.sh /
# run-review-fallback.sh / dev-flow-doctor.sh 共用。
#
# 判定逻辑：opencode.json（或 DEV_FLOW_OPENCODE_CONFIG / OPENCODE_CONFIG 指定的配置路径）
# 含 agent "openai-reviewer"（非空对象）且其 provider/apiKey 配置完整。
# 不硬查环境变量 OPENROUTER_API_KEY：key 运行时解析与校验交给 opencode 自身
# （Agent 实际调用时若 key 缺失 opencode 会报错），使门禁判定与"agent 实际可用"一致。

# resolve_skills_root — 统一解析 skills root 目录。
# review-health-probe.sh 和 run-review-fallback.sh 共用此函数，防止 health pass 但 runner fail。
# 优先级：OPENCODE_SKILLS_ROOT > CURSOR_SKILLS_ROOT > CODEX_SKILLS_ROOT >
#         宿主信号推断（opencode → ~/.config/opencode/skills, cursor → ~/.cursor/skills, codex → ~/.codex/skills）
resolve_skills_root() {
  if [[ -n "${OPENCODE_SKILLS_ROOT:-}" ]]; then
    printf '%s\n' "$OPENCODE_SKILLS_ROOT"
    return 0
  fi
  if [[ -n "${CURSOR_SKILLS_ROOT:-}" ]]; then
    printf '%s\n' "$CURSOR_SKILLS_ROOT"
    return 0
  fi
  if [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
    printf '%s\n' "$CODEX_SKILLS_ROOT"
    return 0
  fi
  # 宿主信号推断（不使用目录存在性判断宿主，只推断 skills root）
  if [[ -n "${OPENCODE:-}" ]]; then
    printf '%s\n' "${HOME}/.config/opencode/skills"
    return 0
  fi
  if [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
    printf '%s\n' "${HOME}/.cursor/skills"
    return 0
  fi
  if [[ -n "${CODEX_HOME:-}" ]]; then
    printf '%s\n' "${CODEX_HOME}/skills"
    return 0
  fi
  printf '%s\n' "${HOME}/.codex/skills"
}

# resolve_gstack_skill_path — 统一解析 gstack review SKILL.md 路径。
# review-health-probe.sh 和 run-review-fallback.sh 共用，防止 health pass 但 runner fail。
# 候选路径顺序与 resolve_skills_root 一致，额外支持 GSTACK_REVIEW_SKILL_ROOT 和 ~/.claude/skills。
# 输出：gstack skill 目录路径（不含 /SKILL.md），或空字符串+return 1。
resolve_gstack_skill_path() {
  local skills_root
  skills_root="$(resolve_skills_root)"
  local candidate
  for candidate in \
    "${GSTACK_REVIEW_SKILL_ROOT:-}" \
    "$skills_root/gstack/review" \
    "${HOME}/.config/opencode/skills/gstack/review" \
    "${HOME}/.claude/skills/gstack/review" \
    "${HOME}/.codex/skills/gstack/review" \
    "${HOME}/.cursor/skills/gstack/review"; do
    if [[ -n "$candidate" && -f "$candidate/SKILL.md" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

reviewer_resolve_opencode_config() {
  # 返回 opencode.json 路径（DEV_FLOW_OPENCODE_CONFIG / OPENCODE_CONFIG 优先，否则默认）。
  if [[ -n "${DEV_FLOW_OPENCODE_CONFIG:-${OPENCODE_CONFIG:-}}" ]]; then
    printf '%s\n' "${DEV_FLOW_OPENCODE_CONFIG:-${OPENCODE_CONFIG:-}}"
  else
    printf '%s\n' "${HOME}/.config/opencode/opencode.json"
  fi
}

# reviewer_ready [config_path]
# 判定 openai-reviewer 是否在 opencode.json 中配置完整（与 opencode 运行时对齐）：
#   1. opencode.json 可解析且为对象；
#   2. agent "openai-reviewer" 存在且为非空对象（兼容顶层单数 agent / 复数 agents / 顶层平铺三种结构）；
#   3. agent 的 model 形如 "<provider>/<model>"，且 opencode.json 顶层 provider[<provider>] 为非空对象；
#   4. 该 provider 的 options.apiKey 配置存在（含 "{env:XXX}" 引用格式，花括号引用也算合法）。
# 返回 0=可用，1=不可用；向 stdout 打印一行诊断 evidence。
reviewer_ready() {
  local config_path="${1:-}"
  if [[ -z "$config_path" ]]; then
    config_path="$(reviewer_resolve_opencode_config)"
  fi

  if [[ ! -f "$config_path" ]]; then
    printf '%s\n' "opencode_config_missing"
    return 1
  fi

  /usr/bin/python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    print("opencode_config_invalid_json")
    raise SystemExit(1)

if not isinstance(payload, dict):
    print("opencode_config_not_object")
    raise SystemExit(1)

# agent 查找兼容三种结构（顺序）：顶层 agent（单数，opencode 真实键）→
# 顶层 agents（复数，容错）→ 顶层平铺 openai-reviewer（早期写法容错）。
value = None
if isinstance(payload.get("agent"), dict) and "openai-reviewer" in payload["agent"]:
    value = payload["agent"]["openai-reviewer"]
elif isinstance(payload.get("agents"), dict) and "openai-reviewer" in payload["agents"]:
    value = payload["agents"]["openai-reviewer"]
elif "openai-reviewer" in payload:
    value = payload["openai-reviewer"]
else:
    print("openai_reviewer_missing")
    raise SystemExit(1)

# openai-reviewer 的值必须是非空 JSON 对象（dict）；null / 非对象 / 空 dict {} 均不可用。
if value is None:
    print("openai_reviewer_null")
    raise SystemExit(1)
if not isinstance(value, dict):
    print("openai_reviewer_not_object")
    raise SystemExit(1)
if len(value) == 0:
    print("openai_reviewer_empty")
    raise SystemExit(1)

# provider 存在性检查：从 agent 配置读 model，取 "/" 前的 provider 名，
# 要求顶层 provider[<provider名>] 是非空 dict（代表审查角色已配置模型通路）。
model = value.get("model")
if not isinstance(model, str) or not model:
    print("reviewer_model_missing")
    raise SystemExit(1)

# model 必须包含 "/" 分隔符，且 provider 和 model 部分均非空
# （形如 "provider/model"，拒绝 "noprovider"、"/model"、"provider/"）
# model 部分本身可以包含 "/"（如 "openai/gpt-5.5"），只检查第一个 "/" 分隔
if "/" not in model:
    print("reviewer_model_invalid_format")
    raise SystemExit(1)
provider_name, model_name = model.split("/", 1)
if not provider_name.strip() or not model_name.strip():
    print("reviewer_model_invalid_format")
    raise SystemExit(1)

providers = payload.get("provider")
if not isinstance(providers, dict) or provider_name not in providers:
    print("reviewer_provider_missing")
    raise SystemExit(1)

provider_cfg = providers[provider_name]
if not isinstance(provider_cfg, dict) or len(provider_cfg) == 0:
    print("reviewer_provider_missing")
    raise SystemExit(1)

# key 判定放宽：provider 的 options.apiKey 配置存在即可（含 "{env:XXX}" 引用格式，
# 花括号引用也算配置合法）；key 运行时解析与校验交给 opencode 自身。
options = provider_cfg.get("options")
if not isinstance(options, dict):
    print("reviewer_apikey_missing")
    raise SystemExit(1)
apikey = options.get("apiKey")
if not isinstance(apikey, str) or not apikey:
    print("reviewer_apikey_missing")
    raise SystemExit(1)

print("reviewer_available")
PY
}
