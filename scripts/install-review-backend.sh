#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dev-flow-paths.sh
source "$ROOT/scripts/lib/dev-flow-paths.sh"
# shellcheck source=lib/reviewer-readiness.sh
source "$ROOT/scripts/lib/reviewer-readiness.sh"
# shellcheck source=lib/review-backend-resolver.sh
source "$ROOT/scripts/lib/review-backend-resolver.sh"

ORCHESTRATOR_REPO="${DEV_FLOW_ORCHESTRATOR_MCP_REPO:-https://github.com/Immmmmmortal1/orchestrator-mcp.git}"
GSTACK_REPO="${DEV_FLOW_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
PLATFORM=""
PROJECT_ROOT=""
SKILLS_ROOT=""
REVIEW_BACKEND=""
SAVE_LEVEL="project"
SKIP_MCP_CONFIG=0
ORCHESTRATOR_ROOT=""
FALLBACK_ORCH_ROOT=""
FALLBACK_GSTACK_SKILL_PATH=""

# 稳定 adapter IDs
ADAPTER_AGENT="agent/openai-reviewer"
ADAPTER_ORCH="mcp/orchestrator"
ADAPTER_GSTACK="skill/gstack"

usage() {
  cat <<EOF
Usage:
  bash scripts/install-review-backend.sh [--cursor | --codex | --opencode]
    [--project <app-root>] [--skills-root <path>]
    [--review-backend <adapter-id|alias>] [--orchestrator-root <path>] [--skip-mcp-config]
    [--fallback-orchestrator-root <path>] [--fallback-gstack-skill-path <path>]
    [--save-level user|project]

Install dev-flow review backend for the environment-health review_mcp gate.

Adapter IDs (stable, schema v2):
  agent/openai-reviewer  — 审查角色（opencode subagent @openai-reviewer，配置存在性探活）
  mcp/orchestrator       — orchestrator-mcp（独立 Review Hub MCP，需配置 API Key）
  skill/gstack           — gstack-review（轻量 fallback，gstack /review skill）

v1 aliases (lazy 兼容，自动迁移到 v2 adapter ID):
  reviewer → agent/openai-reviewer
  orchestrator → mcp/orchestrator
  gstack → skill/gstack

Fallback adapter 自定义路径（不指定则从已有 config 保留或用 resolved 值）:
  --fallback-orchestrator-root <path>    fallback mcp/orchestrator 的自定义 root
  --fallback-gstack-skill-path <path>    fallback skill/gstack 的自定义 skill_path

Interactive wizard runs when stdin is a TTY and --review-backend is omitted.
Non-interactive without a valid selection (CLI / env DEV_FLOW_REVIEW_BACKEND / existing config)
fails closed with guidance; it does NOT silently guess a default.

New writes use schema v2 (*.local.json for project, ~/.config/dev-flow/config.json for user).
Config files never store API keys — only adapter names, identifiers, and path/env references.

Examples:
  bash scripts/install-review-backend.sh
  bash scripts/install-review-backend.sh --review-backend agent/openai-reviewer
  bash scripts/install-review-backend.sh --opencode --review-backend reviewer
  bash scripts/install-review-backend.sh --cursor --project ~/MyApp --review-backend mcp/orchestrator
EOF
}

gstack_review_installed() {
  local root="$1"
  [[ -f "$root/gstack/review/SKILL.md" ]]
}

find_gstack_review_source() {
  local gstack_root="$1"
  local candidate=""
  for candidate in \
    "$gstack_root/review/SKILL.md" \
    "${GSTACK_REPO_ROOT:-}/review/SKILL.md" \
    "$HOME/.gstack/repos/gstack/review/SKILL.md"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd)/SKILL.md"
      return 0
    fi
  done
  return 1
}

link_gstack_review_skill() {
  local source="$1"
  local dest="$SKILLS_ROOT/gstack/review/SKILL.md"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "ERROR: $dest exists and is not a symlink" >&2
    exit 1
  fi
  ln -sf "$source" "$dest"
  echo "Linked gstack-review: $dest -> $source"
}

orchestrator_installed() {
  local orch_root="$1"
  [[ -x "$orch_root/codex-stdio-wrapper.sh" && -x "$orch_root/.venv/bin/python" ]]
}

# v1 alias → v2 adapter ID
normalize_backend() {
  case "$1" in
    reviewer|openai-reviewer|agent/openai-reviewer)
      printf '%s\n' "$ADAPTER_AGENT"
      ;;
    orchestrator|orchestrator-mcp|mcp|mcp/orchestrator)
      printf '%s\n' "$ADAPTER_ORCH"
      ;;
    gstack|gstack-review|review|skill/gstack)
      printf '%s\n' "$ADAPTER_GSTACK"
      ;;
    *)
      echo "Unknown review backend: $1" >&2
      echo "Valid: agent/openai-reviewer | mcp/orchestrator | skill/gstack" >&2
      echo "(v1 aliases: reviewer | orchestrator | gstack)" >&2
      exit 2
      ;;
  esac
}

default_backend_for_platform() {
  case "$1" in
    opencode) printf '%s\n' "$ADAPTER_AGENT" ;;
    *) printf '%s\n' "$ADAPTER_ORCH" ;;
  esac
}

# ── 交互向导 ──
wizard_prompt_host() {
  if [[ -n "$PLATFORM" ]]; then return 0; fi
  cat <<'PROMPT'

dev-flow Review 配置向导 — 步骤 1/6：选择宿主

  1) opencode — opencode subagent（agent/openai-reviewer）
  2) cursor   — Cursor IDE
  3) codex    — Codex CLI

PROMPT
  local choice=""
  while true; do
    read -r -p "请选择 [1/2/3]: " choice
    case "$choice" in
      1|opencode) PLATFORM="opencode"; break ;;
      2|cursor) PLATFORM="cursor"; break ;;
      3|codex) PLATFORM="codex"; break ;;
      *) echo "请输入 1、2 或 3。" ;;
    esac
  done
}

wizard_prompt_primary() {
  if [[ -n "$REVIEW_BACKEND" ]]; then
    REVIEW_BACKEND="$(normalize_backend "$REVIEW_BACKEND")"
    return 0
  fi
  local default_backend default_choice
  default_backend="$(default_backend_for_platform "$PLATFORM")"
  case "$default_backend" in
    "$ADAPTER_AGENT") default_choice=1 ;;
    "$ADAPTER_ORCH") default_choice=2 ;;
    *) default_choice=3 ;;
  esac
  cat <<PROMPT

dev-flow Review 配置向导 — 步骤 2/6：选择首选 Review adapter

  1) agent/openai-reviewer — 审查角色（opencode subagent @openai-reviewer）
     需在 ~/.config/opencode/opencode.json 配置 agent openai-reviewer 及其 provider/apiKey
  2) mcp/orchestrator — orchestrator-mcp（独立 Review Hub MCP，需配置 API Key）
     https://github.com/Immmmmmortal1/orchestrator-mcp
  3) skill/gstack — gstack-review（轻量 fallback，gstack /review skill）

PROMPT
  local choice=""
  while true; do
    read -r -p "请选择 [1/2/3]（默认 $default_choice）: " choice
    choice="${choice:-$default_choice}"
    case "$choice" in
      1) REVIEW_BACKEND="$ADAPTER_AGENT"; break ;;
      2) REVIEW_BACKEND="$ADAPTER_ORCH"; break ;;
      3) REVIEW_BACKEND="$ADAPTER_GSTACK"; break ;;
      *) echo "请输入 1、2 或 3。" ;;
    esac
  done
}

wizard_prompt_identifier() {
  # 询问 adapter-specific identifier（agent 名 / MCP server 名 / skill 路径）
  # 大多数场景用默认值即可，这里只做信息展示 + 确认。
  cat <<PROMPT

dev-flow Review 配置向导 — 步骤 3/6：adapter 标识确认

PROMPT
  case "$REVIEW_BACKEND" in
    "$ADAPTER_AGENT")
      echo "  adapter: agent/openai-reviewer"
      echo "  agent 名: openai-reviewer（opencode subagent 标准名，不可改）"
      echo "  配置路径: $(reviewer_resolve_opencode_config)"
      ;;
    "$ADAPTER_ORCH")
      echo "  adapter: mcp/orchestrator"
      echo "  MCP server 名: orchestrator-mcp"
      echo "  安装路径: ${ORCHESTRATOR_ROOT:-<devflow clone 同级>/orchestrator-mcp}"
      ;;
    "$ADAPTER_GSTACK")
      echo "  adapter: skill/gstack"
      echo "  skill 路径: $SKILLS_ROOT/gstack/review/SKILL.md"
      ;;
  esac
  echo ""
}

wizard_prompt_fallback() {
  cat <<PROMPT

dev-flow Review 配置向导 — 步骤 4/6：pre-dispatch fallback 策略

  primary adapter 在 dispatch 前不可用时，是否允许自动切换到 fallback adapter？
  （dispatch 开始后一律不允许切换 adapter）

  1) allow — 允许 pre-dispatch fallback（推荐）
  2) deny  — 禁止，primary 不可用则阻塞

PROMPT
  local choice=""
  while true; do
    read -r -p "请选择 [1/2]（默认 1）: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) FALLBACK_POLICY="allow"; break ;;
      2) FALLBACK_POLICY="deny"; break ;;
      *) echo "请输入 1 或 2。" ;;
    esac
  done
}

wizard_prompt_fallback_order() {
  FALLBACK_ORDER=""
  if [[ "$FALLBACK_POLICY" != "allow" ]]; then
    return 0
  fi
  # 列出除 primary 外的已知 adapter，让用户排序
  local remaining=()
  for a in "$ADAPTER_AGENT" "$ADAPTER_ORCH" "$ADAPTER_GSTACK"; do
    [[ "$a" != "$REVIEW_BACKEND" ]] && remaining+=("$a")
  done
  if [[ ${#remaining[@]} -eq 0 ]]; then return 0; fi
  cat <<PROMPT

dev-flow Review 配置向导 — 步骤 5/6：fallback 顺序

  可选 fallback adapter（primary=$REVIEW_BACKEND 不可用时按此顺序尝试）：
PROMPT
  local i=1
  for a in "${remaining[@]}"; do
    echo "  $i) $a"
    i=$((i + 1))
  done
  echo ""
  local choice=""
  read -r -p "按顺序输入编号（如全选用默认顺序直接回车）: " choice
  if [[ -z "$choice" ]]; then
    FALLBACK_ORDER="$(IFS=,; printf '%s' "${remaining[*]}")"
  else
    # 解析用户输入的顺序
    local sorted=()
    local used=()
    for n in $choice; do
      case "$n" in
        *[!0-9]*) continue ;;
      esac
      local idx=$((n - 1))
      if [[ $idx -ge 0 && $idx -lt ${#remaining[@]} ]]; then
        sorted+=("${remaining[$idx]}")
      fi
    done
    if [[ ${#sorted[@]} -gt 0 ]]; then
      FALLBACK_ORDER="$(IFS=,; printf '%s' "${sorted[*]}")"
    else
      FALLBACK_ORDER="$(IFS=,; printf '%s' "${remaining[*]}")"
    fi
  fi
}

wizard_prompt_save_level() {
  cat <<PROMPT

dev-flow Review 配置向导 — 步骤 6/6：保存层级

  1) project — 保存到 <app>/.dev-flow/review-backend.local.json（仅当前项目）
  2) user    — 保存到 ~/.config/dev-flow/config.json（当前宿主的全局 profile）

PROMPT
  local choice=""
  while true; do
    read -r -p "请选择 [1/2]（默认 1）: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) SAVE_LEVEL="project"; break ;;
      2) SAVE_LEVEL="user"; break ;;
      *) echo "请输入 1 或 2。" ;;
    esac
  done
}

# ── 安装函数 ──
install_reviewer() {
  local config_path
  config_path="$(reviewer_resolve_opencode_config)"

  # 如果环境没指定自定义路径，尝试从已有 config 读取 config_path
  # （与 make_adapter 的选择顺序一致：env custom → existing config_path → default）
  local oc_default_path="${HOME}/.config/opencode/opencode.json"
  if [[ "$config_path" == "$oc_default_path" ]]; then
    # 环境未指定自定义路径，检查已有项目级和用户级 config 是否有 config_path
    local existing_config_path=""
    # 项目级配置优先
    if [[ -n "${PROJECT_ROOT:-}" && -f "$PROJECT_ROOT/.dev-flow/review-backend.local.json" ]]; then
      existing_config_path="$(/usr/bin/python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    a = c.get("adapters", {}).get("agent/openai-reviewer", {})
    print(a.get("config_path", ""))
except Exception:
    print("")
' "$PROJECT_ROOT/.dev-flow/review-backend.local.json" 2>/dev/null || true)"
    fi
    # 用户级配置兜底
    if [[ -z "$existing_config_path" && -f "$HOME/.config/dev-flow/config.json" ]]; then
      existing_config_path="$(/usr/bin/python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    h = c.get("hosts", {}).get("opencode", {})
    a = h.get("adapters", {}).get("agent/openai-reviewer", {})
    print(a.get("config_path", ""))
except Exception:
    print("")
' "$HOME/.config/dev-flow/config.json" 2>/dev/null || true)"
    fi
    if [[ -n "$existing_config_path" ]]; then
      config_path="$existing_config_path"
    fi
  fi

  if reviewer_ready "$config_path"; then
    echo "审查角色可用（openai-reviewer 配置完整）"
    return 0
  fi
  cat <<ERR >&2
ERROR: 审查角色（@openai-reviewer）不可用。需要：
  1. 在 $config_path 中配置 agent "openai-reviewer"
     （或通过 DEV_FLOW_OPENCODE_CONFIG / OPENCODE_CONFIG 指定其他配置路径）
  2. 配置 agent 的 model（形如 <provider>/<model>）及对应 provider 段的 options.apiKey
     （apiKey 可用 "{env:XXX}" 引用格式；key 运行时解析交给 opencode）
修复后重试，或改用 --review-backend mcp/orchestrator 或 skill/gstack。
ERR
  exit 1
}

install_orchestrator() {
  if [[ -z "$ORCHESTRATOR_ROOT" ]]; then
    ORCHESTRATOR_ROOT="$(cd "$ROOT/.." && pwd)/orchestrator-mcp"
  fi
  ORCHESTRATOR_ROOT="$(cd "$(dirname "$ORCHESTRATOR_ROOT")" && pwd)/$(basename "$ORCHESTRATOR_ROOT")"
  mkdir -p "$(dirname "$ORCHESTRATOR_ROOT")"
  if [[ -d "$ORCHESTRATOR_ROOT/.git" ]]; then
    echo "Updating orchestrator-mcp at $ORCHESTRATOR_ROOT"
    current_branch="$(git -C "$ORCHESTRATOR_ROOT" symbolic-ref -q --short HEAD || true)"
    git -C "$ORCHESTRATOR_ROOT" fetch origin
    if [[ -n "$current_branch" ]]; then
      git -C "$ORCHESTRATOR_ROOT" pull --ff-only origin "$current_branch" || {
        echo "WARNING: could not fast-forward $ORCHESTRATOR_ROOT; using existing checkout." >&2
      }
    fi
  elif [[ -x "$ORCHESTRATOR_ROOT/codex-stdio-wrapper.sh" ]]; then
    echo "Using existing orchestrator-mcp at $ORCHESTRATOR_ROOT"
  else
    echo "Cloning orchestrator-mcp into $ORCHESTRATOR_ROOT"
    git clone "$ORCHESTRATOR_REPO" "$ORCHESTRATOR_ROOT"
  fi

  if [[ -x "$ORCHESTRATOR_ROOT/ensure-venv.sh" ]]; then
    bash "$ORCHESTRATOR_ROOT/ensure-venv.sh" >/dev/null
  fi
  if [[ -f "$ORCHESTRATOR_ROOT/codex-stdio-wrapper.sh" ]]; then
    chmod +x "$ORCHESTRATOR_ROOT/codex-stdio-wrapper.sh"
  fi

  if [[ "$SKIP_MCP_CONFIG" -eq 0 ]]; then
    if [[ "$PLATFORM" == "cursor" ]]; then
      MCP_CONFIG_PATH="${CURSOR_MCP_CONFIG:-$HOME/.cursor/mcp.json}"
    else
      MCP_CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
    fi
    python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
      --platform "$PLATFORM" \
      --wrapper-path "$ORCHESTRATOR_ROOT/codex-stdio-wrapper.sh" \
      --pythonpath "$ORCHESTRATOR_ROOT/src" \
      --config-path "$MCP_CONFIG_PATH"
  fi
}

install_gstack_review() {
  local gstack_root="$SKILLS_ROOT/gstack"
  if gstack_review_installed "$SKILLS_ROOT"; then
    echo "gstack-review already present: $SKILLS_ROOT/gstack/review/SKILL.md"
    return 0
  fi

  echo "Installing gstack-review under $SKILLS_ROOT/gstack"
  mkdir -p "$SKILLS_ROOT"

  local review_source=""
  if review_source="$(find_gstack_review_source "$gstack_root")"; then
    link_gstack_review_skill "$review_source"
    return 0
  fi

  if [[ ! -d "$gstack_root/.git" ]]; then
    if [[ -e "$gstack_root" ]]; then
      echo "NOTE: $gstack_root exists without review/SKILL.md; cloning gstack alongside it is skipped." >&2
      echo "ERROR: could not locate gstack review/SKILL.md (checked ~/.gstack/repos/gstack and $gstack_root)" >&2
      exit 1
    fi
    git clone --single-branch --depth 1 "$GSTACK_REPO" "$gstack_root"
  fi

  if [[ ! -f "$gstack_root/review/SKILL.md" ]]; then
    echo "ERROR: gstack clone missing review/SKILL.md at $gstack_root" >&2
    exit 1
  fi

  if [[ -x "$gstack_root/setup" ]] && command -v bun >/dev/null 2>&1; then
    echo "Running gstack setup for $PLATFORM host (optional binaries)..."
    case "$PLATFORM" in
      cursor) (cd "$gstack_root" && ./setup --host claude -q) || echo "WARNING: gstack setup failed; review skill is still available." >&2 ;;
      codex|opencode) (cd "$gstack_root" && ./setup --host codex -q) || echo "WARNING: gstack setup failed; review skill is still available." >&2 ;;
    esac
  else
    echo "NOTE: bun not found; installed gstack review skill only. Run gstack ./setup later for full /review tooling."
  fi
}

# ── schema v2 配置写入 ──
write_v2_config() {
  local config_dir="$1"
  local config_path
  config_path="$config_dir/review-backend.local.json"
  mkdir -p "$config_dir"

  # 解析 opencode config 路径，判断是否为自定义路径（来自 DEV_FLOW_OPENCODE_CONFIG/OPENCODE_CONFIG）
  # 自定义路径需持久化到 adapter config，后续新进程清除环境变量仍能 resolver/probe 读取
  local oc_config_path oc_default_path oc_is_custom
  oc_config_path="$(reviewer_resolve_opencode_config)"
  oc_default_path="${HOME}/.config/opencode/opencode.json"
  if [[ "$oc_config_path" != "$oc_default_path" ]]; then
    oc_is_custom=1
  else
    oc_is_custom=0
  fi

  REVIEW_BACKEND_VAL="$REVIEW_BACKEND" \
  FALLBACK_POLICY_VAL="${FALLBACK_POLICY:-allow}" \
  FALLBACK_ORDER_VAL="${FALLBACK_ORDER:-}" \
  PLATFORM_VAL="$PLATFORM" \
  SKILLS_ROOT_VAL="$SKILLS_ROOT" \
  ORCHESTRATOR_ROOT_VAL="${ORCHESTRATOR_ROOT:-}" \
  FB_ORCH_ROOT_VAL="${FALLBACK_ORCH_ROOT:-}" \
  FB_GSTACK_SKILL_PATH_VAL="${FALLBACK_GSTACK_SKILL_PATH:-}" \
  CONFIG_DIR_VAL="$config_dir" \
  OPENCODE_CONFIG_PATH_VAL="$oc_config_path" \
  OPENCODE_CONFIG_IS_CUSTOM_VAL="$oc_is_custom" \
  DEV_FLOW_SOURCE_ROOT="$ROOT" \
  python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

primary = os.environ["REVIEW_BACKEND_VAL"]
fallback_policy = os.environ["FALLBACK_POLICY_VAL"]
fallback_order_str = os.environ.get("FALLBACK_ORDER_VAL", "")
platform = os.environ["PLATFORM_VAL"]
skills_root = os.environ.get("SKILLS_ROOT_VAL", "")
orchestrator_root = os.environ.get("ORCHESTRATOR_ROOT_VAL", "")
fb_orch_root = os.environ.get("FB_ORCH_ROOT_VAL", "")
fb_gstack_skill_path = os.environ.get("FB_GSTACK_SKILL_PATH_VAL", "")
config_dir = os.environ["CONFIG_DIR_VAL"]

fallback_order = [a for a in fallback_order_str.split(",") if a] if fallback_order_str else []

# 从已有 config 提取 adapter 自定义路径（fallback 未显式指定时保留）
# 已有配置损坏（JSON 解析失败、非 object、结构异常）→ fail closed，不静默重写丢数据
existing_adapters = {}
_existing_config_path = Path(config_dir) / "review-backend.local.json"
if _existing_config_path.is_file():
    try:
        _existing = json.loads(_existing_config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"fail closed: existing project config is corrupted ({_existing_config_path}): {exc}")
    if not isinstance(_existing, dict):
        raise SystemExit(f"fail closed: existing project config is not a JSON object ({_existing_config_path})")
    existing_adapters = _existing.get("adapters", {})
    if not isinstance(existing_adapters, dict):
        raise SystemExit(f"fail closed: existing project config adapters is not an object ({_existing_config_path})")

def _existing_adapter_field(adapter_id, field):
    cfg = existing_adapters.get(adapter_id, {})
    return cfg.get(field, "")

# adapter 配置（不含 API key，只含标识/路径引用）
# fallback adapter 也保留完整自定义路径（root/skill_path/config_path）
adapters = {}

def _validate_oc_config_path(path_str, context):
    """验证 opencode config 路径：绝对、存在、regular file、非 symlink。

    验证失败 raise SystemExit fail closed，不静默丢弃。
    """
    p = Path(path_str)
    if not p.is_absolute():
        raise SystemExit(
            f"fail closed: {context}: opencode config path is not absolute: {path_str}"
        )
    if not p.is_file():
        raise SystemExit(
            f"fail closed: {context}: opencode config path does not exist or is not a file: {path_str}"
        )
    if p.is_symlink():
        raise SystemExit(
            f"fail closed: {context}: refusing to persist symlinked opencode config path: {path_str}"
        )
    return path_str

# 辅助：构建 adapter config，保留自定义路径
# config_path 选择顺序：当前环境解析到的合法自定义路径 → 已有配置中的合法 config_path → 默认路径不写
# 已存路径必须重新校验，失效 fail closed，不能静默丢弃
def make_adapter(adapter_id, is_primary=False):
    if adapter_id == "agent/openai-reviewer":
        cfg = {"type": "agent", "identifier": "openai-reviewer"}
        oc_config = os.environ.get("OPENCODE_CONFIG_PATH_VAL", "")
        oc_is_custom = os.environ.get("OPENCODE_CONFIG_IS_CUSTOM_VAL", "0") == "1"

        selected_path = ""
        if oc_is_custom and oc_config:
            # 1. 当前环境解析到的自定义路径 — 重新校验
            selected_path = _validate_oc_config_path(oc_config, "install (env custom path)")
        else:
            # 2. 已有配置中的 config_path — 必须重新校验，失效 fail closed
            existing_cp = _existing_adapter_field("agent/openai-reviewer", "config_path")
            if existing_cp:
                selected_path = _validate_oc_config_path(existing_cp, "install (existing config_path)")
            # 3. 默认路径 → 不写 config_path

        if selected_path:
            cfg["config_path"] = selected_path
        return cfg
    elif adapter_id == "mcp/orchestrator":
        cfg = {"type": "mcp", "identifier": "orchestrator-mcp"}
        if is_primary:
            root = orchestrator_root
        else:
            root = fb_orch_root or _existing_adapter_field("mcp/orchestrator", "root") or orchestrator_root
        if root:
            cfg["root"] = root
        return cfg
    elif adapter_id == "skill/gstack":
        cfg = {"type": "skill", "identifier": "gstack-review"}
        if is_primary:
            cfg["skill_path"] = f"{skills_root}/gstack/review/SKILL.md"
        else:
            cfg["skill_path"] = fb_gstack_skill_path or _existing_adapter_field("skill/gstack", "skill_path") or f"{skills_root}/gstack/review/SKILL.md"
        return cfg
    return {"type": "unknown", "identifier": adapter_id}

adapters[primary] = make_adapter(primary, is_primary=True)
for fb in fallback_order:
    if fb not in adapters:
        adapters[fb] = make_adapter(fb, is_primary=False)

config = {
    "schema_version": 2,
    "host": platform,
    "primary": primary,
    "fallback_policy": fallback_policy,
    "fallback_order": fallback_order,
    "adapters": adapters,
}

# 统一使用 safe_atomic_write_json（trusted root 显式传入）
sys.path.insert(0, os.path.join(os.environ.get("DEV_FLOW_SOURCE_ROOT", ""), 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

# 原子写 DEV_FLOW_CONFIG_OUT（如有）
config_out = os.environ.get("DEV_FLOW_CONFIG_OUT", "")
if config_out:
    co_trusted = str(Path(config_out).parent)
    safe_atomic_write_json(co_trusted, config_out, config)

# 原子写 review-backend.local.json
target = Path(config_dir) / "review-backend.local.json"
safe_atomic_write_json(config_dir, str(target), config)
print(str(target))
PY
}

write_user_v2_config() {
  local user_config_dir="$HOME/.config/dev-flow"
  local user_config_path="$user_config_dir/config.json"
  mkdir -p "$user_config_dir"

  # 解析 opencode config 路径，判断是否为自定义路径（与 write_v2_config 同步）
  local oc_config_path oc_default_path oc_is_custom
  oc_config_path="$(reviewer_resolve_opencode_config)"
  oc_default_path="${HOME}/.config/opencode/opencode.json"
  if [[ "$oc_config_path" != "$oc_default_path" ]]; then
    oc_is_custom=1
  else
    oc_is_custom=0
  fi

  REVIEW_BACKEND_VAL="$REVIEW_BACKEND" \
  FALLBACK_POLICY_VAL="${FALLBACK_POLICY:-allow}" \
  FALLBACK_ORDER_VAL="${FALLBACK_ORDER:-}" \
  PLATFORM_VAL="$PLATFORM" \
  SKILLS_ROOT_VAL="$SKILLS_ROOT" \
  ORCHESTRATOR_ROOT_VAL="${ORCHESTRATOR_ROOT:-}" \
  FB_ORCH_ROOT_VAL="${FALLBACK_ORCH_ROOT:-}" \
  FB_GSTACK_SKILL_PATH_VAL="${FALLBACK_GSTACK_SKILL_PATH:-}" \
  USER_CONFIG_PATH="$user_config_path" \
  OPENCODE_CONFIG_PATH_VAL="$oc_config_path" \
  OPENCODE_CONFIG_IS_CUSTOM_VAL="$oc_is_custom" \
  DEV_FLOW_SOURCE_ROOT="$ROOT" \
  python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

primary = os.environ["REVIEW_BACKEND_VAL"]
fallback_policy = os.environ["FALLBACK_POLICY_VAL"]
fallback_order_str = os.environ.get("FALLBACK_ORDER_VAL", "")
platform = os.environ["PLATFORM_VAL"]
skills_root = os.environ.get("SKILLS_ROOT_VAL", "")
orchestrator_root = os.environ.get("ORCHESTRATOR_ROOT_VAL", "")
fb_orch_root = os.environ.get("FB_ORCH_ROOT_VAL", "")
fb_gstack_skill_path = os.environ.get("FB_GSTACK_SKILL_PATH_VAL", "")
user_config_path = Path(os.environ["USER_CONFIG_PATH"])

fallback_order = [a for a in fallback_order_str.split(",") if a] if fallback_order_str else []

# 读取现有 user config（如有），合并 host profile
# 已有配置损坏（JSON 解析失败、非 object、hosts 非 object、host profile 非 object）→ fail closed
# 仅文件不存在允许创建空配置；不能静默重写丢其他 profile
existing = {}
if user_config_path.is_file():
    try:
        existing = json.loads(user_config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"fail closed: existing user config is corrupted ({user_config_path}): {exc}")
    if not isinstance(existing, dict):
        raise SystemExit(f"fail closed: existing user config is not a JSON object ({user_config_path})")
    _hosts = existing.get("hosts")
    if _hosts is not None and not isinstance(_hosts, dict):
        raise SystemExit(f"fail closed: existing user config hosts is not an object ({user_config_path})")
    if isinstance(_hosts, dict) and platform in _hosts:
        _profile = _hosts[platform]
        if _profile is not None and not isinstance(_profile, dict):
            raise SystemExit(f"fail closed: existing user config hosts.{platform} is not an object ({user_config_path})")

# 从已有 config 提取 adapter 自定义路径（fallback 未显式指定时保留）
existing_host_adapters = (existing.get("hosts", {}).get(platform, {}) or {}).get("adapters", {})

def _existing_adapter_field(adapter_id, field):
    """从已有 config 提取 adapter 的自定义字段值。"""
    cfg = existing_host_adapters.get(adapter_id, {})
    return cfg.get(field, "")

# adapter 配置（与 write_v2_config 共同逻辑：fallback 保留完整自定义路径）

def _validate_oc_config_path(path_str, context):
    """验证 opencode config 路径：绝对、存在、regular file、非 symlink。

    验证失败 raise SystemExit fail closed，不静默丢弃。
    与 write_v2_config 中同名函数逻辑一致。
    """
    p = Path(path_str)
    if not p.is_absolute():
        raise SystemExit(
            f"fail closed: {context}: opencode config path is not absolute: {path_str}"
        )
    if not p.is_file():
        raise SystemExit(
            f"fail closed: {context}: opencode config path does not exist or is not a file: {path_str}"
        )
    if p.is_symlink():
        raise SystemExit(
            f"fail closed: {context}: refusing to persist symlinked opencode config path: {path_str}"
        )
    return path_str

# config_path 选择顺序与 write_v2_config 一致：
# 当前环境解析到的合法自定义路径 → 已有配置中的合法 config_path → 默认路径不写
# 已存路径必须重新校验，失效 fail closed，不能静默丢弃
def make_adapter(adapter_id, is_primary=False):
    if adapter_id == "agent/openai-reviewer":
        cfg = {"type": "agent", "identifier": "openai-reviewer"}
        oc_config = os.environ.get("OPENCODE_CONFIG_PATH_VAL", "")
        oc_is_custom = os.environ.get("OPENCODE_CONFIG_IS_CUSTOM_VAL", "0") == "1"

        selected_path = ""
        if oc_is_custom and oc_config:
            # 1. 当前环境解析到的自定义路径 — 重新校验
            selected_path = _validate_oc_config_path(oc_config, "install (env custom path)")
        else:
            # 2. 已有配置中的 config_path — 必须重新校验，失效 fail closed
            existing_cp = _existing_adapter_field("agent/openai-reviewer", "config_path")
            if existing_cp:
                selected_path = _validate_oc_config_path(existing_cp, "install (existing config_path)")
            # 3. 默认路径 → 不写 config_path

        if selected_path:
            cfg["config_path"] = selected_path
        return cfg
    elif adapter_id == "mcp/orchestrator":
        cfg = {"type": "mcp", "identifier": "orchestrator-mcp"}
        if is_primary:
            root = orchestrator_root
        else:
            # fallback 优先用 CLI 值 → 已有 config 值 → primary 值
            root = fb_orch_root or _existing_adapter_field("mcp/orchestrator", "root") or orchestrator_root
        if root:
            cfg["root"] = root
        return cfg
    elif adapter_id == "skill/gstack":
        cfg = {"type": "skill", "identifier": "gstack-review"}
        if is_primary:
            cfg["skill_path"] = f"{skills_root}/gstack/review/SKILL.md"
        else:
            # fallback 优先用 CLI 值 → 已有 config 值 → resolved skills_root
            cfg["skill_path"] = fb_gstack_skill_path or _existing_adapter_field("skill/gstack", "skill_path") or f"{skills_root}/gstack/review/SKILL.md"
        return cfg
    return {"type": "unknown", "identifier": adapter_id}

adapters = {}
adapters[primary] = make_adapter(primary, is_primary=True)
for fb in fallback_order:
    if fb not in adapters:
        adapters[fb] = make_adapter(fb, is_primary=False)

profile = {
    "primary": primary,
    "fallback_policy": fallback_policy,
    "fallback_order": fallback_order,
    "adapters": adapters,
}

# 合并 host profile 到 existing user config
# existing 已在上方读取并校验（JSON 解析失败/非 object/hosts 非 object/profile 非 object 均 fail closed）
# 不能静默重写丢其他 host profile
existing["schema_version"] = 2
hosts = existing.setdefault("hosts", {})
hosts[platform] = profile
existing["hosts"] = hosts

# 统一使用 safe_atomic_write_json（trusted root = user_config_dir）
# safe_atomic_write_json 会沿原始路径逐级 lstat + resolve 边界校验
sys.path.insert(0, os.path.join(os.environ.get("DEV_FLOW_SOURCE_ROOT", ""), 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json
_user_config_dir = str(user_config_path.parent)
safe_atomic_write_json(_user_config_dir, str(user_config_path), existing)
print(str(user_config_path))
PY
}

# ── 参数解析 ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cursor) PLATFORM="cursor"; shift ;;
    --codex) PLATFORM="codex"; shift ;;
    --opencode) PLATFORM="opencode"; shift ;;
    --project) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --skills-root) SKILLS_ROOT="${2:-}"; shift 2 ;;
    --review-backend) REVIEW_BACKEND="${2:-}"; shift 2 ;;
    --orchestrator-root) ORCHESTRATOR_ROOT="${2:-}"; shift 2 ;;
    --fallback-orchestrator-root) FALLBACK_ORCH_ROOT="${2:-}"; shift 2 ;;
    --fallback-gstack-skill-path) FALLBACK_GSTACK_SKILL_PATH="${2:-}"; shift 2 ;;
    --skip-mcp-config) SKIP_MCP_CONFIG=1; shift ;;
    --save-level) SAVE_LEVEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── 平台检测 ──
# 优先级：CLI --opencode/--cursor/--codex > DEV_FLOW_HOST > 明确宿主环境信号 > codex（保守）
# 不得用 ~/.config/opencode 是否存在来判断——同机安装 OpenCode 目录不能让 Codex 误判
if [[ -z "$PLATFORM" ]]; then
  if [[ -n "${DEV_FLOW_HOST:-}" ]]; then
    PLATFORM="$DEV_FLOW_HOST"
  elif [[ -n "${OPENCODE:-}" ]]; then
    PLATFORM="opencode"
  elif [[ "${CURSOR_AGENT:-}" == "1" || -n "${CURSOR_CONVERSATION_ID:-}" ]]; then
    PLATFORM="cursor"
  else
    PLATFORM="codex"
  fi
fi

# ── skills root 解析 ──
if [[ -z "$SKILLS_ROOT" ]]; then
  case "$PLATFORM" in
    cursor) SKILLS_ROOT="${CURSOR_SKILLS_ROOT:-$HOME/.cursor/skills}" ;;
    opencode) SKILLS_ROOT="${OPENCODE_SKILLS_ROOT:-$HOME/.config/opencode/skills}" ;;
    *)
      if [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
        SKILLS_ROOT="$CODEX_SKILLS_ROOT"
      elif [[ -n "${CODEX_HOME:-}" ]]; then
        SKILLS_ROOT="$CODEX_HOME/skills"
      else
        SKILLS_ROOT="$HOME/.codex/skills"
      fi
      ;;
  esac
fi

# ── 确定 backend ──
FALLBACK_POLICY=""
FALLBACK_ORDER=""

if [[ -n "$REVIEW_BACKEND" ]]; then
  # CLI 显式指定
  REVIEW_BACKEND="$(normalize_backend "$REVIEW_BACKEND")"
  FALLBACK_POLICY="allow"
  # 默认 fallback order：除 primary 外按已知顺序
  for a in "$ADAPTER_AGENT" "$ADAPTER_ORCH" "$ADAPTER_GSTACK"; do
    [[ "$a" != "$REVIEW_BACKEND" ]] && FALLBACK_ORDER="${FALLBACK_ORDER:+$FALLBACK_ORDER,}$a"
  done
elif [[ -n "${DEV_FLOW_REVIEW_BACKEND:-}" ]]; then
  REVIEW_BACKEND="$(normalize_backend "$DEV_FLOW_REVIEW_BACKEND")"
  FALLBACK_POLICY="allow"
  for a in "$ADAPTER_AGENT" "$ADAPTER_ORCH" "$ADAPTER_GSTACK"; do
    [[ "$a" != "$REVIEW_BACKEND" ]] && FALLBACK_ORDER="${FALLBACK_ORDER:+$FALLBACK_ORDER,}$a"
  done
elif [[ -t 0 ]]; then
  # 交互向导
  wizard_prompt_host
  wizard_prompt_primary
  wizard_prompt_identifier
  wizard_prompt_fallback
  wizard_prompt_fallback_order
  wizard_prompt_save_level
else
  # 非交互且无 CLI/env 选择 → 用 resolver 读取现有项目/用户合法配置并复用
  # 不得把仓库默认策略当成"已有配置"——resolver 输出 source=default 时 fail closed
  resolver_args=(--host "$PLATFORM")
  if [[ -n "$PROJECT_ROOT" ]]; then
    resolver_args+=(--project-root "$PROJECT_ROOT")
  fi
  resolver_output="$(review_resolve "${resolver_args[@]}" 2>/dev/null || true)"
  resolver_status=""
  resolver_adapter=""
  resolver_source=""
  if [[ -n "$resolver_output" ]]; then
    resolver_status="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' <<< "$resolver_output" 2>/dev/null || true)"
    resolver_adapter="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("selected_adapter",""))' <<< "$resolver_output" 2>/dev/null || true)"
    resolver_source="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("source",""))' <<< "$resolver_output" 2>/dev/null || true)"
  fi
  if [[ "$resolver_status" == "available" && "$resolver_source" != "default" && -n "$resolver_adapter" ]]; then
    # 复用现有合法配置（项目级或用户级，非 default）。
    # 不重写/默认覆盖——直接验证 + probe 并退出，不改文件。
    # 保持完整 adapters（从 resolver 输出提取，不丢失自定义 root/skill_path/config_path）。
    REVIEW_BACKEND="$resolver_adapter"
    FALLBACK_POLICY="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("fallback_policy","allow"))' <<< "$resolver_output" 2>/dev/null || echo allow)"
    FALLBACK_ORDER="$(/usr/bin/python3 -c 'import json,sys;print(",".join(json.load(sys.stdin).get("fallback_order",[])))' <<< "$resolver_output" 2>/dev/null || true)"
    # 提取完整 adapters（保留自定义 root/skill_path/config_path）
    RESOLVER_ADAPTERS="$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("adapters",{})))' <<< "$resolver_output" 2>/dev/null || true)"
    echo "Reusing existing review config (source=$resolver_source, adapter=$REVIEW_BACKEND)"

    # 直接 probe 验证可用性，不写任何文件
    echo ""
    echo "== Review backend (reuse mode) =="
    echo "Backend:      $REVIEW_BACKEND"
    echo "Platform:     $PLATFORM"
    echo "Source:       $resolver_source (no files modified)"
    echo "Fallback:     ${FALLBACK_POLICY:-allow} (${FALLBACK_ORDER:-none})"

    echo ""
    echo "Probe:"
    # 传入完整 adapter config（自定义 root/skill_path 生效）
    adapter_cfg=""
    if [[ -n "$RESOLVER_ADAPTERS" ]]; then
      adapter_cfg="$(/usr/bin/python3 -c 'import json,sys;adapters=json.loads(sys.stdin.read());cfg=adapters.get(sys.argv[1],{});print(json.dumps(cfg) if cfg else "")' "$REVIEW_BACKEND" <<< "$RESOLVER_ADAPTERS" 2>/dev/null || true)"
    fi
    if probe_evidence="$(review_probe_adapter "$REVIEW_BACKEND" "$adapter_cfg" 2>/dev/null)"; then
      echo "  $REVIEW_BACKEND: available ($probe_evidence)"
    else
      echo "  $REVIEW_BACKEND: unavailable ($probe_evidence)"
      echo "  WARNING: primary adapter 探活失败，审查门禁可能阻塞。" >&2
    fi
    exit 0
  else
    # 无有效显式本地配置 → fail closed
    cat <<ERR >&2
ERROR: 非交互环境下未指定 review backend 且无有效显式本地配置。需要：
  1. 通过 --review-backend <adapter-id|alias> 显式指定
      （agent/openai-reviewer | mcp/orchestrator | skill/gstack，或 v1 别名 reviewer|orchestrator|gstack）
  2. 或设置环境变量 DEV_FLOW_REVIEW_BACKEND
  3. 或已有项目/用户级配置（.dev-flow/review-backend.local.json 或 ~/.config/dev-flow/config.json）
  4. 或在交互终端运行本脚本进入配置向导

不静默猜测默认 backend，不把仓库默认策略当成已配置。请显式选择后重试。
ERR
    exit 1
  fi
fi

# ── 安装选定 adapter ──
case "$REVIEW_BACKEND" in
  "$ADAPTER_AGENT") install_reviewer ;;
  "$ADAPTER_ORCH") install_orchestrator ;;
  "$ADAPTER_GSTACK") install_gstack_review ;;
esac

# ── 写入 schema v2 配置 ──
if [[ "$SAVE_LEVEL" == "user" ]]; then
  CONFIG_OUT="$(write_user_v2_config)"
else
  if [[ -n "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
    CONFIG_OUT="$(write_v2_config "$PROJECT_ROOT/.dev-flow")"
  else
    CONFIG_OUT="$(write_v2_config "$ROOT/.dev-flow")"
  fi
fi

# orchestrator 额外写 root 文件（兼容现有 probe）— 统一安全原子文本写
if [[ "$REVIEW_BACKEND" == "$ADAPTER_ORCH" && -n "$ORCHESTRATOR_ROOT" ]]; then
  _project_root="${PROJECT_ROOT:-$ROOT}"
  local_state_dir="$_project_root/.dev-flow"

  mkdir -p "$local_state_dir"

  orch_marker="$local_state_dir/orchestrator-mcp-root"
  # 统一使用 safe_atomic_write_bytes（trusted root = .dev-flow）
  printf '%s\n' "$ORCHESTRATOR_ROOT" | DEV_FLOW_SOURCE_ROOT="$ROOT" /usr/bin/python3 - "$local_state_dir" "$orch_marker" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ.get("DEV_FLOW_SOURCE_ROOT", ""), 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_bytes
trusted_root = sys.argv[1]
target_path = sys.argv[2]
data = sys.stdin.buffer.read()
safe_atomic_write_bytes(trusted_root, target_path, data)
PY
fi

# ── doctor/probe ──
echo ""
echo "== Review backend install =="
echo "Backend:      $REVIEW_BACKEND"
echo "Platform:     $PLATFORM"
echo "Save level:   $SAVE_LEVEL"
echo "Config:       $CONFIG_OUT"
echo "Fallback:     ${FALLBACK_POLICY:-allow} (${FALLBACK_ORDER:-none})"

echo ""
echo "Probe:"
# 从写入的 config 重建 adapter_cfg，确保 probe 使用与 install 时相同的 adapter config
# （自定义 root/skill_path/config_path 生效），不靠调用者手动传 env。
PROBE_ADAPTER_CFG=""
if [[ -f "$CONFIG_OUT" ]]; then
  PROBE_ADAPTER_CFG="$(/usr/bin/python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    adapters = c.get("adapters", {})
    if isinstance(c.get("hosts"), dict) and sys.argv[2] in c["hosts"]:
        adapters = c["hosts"][sys.argv[2]].get("adapters", adapters)
    cfg = adapters.get(sys.argv[3], {})
    print(json.dumps(cfg) if cfg else "")
except Exception:
    print("")
' "$CONFIG_OUT" "$PLATFORM" "$REVIEW_BACKEND" 2>/dev/null || true)"
fi
if probe_evidence="$(review_probe_adapter "$REVIEW_BACKEND" "$PROBE_ADAPTER_CFG" 2>/dev/null)"; then
  echo "  $REVIEW_BACKEND: available ($probe_evidence)"
else
  echo "  $REVIEW_BACKEND: unavailable ($probe_evidence)"
  echo "  WARNING: primary adapter 探活失败，审查门禁可能阻塞。" >&2
fi
