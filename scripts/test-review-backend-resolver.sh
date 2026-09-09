#!/usr/bin/env bash
# review_backend_resolver.py 单元测试：3-tier 优先级 + v1 兼容 + unknown fail-closed + config_digest
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/scripts/lib/review_backend_resolver.py"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  OK: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ── test 1: default policy (no config) → agent/openai-reviewer on opencode ──
echo "=== test 1: default policy ==="
result="$(DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_HOST=opencode DEV_FLOW_OPENCODE_CONFIG="$TMP/nonexistent.json" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "default adapter" "$adapter" "agent/openai-reviewer"
assert_eq "default source" "$source" "default"

# ── test 2: CLI override (--adapter) ──
echo "=== test 2: CLI override ==="
result="$(DEV_FLOW_PROJECT_ROOT="$TMP" DEV_FLOW_HOST=opencode DEV_FLOW_REVIEW_ADAPTER=skill/gstack /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "CLI override adapter" "$adapter" "skill/gstack"
assert_eq "CLI override source" "$source" "cli"

# ── test 3: project config (v2) ──
echo "=== test 3: project v2 config ==="
mkdir -p "$TMP/proj1/.dev-flow"
cat > "$TMP/proj1/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "codex",
  "primary": "mcp/orchestrator",
  "fallback_policy": "allow",
  "fallback_order": ["skill/gstack"],
  "adapters": {
    "mcp/orchestrator": {"type": "mcp", "identifier": "orchestrator-mcp"},
    "skill/gstack": {"type": "skill", "identifier": "gstack-review", "skill_path": "/tmp/skill.md"}
  }
}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
digest="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
assert_eq "project v2 adapter" "$adapter" "mcp/orchestrator"
assert_eq "project v2 source" "$source" "project"
assert_eq "project v2 digest prefix" "${digest:0:7}" "sha256:"

# ── test 4: v1 config lazy migration ──
echo "=== test 4: v1 config migration ==="
mkdir -p "$TMP/proj2/.dev-flow"
cat > "$TMP/proj2/.dev-flow/review-backend.json" <<'JSON'
{"backend": "gstack", "schema_version": 1}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj2" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "v1 migration adapter" "$adapter" "skill/gstack"
assert_eq "v1 migration source" "$source" "project"

# ── test 5: v1 alias 'reviewer' → agent/openai-reviewer ──
echo "=== test 5: v1 alias reviewer ==="
mkdir -p "$TMP/proj3/.dev-flow"
cat > "$TMP/proj3/.dev-flow/review-backend.json" <<'JSON'
{"backend": "reviewer", "schema_version": 1}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj3" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
assert_eq "v1 alias reviewer" "$adapter" "agent/openai-reviewer"

# ── test 6: v1 alias 'orchestrator' → mcp/orchestrator ──
echo "=== test 6: v1 alias orchestrator ==="
mkdir -p "$TMP/proj4/.dev-flow"
cat > "$TMP/proj4/.dev-flow/review-backend.json" <<'JSON'
{"backend": "orchestrator", "schema_version": 1}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj4" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
assert_eq "v1 alias orchestrator" "$adapter" "mcp/orchestrator"

# ── test 7: unknown backend → fail closed ──
echo "=== test 7: unknown backend fail closed ==="
mkdir -p "$TMP/proj5/.dev-flow"
cat > "$TMP/proj5/.dev-flow/review-backend.json" <<'JSON'
{"backend": "bogus", "schema_version": 1}
JSON
if DEV_FLOW_PROJECT_ROOT="$TMP/proj5" /usr/bin/python3 "$RESOLVER" resolve >/dev/null 2>&1; then
  echo "  FAIL: unknown backend should fail closed" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: unknown backend fails closed"
  PASS=$((PASS + 1))
fi

# ── test 8: CLI override takes priority over project config ──
echo "=== test 8: CLI > project config ==="
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" DEV_FLOW_REVIEW_ADAPTER=skill/gstack /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "CLI > project adapter" "$adapter" "skill/gstack"
assert_eq "CLI > project source" "$source" "cli"

# ── test 9: config_digest is deterministic (same config → same digest) ──
echo "=== test 9: config_digest determinism ==="
digest1="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
digest2="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
assert_eq "digest determinism" "$digest1" "$digest2"

# ── test 10: user config (schema v2 host profile) ──
echo "=== test 10: user config ==="
TMP_HOME2="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_HOME2/.config/dev-flow"
cat > "$TMP_HOME2/.config/dev-flow/config.json" <<'JSON'
{
  "schema_version": 2,
  "hosts": {
    "codex": {
      "primary": "skill/gstack",
      "fallback_policy": "allow",
      "fallback_order": [],
      "adapters": {
        "skill/gstack": {"type": "skill", "identifier": "gstack-review"}
      }
    }
  }
}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/empty_proj" DEV_FLOW_USER_CONFIG_PATH="$TMP_HOME2/.config/dev-flow/config.json" DEV_FLOW_HOST=codex /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "user config adapter" "$adapter" "skill/gstack"
assert_eq "user config source" "$source" "user"
rm -rf "$TMP_HOME2"

# ── test 11: project config takes priority over user config ──
echo "=== test 11: project > user config ==="
TMP_HOME3="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_HOME3/.config/dev-flow"
cat > "$TMP_HOME3/.config/dev-flow/config.json" <<'JSON'
{
  "schema_version": 2,
  "hosts": {
    "codex": {
      "primary": "skill/gstack",
      "fallback_policy": "allow",
      "fallback_order": [],
      "adapters": {"skill/gstack": {"type": "skill", "identifier": "gstack-review"}}
    }
  }
}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" DEV_FLOW_USER_CONFIG_PATH="$TMP_HOME3/.config/dev-flow/config.json" DEV_FLOW_HOST=codex /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
adapter="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])')"
source="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["source"])')"
assert_eq "project > user adapter" "$adapter" "mcp/orchestrator"
assert_eq "project > user source" "$source" "project"
rm -rf "$TMP_HOME3"

# ── test 12: validate subcommand (validates a config file) ──
echo "=== test 12: validate subcommand ==="
# valid v2 config
cat > "$TMP/valid-config.json" <<'JSON'
{"schema_version":2,"host":"codex","primary":"skill/gstack","fallback_policy":"allow","fallback_order":[],"adapters":{"skill/gstack":{"type":"skill","identifier":"gstack-review"}}}
JSON
if /usr/bin/python3 "$RESOLVER" validate --config-path "$TMP/valid-config.json" >/dev/null 2>&1; then
  echo "  OK: validate accepts valid v2 config"
  PASS=$((PASS + 1))
else
  echo "  FAIL: validate rejected valid v2 config" >&2
  FAIL=$((FAIL + 1))
fi
# invalid: unknown adapter
cat > "$TMP/invalid-config.json" <<'JSON'
{"schema_version":2,"host":"codex","primary":"bogus","fallback_policy":"allow","fallback_order":[],"adapters":{"bogus":{"type":"x","identifier":"y"}}}
JSON
if /usr/bin/python3 "$RESOLVER" validate --config-path "$TMP/invalid-config.json" >/dev/null 2>&1; then
  echo "  FAIL: validate accepted config with unknown adapter" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: validate rejects config with unknown adapter"
  PASS=$((PASS + 1))
fi

# ── test 13: cross-type field rejection (agent must not carry root/skill_path) ──
echo "=== test 13: cross-type field rejection ==="

# agent 携带 root（mcp 字段）→ fail closed
mkdir -p "$TMP/proj_cross1/.dev-flow"
cat > "$TMP/proj_cross1/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "opencode",
  "primary": "agent/openai-reviewer",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "agent/openai-reviewer": {"type": "agent", "identifier": "openai-reviewer", "root": "/tmp/orch"}
  }
}
JSON
if DEV_FLOW_PROJECT_ROOT="$TMP/proj_cross1" /usr/bin/python3 "$RESOLVER" resolve >/dev/null 2>&1; then
  echo "  FAIL: agent with root field should fail closed" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: agent with root field fails closed (cross-type field rejected)"
  PASS=$((PASS + 1))
fi

# mcp 携带 config_path（agent 字段）→ fail closed
mkdir -p "$TMP/proj_cross2/.dev-flow"
cat > "$TMP/proj_cross2/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "codex",
  "primary": "mcp/orchestrator",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "mcp/orchestrator": {"type": "mcp", "identifier": "orchestrator-mcp", "root": "/tmp/orch", "config_path": "/tmp/oc.json"}
  }
}
JSON
if DEV_FLOW_PROJECT_ROOT="$TMP/proj_cross2" /usr/bin/python3 "$RESOLVER" resolve >/dev/null 2>&1; then
  echo "  FAIL: mcp with config_path field should fail closed" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: mcp with config_path field fails closed (cross-type field rejected)"
  PASS=$((PASS + 1))
fi

# skill 携带 root（mcp 字段）→ fail closed
mkdir -p "$TMP/proj_cross3/.dev-flow"
cat > "$TMP/proj_cross3/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "codex",
  "primary": "skill/gstack",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "skill/gstack": {"type": "skill", "identifier": "gstack-review", "skill_path": "/tmp/skill.md", "root": "/tmp/orch"}
  }
}
JSON
if DEV_FLOW_PROJECT_ROOT="$TMP/proj_cross3" /usr/bin/python3 "$RESOLVER" resolve >/dev/null 2>&1; then
  echo "  FAIL: skill with root field should fail closed" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: skill with root field fails closed (cross-type field rejected)"
  PASS=$((PASS + 1))
fi

# agent 携带 skill_path（skill 字段）→ fail closed
mkdir -p "$TMP/proj_cross4/.dev-flow"
cat > "$TMP/proj_cross4/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "opencode",
  "primary": "agent/openai-reviewer",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "agent/openai-reviewer": {"type": "agent", "identifier": "openai-reviewer", "skill_path": "/tmp/skill.md"}
  }
}
JSON
if DEV_FLOW_PROJECT_ROOT="$TMP/proj_cross4" /usr/bin/python3 "$RESOLVER" resolve >/dev/null 2>&1; then
  echo "  FAIL: agent with skill_path field should fail closed" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: agent with skill_path field fails closed (cross-type field rejected)"
  PASS=$((PASS + 1))
fi

# 正面：agent 携带 config_path（agent 字段）→ 通过
mkdir -p "$TMP/proj_valid_agent/.dev-flow"
cat > "$TMP/proj_valid_agent/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "opencode",
  "primary": "agent/openai-reviewer",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "agent/openai-reviewer": {"type": "agent", "identifier": "openai-reviewer", "config_path": "/tmp/oc.json"}
  }
}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj_valid_agent" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
if [[ "$status" == "available" ]]; then
  echo "  OK: agent with config_path accepted (same-type field)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: agent with config_path should be accepted" >&2
  FAIL=$((FAIL + 1))
fi

# 正面：mcp 携带 root（mcp 字段）→ 通过
mkdir -p "$TMP/proj_valid_mcp/.dev-flow"
cat > "$TMP/proj_valid_mcp/.dev-flow/review-backend.local.json" <<'JSON'
{
  "schema_version": 2,
  "host": "codex",
  "primary": "mcp/orchestrator",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "mcp/orchestrator": {"type": "mcp", "identifier": "orchestrator-mcp", "root": "/tmp/orch"}
  }
}
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj_valid_mcp" /usr/bin/python3 "$RESOLVER" resolve 2>/dev/null)"
status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
if [[ "$status" == "available" ]]; then
  echo "  OK: mcp with root accepted (same-type field)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: mcp with root should be accepted" >&2
  FAIL=$((FAIL + 1))
fi

# ── test 14: env override takes priority over adapter config_path (Major 1) ──
echo "=== test 14: env override > adapter config_path ==="

# 项目配置中持久化了 config_path=A
mkdir -p "$TMP/proj_env_override/.dev-flow"
TMP_OC_A="$TMP/oc-a.json"
printf '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$TMP_OC_A"
cat > "$TMP/proj_env_override/.dev-flow/review-backend.local.json" <<JSON
{
  "schema_version": 2,
  "host": "opencode",
  "primary": "agent/openai-reviewer",
  "fallback_policy": "allow",
  "fallback_order": [],
  "adapters": {
    "agent/openai-reviewer": {"type": "agent", "identifier": "openai-reviewer", "config_path": "$TMP_OC_A"}
  }
}
JSON

# 不设 env → resolver 用 adapter 中的 config_path=A
result="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  DEV_FLOW_PROJECT_ROOT="$TMP/proj_env_override" \
  /usr/bin/python3 "$RESOLVER" resolve --host opencode 2>/dev/null)"
resolved_cp="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["adapters"]["agent/openai-reviewer"].get("config_path",""))')"
digest_no_env="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
assert_eq "no env: config_path = A" "$resolved_cp" "$TMP_OC_A"

# 设 env=config_path=B → resolver 应覆盖为 B，digest 应反映 B
TMP_OC_B="$TMP/oc-b.json"
printf '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$TMP_OC_B"
result="$(DEV_FLOW_OPENCODE_CONFIG="$TMP_OC_B" \
  DEV_FLOW_PROJECT_ROOT="$TMP/proj_env_override" \
  /usr/bin/python3 "$RESOLVER" resolve --host opencode 2>/dev/null)"
resolved_cp_env="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["adapters"]["agent/openai-reviewer"].get("config_path",""))')"
digest_env="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
assert_eq "env override: config_path = B" "$resolved_cp_env" "$TMP_OC_B"
if [[ "$digest_env" != "$digest_no_env" ]]; then
  echo "  OK: digest changes when env overrides config_path"
  PASS=$((PASS + 1))
else
  echo "  FAIL: digest should differ when env overrides config_path" >&2
  FAIL=$((FAIL + 1))
fi

# 清除 env → resolver 回到 adapter 中的 config_path=A，digest 恢复
result="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  DEV_FLOW_PROJECT_ROOT="$TMP/proj_env_override" \
  /usr/bin/python3 "$RESOLVER" resolve --host opencode 2>/dev/null)"
digest_restore="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"
assert_eq "env cleared: digest restored" "$digest_restore" "$digest_no_env"

# ── test 15: v1 config as array → structured fail closed (Major 3) ──
echo "=== test 15: v1 config array/string fail closed ==="

# v1 config 是 JSON array → 结构化 fail closed（不 traceback）
mkdir -p "$TMP/proj_v1_array/.dev-flow"
cat > "$TMP/proj_v1_array/.dev-flow/review-backend.json" <<'JSON'
[1, 2, 3]
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj_v1_array" /usr/bin/python3 "$RESOLVER" resolve 2>&1 || true)"
status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
if [[ "$status" == "blocked" ]]; then
  echo "  OK: v1 config as array fails closed (structured)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: v1 config as array should fail closed with blocked status" >&2
  echo "  output: $result" >&2
  FAIL=$((FAIL + 1))
fi

# v1 config 是 JSON string → 结构化 fail closed
mkdir -p "$TMP/proj_v1_string/.dev-flow"
cat > "$TMP/proj_v1_string/.dev-flow/review-backend.json" <<'JSON'
"just a string"
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj_v1_string" /usr/bin/python3 "$RESOLVER" resolve 2>&1 || true)"
status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
if [[ "$status" == "blocked" ]]; then
  echo "  OK: v1 config as string fails closed (structured)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: v1 config as string should fail closed with blocked status" >&2
  echo "  output: $result" >&2
  FAIL=$((FAIL + 1))
fi

# v1 config 是 JSON number → 结构化 fail closed
mkdir -p "$TMP/proj_v1_number/.dev-flow"
cat > "$TMP/proj_v1_number/.dev-flow/review-backend.json" <<'JSON'
42
JSON
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj_v1_number" /usr/bin/python3 "$RESOLVER" resolve 2>&1 || true)"
status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
if [[ "$status" == "blocked" ]]; then
  echo "  OK: v1 config as number fails closed (structured)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: v1 config as number should fail closed with blocked status" >&2
  echo "  output: $result" >&2
  FAIL=$((FAIL + 1))
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "PASS: review_backend_resolver.py unit tests ($PASS assertions)"
else
  echo "FAIL: $FAIL assertions failed out of $((PASS + FAIL))" >&2
  exit 1
fi
