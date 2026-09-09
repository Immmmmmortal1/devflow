#!/usr/bin/env bash
# install-review-backend.sh v2 测试：3 adapter 非交互安装 + schema v2 校验 + resolver 集成
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
TMP_HOME="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP" "$TMP_HOME"' EXIT

mkdir -p "$TMP/skills" "$TMP/project/.dev-flow" "$TMP/orch/.venv/bin" "$TMP/orch/src"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/orch/codex-stdio-wrapper.sh"
printf '%s\n' '#!/usr/bin/env python3' 'pass' > "$TMP/orch/.venv/bin/python"
chmod +x "$TMP/orch/codex-stdio-wrapper.sh" "$TMP/orch/.venv/bin/python"

# 伪造 gstack review skill 源（供 skill/gstack adapter 安装使用）
mkdir -p "$TMP/gstack-source/review"
printf '%s\n' '# gstack review SKILL' > "$TMP/gstack-source/review/SKILL.md"
export GSTACK_REPO_ROOT="$TMP/gstack-source"

echo "=== test 1: orchestrator (mcp/orchestrator) → schema v2 project config ==="
HOME="$TMP_HOME" bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP/skills" \
  --review-backend orchestrator \
  --orchestrator-root "$TMP/orch" \
  --project "$TMP/project" \
  --skip-mcp-config >/dev/null

[[ -f "$TMP/project/.dev-flow/review-backend.local.json" ]]
[[ -f "$TMP/project/.dev-flow/orchestrator-mcp-root" ]]
# schema v2 校验
/usr/bin/python3 - "$TMP/project/.dev-flow/review-backend.local.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["schema_version"] == 2, f"schema_version != 2: {c}"
assert c["primary"] == "mcp/orchestrator", c["primary"]
assert c["fallback_policy"] == "allow", c["fallback_policy"]
assert "mcp/orchestrator" in c["adapters"], c["adapters"]
assert c["adapters"]["mcp/orchestrator"]["type"] == "mcp"
print("OK: orchestrator v2 config")
PY

echo "=== test 2: gstack (skill/gstack) → schema v2 project config ==="
TMP_PROJECT2="$(/usr/bin/mktemp -d)"
HOME="$TMP_HOME" bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT2" \
  --skip-mcp-config >/dev/null

[[ -f "$TMP_PROJECT2/.dev-flow/review-backend.local.json" ]]
/usr/bin/python3 - "$TMP_PROJECT2/.dev-flow/review-backend.local.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["schema_version"] == 2
assert c["primary"] == "skill/gstack"
assert "skill/gstack" in c["adapters"]
assert c["adapters"]["skill/gstack"]["type"] == "skill"
print("OK: gstack v2 config")
PY

echo "=== test 3: v1 alias 'reviewer' → agent/openai-reviewer migration ==="
TMP_PROJECT3="$(/usr/bin/mktemp -d)"
# 创建一个最小 opencode.json 让 agent probe 通过
TMP_OC_CONFIG="$TMP_PROJECT3/opencode.json"
printf '%s\n' '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$TMP_OC_CONFIG"
DEV_FLOW_OPENCODE_CONFIG="$TMP_OC_CONFIG" HOME="$TMP_HOME" bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend reviewer \
  --project "$TMP_PROJECT3" \
  --skip-mcp-config >/dev/null

[[ -f "$TMP_PROJECT3/.dev-flow/review-backend.local.json" ]]
/usr/bin/python3 - "$TMP_PROJECT3/.dev-flow/review-backend.local.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["schema_version"] == 2
assert c["primary"] == "agent/openai-reviewer", c["primary"]
assert "agent/openai-reviewer" in c["adapters"]
assert c["adapters"]["agent/openai-reviewer"]["type"] == "agent"
print("OK: reviewer→agent/openai-reviewer v2 migration")
PY

echo "=== test 4: unknown adapter → fail closed ==="
TMP_PROJECT4="$(/usr/bin/mktemp -d)"
if HOME="$TMP_HOME" bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP/skills" \
  --review-backend bogus \
  --project "$TMP_PROJECT4" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: unknown adapter should have exited non-zero" >&2
  exit 1
fi
echo "OK: unknown adapter fails closed"

echo "=== test 5: non-interactive without selection → fail closed ==="
TMP_PROJECT5="$(/usr/bin/mktemp -d)"
if bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP/skills" \
  --project "$TMP_PROJECT5" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: non-interactive without selection should fail closed" >&2
  exit 1
fi
echo "OK: non-interactive without selection fails closed"

echo "=== test 6: resolver reads v2 config and returns correct adapter ==="
selection="$(DEV_FLOW_PROJECT_ROOT="$TMP/project" /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve 2>&1)"
echo "$selection" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["selected_adapter"]=="mcp/orchestrator",d;print("OK: resolver returns mcp/orchestrator from v2 project config")'

echo "=== test 7: user-level config (save-level=user) ==="
TMP_PROJECT6="$(/usr/bin/mktemp -d)"
HOME="$TMP_HOME" bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT6" \
  --save-level user \
  --skip-mcp-config >/dev/null

[[ -f "$TMP_HOME/.config/dev-flow/config.json" ]]
/usr/bin/python3 - "$TMP_HOME/.config/dev-flow/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["schema_version"] == 2
assert "codex" in c["hosts"], c
assert c["hosts"]["codex"]["primary"] == "skill/gstack"
print("OK: user-level v2 config")
PY

echo "=== test 8: review-health-probe with project v2 config (gstack) ==="
# 用 gstack 项目配置跑 health probe（应 fallback 到 gstack skill）
TMP_PROBE="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_PROBE/skills/gstack/review"
printf '%s\n' '# gstack review SKILL' > "$TMP_PROBE/skills/gstack/review/SKILL.md"
DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT2" \
DEV_FLOW_SESSION_ID=test-probe \
DEV_FLOW_HOST=codex \
GSTACK_REVIEW_SKILL_ROOT="$TMP_PROBE/skills/gstack/review" \
bash "$ROOT/scripts/review-health-probe.sh" 2>&1 | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["status"] == "available", d
assert d["selected_adapter"] == "skill/gstack", d
assert d["transport"] == "fallback", d
assert d.get("config_digest", "").startswith("sha256:"), d
print("OK: health probe reads v2 config, selects skill/gstack, returns config_digest")
'

echo ""
echo "PASS: install-review-backend.sh v2 wizard + resolver integration"
