#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"

ORCHESTRATOR_REPO="${DEV_FLOW_ORCHESTRATOR_MCP_REPO:-https://github.com/Immmmmmortal1/orchestrator-mcp.git}"
GSTACK_REPO="${DEV_FLOW_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
PLATFORM=""
PROJECT_ROOT=""
SKILLS_ROOT=""
REVIEW_BACKEND=""
ORCHESTRATOR_ROOT=""
SKIP_MCP_CONFIG=0

usage() {
  cat <<EOF
Usage:
  bash scripts/install-review-backend.sh [--cursor | --codex] [--project <app-root>] [--skills-root <path>] [--review-backend orchestrator|gstack] [--orchestrator-root <path>] [--skip-mcp-config]

Install dev-flow review backend for environment-health review_mcp gate.

Choices:
  orchestrator — clone https://github.com/Immmmmmortal1/orchestrator-mcp, prepare venv, merge MCP config
  gstack       — ensure gstack-review skill exists under the platform skills root (default fallback)

Interactive install prompts when stdin is a TTY and --review-backend is omitted.
Non-interactive default: gstack.

Examples:
  bash scripts/install-review-backend.sh
  bash scripts/install-review-backend.sh --review-backend orchestrator
  bash scripts/install-review-backend.sh --cursor --project ~/iOSworkspace/KakaPic --review-backend gstack
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

prompt_review_backend() {
  if [[ -n "$REVIEW_BACKEND" ]]; then
    return 0
  fi
  if [[ -n "${DEV_FLOW_REVIEW_BACKEND:-}" ]]; then
    REVIEW_BACKEND="$DEV_FLOW_REVIEW_BACKEND"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    REVIEW_BACKEND="gstack"
    echo "Non-interactive install: default review backend = gstack-review."
    echo "Use --review-backend orchestrator to install orchestrator-mcp instead."
    return 0
  fi

  cat <<'PROMPT'

dev-flow 环境门禁需要 Review 能力（review_mcp）。请选择：

  1) orchestrator-mcp — 独立 Review Hub MCP（多模型审查，需配置 Provider API Key）
     https://github.com/Immmmmmortal1/orchestrator-mcp

  2) gstack-review — 轻量 fallback（使用 gstack /review skill，无需 MCP Server）

PROMPT
  local choice=""
  while true; do
    read -r -p "请选择 [1/2]（默认 2）: " choice
    choice="${choice:-2}"
    case "$choice" in
      1|orchestrator|orchestrator-mcp|mcp)
        REVIEW_BACKEND="orchestrator"
        break
        ;;
      2|gstack|gstack-review|review)
        REVIEW_BACKEND="gstack"
        break
        ;;
      *)
        echo "请输入 1 或 2。"
        ;;
    esac
  done
}

install_orchestrator() {
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
    merge_output="$(
      python3 "$LIB/merge-orchestrator-mcp-config.py" \
        --platform "$PLATFORM" \
        --wrapper-path "$ORCHESTRATOR_ROOT/codex-stdio-wrapper.sh" \
        --pythonpath "$ORCHESTRATOR_ROOT/src" \
        --config-path "$MCP_CONFIG_PATH"
    )"
    echo "$merge_output"
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
      codex) (cd "$gstack_root" && ./setup --host codex -q) || echo "WARNING: gstack setup failed; review skill is still available." >&2 ;;
    esac
  else
    echo "NOTE: bun not found; installed gstack review skill only. Run gstack ./setup later for full /review tooling."
  fi
}

write_manifest() {
  local state_dir="$1"
  mkdir -p "$state_dir"
  python3 - <<PY
import json
from pathlib import Path

manifest = {
    "schema_version": 1,
    "backend": "$REVIEW_BACKEND",
    "platform": "$PLATFORM",
    "orchestrator_mcp_root": "$ORCHESTRATOR_ROOT" if "$REVIEW_BACKEND" == "orchestrator" else None,
    "gstack_review_skill": "$SKILLS_ROOT/gstack/review/SKILL.md" if "$REVIEW_BACKEND" == "gstack" else None,
    "ai_next_steps": [],
}
if "$REVIEW_BACKEND" == "orchestrator":
    manifest["ai_next_steps"].append("Restart Cursor/Codex MCP so orchestrator_mcp reloads")
    manifest["ai_next_steps"].append("Configure provider API keys in orchestrator WebUI or environment variables")
else:
    manifest["ai_next_steps"].append("Use gstack-review (/review) when Review MCP is unavailable")
    manifest["ai_next_steps"].append("Optional: run bun-based gstack ./setup for full review tooling")

Path("$state_dir/review-backend.json").write_text(
    json.dumps(manifest, indent=2) + "\n",
    encoding="utf-8",
)
PY

  if [[ "$REVIEW_BACKEND" == "orchestrator" ]]; then
    printf '%s\n' "$ORCHESTRATOR_ROOT" >"$state_dir/orchestrator-mcp-root"
  fi
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
    --skills-root)
      SKILLS_ROOT="${2:-}"
      shift 2
      ;;
    --review-backend)
      REVIEW_BACKEND="${2:-}"
      shift 2
      ;;
    --orchestrator-root)
      ORCHESTRATOR_ROOT="${2:-}"
      shift 2
      ;;
    --skip-mcp-config)
      SKIP_MCP_CONFIG=1
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

if [[ -z "$SKILLS_ROOT" ]]; then
  if [[ "$PLATFORM" == "cursor" ]]; then
    SKILLS_ROOT="${CURSOR_SKILLS_ROOT:-$HOME/.cursor/skills}"
  elif [[ -n "${CODEX_SKILLS_ROOT:-}" ]]; then
    SKILLS_ROOT="$CODEX_SKILLS_ROOT"
  elif [[ -n "${CODEX_HOME:-}" ]]; then
    SKILLS_ROOT="$CODEX_HOME/skills"
  else
    SKILLS_ROOT="$HOME/.codex/skills"
  fi
fi

if [[ -z "$ORCHESTRATOR_ROOT" ]]; then
  ORCHESTRATOR_ROOT="$(cd "$ROOT/.." && pwd)/orchestrator-mcp"
fi
ORCHESTRATOR_ROOT="$(cd "$(dirname "$ORCHESTRATOR_ROOT")" && pwd)/$(basename "$ORCHESTRATOR_ROOT")"

prompt_review_backend

case "$REVIEW_BACKEND" in
  orchestrator|orchestrator-mcp|mcp)
    REVIEW_BACKEND="orchestrator"
    install_orchestrator
    ;;
  gstack|gstack-review|review)
    REVIEW_BACKEND="gstack"
    install_gstack_review
    ;;
  *)
    echo "Unknown review backend: $REVIEW_BACKEND" >&2
    exit 2
    ;;
esac

if [[ -n "$PROJECT_ROOT" ]]; then
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
  write_manifest "$PROJECT_ROOT/.dev-flow"
else
  write_manifest "$ROOT/.dev-flow"
fi

cat <<EOF

== Review backend install ==
Backend:      $REVIEW_BACKEND
Platform:     $PLATFORM
Skills root:  $SKILLS_ROOT
EOF

if [[ "$REVIEW_BACKEND" == "orchestrator" ]]; then
  cat <<EOF
Orchestrator: $ORCHESTRATOR_ROOT
EOF
else
  cat <<EOF
gstack-review: $SKILLS_ROOT/gstack/review/SKILL.md
EOF
fi
