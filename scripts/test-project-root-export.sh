#!/usr/bin/env bash
# 真实集成测试：不显式设置 DEV_FLOW_PROJECT_ROOT，只在项目 cwd 通过 dev-flow.sh 入口，
# 有项目 local config 时 review selection available 并写 state。
# 同时测试 install-review-backend probe 输出 available 且命令成功。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
TMP_HOME="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP" "$TMP_HOME"' EXIT

# ── 项目 git init ──
/usr/bin/git -C "$TMP" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP" init -q && /usr/bin/git -C "$TMP" checkout -qb main; }
/usr/bin/git -C "$TMP" config user.email "test@example.com"
/usr/bin/git -C "$TMP" config user.name "test"
printf 'base\n' > "$TMP/base.txt"
/usr/bin/git -C "$TMP" add base.txt
/usr/bin/git -C "$TMP" commit -qm "init"
printf '.dev-flow/\n' > "$TMP/.gitignore"
/usr/bin/git -C "$TMP" add .gitignore
/usr/bin/git -C "$TMP" commit -qm "gitignore"

# ── fake opencode.json（让 agent probe 通过）──
OC_CONFIG="$TMP/opencode.json"
printf '%s\n' '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$OC_CONFIG"

# ============================================================
# Test 1: install-review-backend probe 输出 available 且命令成功
# ============================================================
echo "=== Test 1: install-review-backend probe available ==="
INSTALL_OUTPUT="$(HOME="$TMP_HOME" OPENCODE_CONFIG="$OC_CONFIG" bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --review-backend agent/openai-reviewer \
  --project "$TMP" \
  --skip-mcp-config 2>&1)"

# 命令必须成功
if [[ $? -ne 0 ]]; then
  echo "FAIL: install-review-backend should succeed" >&2
  echo "$INSTALL_OUTPUT" >&2
  exit 1
fi

# probe 输出必须含 available
if ! echo "$INSTALL_OUTPUT" | /usr/bin/grep -q "available"; then
  echo "FAIL: probe output should contain 'available'" >&2
  echo "$INSTALL_OUTPUT" >&2
  exit 1
fi

# 不应含 unavailable
if echo "$INSTALL_OUTPUT" | /usr/bin/grep -q "unavailable"; then
  echo "FAIL: probe output should not contain 'unavailable'" >&2
  echo "$INSTALL_OUTPUT" >&2
  exit 1
fi

echo "OK: install-review-backend probe outputs available"

# ============================================================
# Test 2: 不显式设置 DEV_FLOW_PROJECT_ROOT，从项目 cwd 跑 environment-health
# ============================================================
echo "=== Test 2: environment-health from cwd without DEV_FLOW_PROJECT_ROOT ==="

# 先确保 .dev-flow/sessions 存在
/bin/mkdir -p "$TMP/.dev-flow/sessions"

# 从项目 cwd start session（不显式设 DEV_FLOW_PROJECT_ROOT）
cd "$TMP"
HOME="$TMP_HOME" OPENCODE_CONFIG="$OC_CONFIG" DEV_FLOW_SESSION_ID=cwd-test \
  bash "$ROOT/scripts/dev-flow.sh" session start --type feature --task "cwd test" >/dev/null

# confirm-plan
HOME="$TMP_HOME" OPENCODE_CONFIG="$OC_CONFIG" DEV_FLOW_SESSION_ID=cwd-test \
  bash "$ROOT/scripts/dev-flow.sh" session confirm-plan >/dev/null

# 跑 environment-health-check（不显式设 DEV_FLOW_PROJECT_ROOT，只靠 cwd）
# 真实运行 review-health-probe.sh（不设 DEV_FLOW_TEST_MODE，不用 fake probe）
HEALTH_OUTPUT="$(HOME="$TMP_HOME" OPENCODE_CONFIG="$OC_CONFIG" DEV_FLOW_SESSION_ID=cwd-test \
  bash "$ROOT/scripts/dev-flow.sh" environment-health run 2>&1)" || true

# 验证 state 中的 review_mcp status 和 review_selection
/usr/bin/python3 - "$TMP/.dev-flow/sessions/cwd-test.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())

env = state.get("environment_health") or {}
review_mcp = (env.get("checks") or {}).get("review_mcp") or {}

# review_mcp 必须 available（项目有 local config，agent probe 通过）
assert review_mcp.get("status") == "available", f"review_mcp not available: {review_mcp}"

# review_selection 必须写入 state，且 selected_adapter = agent/openai-reviewer
selection = state.get("review_selection") or {}
assert selection.get("selected_adapter") == "agent/openai-reviewer", f"wrong adapter: {selection}"
assert selection.get("config_digest", "").startswith("sha256:"), f"missing config_digest: {selection}"
assert selection.get("source") == "project", f"wrong source: {selection}"

print("OK: environment-health from cwd resolves project config, review_mcp available, selection written")
PY

# ============================================================
# Test 3: 验证 DEV_FLOW_PROJECT_ROOT 被 export 到子进程
# ============================================================
echo "=== Test 3: DEV_FLOW_PROJECT_ROOT exported to subprocess ==="
# 直接验证 resolver 能在子进程中读到 DEV_FLOW_PROJECT_ROOT
cd "$TMP"
RESOLVER_OUT="$(HOME="$TMP_HOME" OPENCODE_CONFIG="$OC_CONFIG" \
  bash -c 'source "'$ROOT'/scripts/lib/dev-flow-paths.sh"; dev_flow_load_paths "'$ROOT'/scripts/dev-flow.sh"; /usr/bin/python3 -c "import os; print(os.environ.get(\"DEV_FLOW_PROJECT_ROOT\",\"EMPTY\"))"')"
if [[ "$RESOLVER_OUT" != "$TMP" ]]; then
  echo "FAIL: DEV_FLOW_PROJECT_ROOT not exported to subprocess: got '$RESOLVER_OUT' expected '$TMP'" >&2
  exit 1
fi
echo "OK: DEV_FLOW_PROJECT_ROOT exported to subprocess"

echo ""
echo "PASS: project root export integration (cwd resolution, install probe, subprocess visibility)"
