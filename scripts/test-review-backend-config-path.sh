#!/usr/bin/env bash
# 回归测试：自定义 opencode config 路径持久化到 adapter config
# 验证：安装时 DEV_FLOW_OPENCODE_CONFIG 指定自定义路径 → adapter config 持久化 config_path
#       后续清除环境变量、新 shell 调用 resolver 和 probe 仍能读取该路径 → available
#       config_digest 反映 config_path
# 同步验证 project/user 两套 make_adapter 逻辑
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
TMP_HOME="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP" "$TMP_HOME"' EXIT

mkdir -p "$TMP/skills" "$TMP/project/.dev-flow"

# 伪造 gstack review skill 源（供 skill/gstack adapter 安装使用，避免慢 clone）
mkdir -p "$TMP/gstack-source/review"
printf '%s\n' '# gstack review SKILL' > "$TMP/gstack-source/review/SKILL.md"
export GSTACK_REPO_ROOT="$TMP/gstack-source"

# 创建一个最小 opencode.json 让 agent probe 通过
make_oc_config() {
  local dir="$1"
  mkdir -p "$dir"
  printf '%s\n' '{"agent":{"openai-reviewer":{"model":"openrouter/openai/gpt-5.5","mode":"subagent"}},"provider":{"openrouter":{"name":"OpenRouter","options":{"baseURL":"https://openrouter.ai/api/v1","apiKey":"{env:OPENROUTER_API_KEY}"}}}}' > "$dir/opencode.json"
}

# 辅助：从 JSON 字符串提取字段（避免 heredoc/stdin 冲突）
json_get() {
  local key="$1"
  /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('$key',''))"
}

# ============================================================
# 1. project 级：自定义路径安装 → config_path 持久化
# ============================================================
echo "=== test 1: project-level install with custom opencode config path ==="

TMP_OC="$TMP/custom-oc"
make_oc_config "$TMP_OC"
CUSTOM_OC_PATH="$TMP_OC/opencode.json"

DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_PATH" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP/project" \
  --skip-mcp-config >/dev/null

# 验证 adapter config 持久化了 config_path
/usr/bin/python3 -c "
import json, sys
c = json.load(open('$TMP/project/.dev-flow/review-backend.local.json'))
adapter = c['adapters']['agent/openai-reviewer']
assert adapter['type'] == 'agent', adapter
assert adapter['identifier'] == 'openai-reviewer', adapter
assert 'config_path' in adapter, f'config_path not persisted: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC_PATH', f\"config_path mismatch: {adapter['config_path']}\"
print('OK: project-level config_path persisted in adapter config')
"

# ============================================================
# 2. 清除环境变量 → resolver 仍能读取 config_path
# ============================================================
echo "=== test 2: resolver reads config_path without env vars ==="

# 关键：不设置 DEV_FLOW_OPENCODE_CONFIG/OPENCODE_CONFIG，HOME 指向空的 TMP_HOME
# resolver 应从 adapter config 读取 config_path
selection="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP/project" \
  /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve --host opencode 2>&1)"

status="$(echo "$selection" | json_get status)"
sel_adapter="$(echo "$selection" | json_get selected_adapter)"
sel_source="$(echo "$selection" | json_get source)"
sel_digest="$(echo "$selection" | json_get config_digest)"
sel_config_path="$(echo "$selection" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("adapters",{}).get("agent/openai-reviewer",{}).get("config_path",""))')"

[[ "$status" == "available" ]] || { echo "FAIL: status=$status" >&2; exit 1; }
[[ "$sel_adapter" == "agent/openai-reviewer" ]] || { echo "FAIL: adapter=$sel_adapter" >&2; exit 1; }
[[ "$sel_source" == "project" ]] || { echo "FAIL: source=$sel_source" >&2; exit 1; }
[[ "$sel_config_path" == "$CUSTOM_OC_PATH" ]] || { echo "FAIL: config_path=$sel_config_path" >&2; exit 1; }
[[ "$sel_digest" == sha256:* ]] || { echo "FAIL: digest=$sel_digest" >&2; exit 1; }
echo "OK: resolver reads config_path from adapter config without env vars"

# ============================================================
# 3. 清除环境变量 → review-health-probe 仍 available
# ============================================================
echo "=== test 3: review-health-probe available without env vars ==="

probe_output="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP/project" \
  DEV_FLOW_SESSION_ID=test-custom-oc \
  DEV_FLOW_HOST=opencode \
  bash "$ROOT/scripts/review-health-probe.sh" 2>&1)" || {
  echo "FAIL: review-health-probe failed without env vars" >&2
  echo "$probe_output" >&2
  exit 1
}

probe_status="$(echo "$probe_output" | json_get status)"
probe_adapter="$(echo "$probe_output" | json_get selected_adapter)"
probe_transport="$(echo "$probe_output" | json_get transport)"
probe_digest="$(echo "$probe_output" | json_get config_digest)"

[[ "$probe_status" == "available" ]] || { echo "FAIL: probe status=$probe_status" >&2; exit 1; }
[[ "$probe_adapter" == "agent/openai-reviewer" ]] || { echo "FAIL: probe adapter=$probe_adapter" >&2; exit 1; }
[[ "$probe_transport" == "reviewer" ]] || { echo "FAIL: transport=$probe_transport" >&2; exit 1; }
[[ "$probe_digest" == sha256:* ]] || { echo "FAIL: probe digest=$probe_digest" >&2; exit 1; }
echo "OK: review-health-probe available without env vars (reads config_path from adapter config)"

# ============================================================
# 4. config_digest 反映 config_path（改变路径 → digest 变化）
# ============================================================
echo "=== test 4: config_digest reflects config_path ==="

# 用不同自定义路径安装到另一个项目，比较 digest
TMP_PROJECT2="$(/usr/bin/mktemp -d)"
TMP_OC2="$TMP/custom-oc2"
make_oc_config "$TMP_OC2"
CUSTOM_OC_PATH2="$TMP_OC2/opencode.json"

DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_PATH2" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT2" \
  --skip-mcp-config >/dev/null

selection2="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT2" \
  /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve --host opencode 2>&1)"

digest2="$(echo "$selection2" | json_get config_digest)"

[[ "$sel_digest" != "$digest2" ]] || {
  echo "FAIL: config_digest should differ when config_path differs" >&2
  echo "digest1=$sel_digest (path=$CUSTOM_OC_PATH)" >&2
  echo "digest2=$digest2 (path=$CUSTOM_OC_PATH2)" >&2
  exit 1
}
echo "OK: config_digest differs when config_path differs ($sel_digest vs $digest2)"

/bin/rm -rf -- "$TMP_PROJECT2"

# ============================================================
# 5. user 级：自定义路径安装 → config_path 持久化
# ============================================================
echo "=== test 5: user-level install with custom opencode config path ==="

TMP_USER_HOME="$(/usr/bin/mktemp -d)"
TMP_OC_USER="$TMP/custom-oc-user"
make_oc_config "$TMP_OC_USER"
CUSTOM_OC_PATH_USER="$TMP_OC_USER/opencode.json"

DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_PATH_USER" HOME="$TMP_USER_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_USER_HOME/.config/dev-flow/config.json'))
profile = c['hosts']['opencode']
adapter = profile['adapters']['agent/openai-reviewer']
assert adapter['type'] == 'agent', adapter
assert 'config_path' in adapter, f'config_path not persisted: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC_PATH_USER', f\"config_path mismatch: {adapter['config_path']}\"
print('OK: user-level config_path persisted in adapter config')
"

# ============================================================
# 6. user 级：清除环境变量 → resolver 仍 available
# ============================================================
echo "=== test 6: user-level resolver available without env vars ==="

selection_user="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_USER_HOME" \
  /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve --host opencode 2>&1)"

user_status="$(echo "$selection_user" | json_get status)"
user_adapter="$(echo "$selection_user" | json_get selected_adapter)"
user_source="$(echo "$selection_user" | json_get source)"
user_digest="$(echo "$selection_user" | json_get config_digest)"
user_config_path="$(echo "$selection_user" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("adapters",{}).get("agent/openai-reviewer",{}).get("config_path",""))')"

[[ "$user_status" == "available" ]] || { echo "FAIL: user status=$user_status" >&2; exit 1; }
[[ "$user_adapter" == "agent/openai-reviewer" ]] || { echo "FAIL: user adapter=$user_adapter" >&2; exit 1; }
[[ "$user_source" == "user" ]] || { echo "FAIL: user source=$user_source" >&2; exit 1; }
[[ "$user_config_path" == "$CUSTOM_OC_PATH_USER" ]] || { echo "FAIL: user config_path=$user_config_path" >&2; exit 1; }
[[ "$user_digest" == sha256:* ]] || { echo "FAIL: user digest=$user_digest" >&2; exit 1; }
echo "OK: user-level resolver reads config_path without env vars"

/bin/rm -rf -- "$TMP_USER_HOME"

# ============================================================
# 7. 默认路径安装 → config_path 不持久化（向后兼容）
# ============================================================
echo "=== test 7: default path install → config_path not persisted ==="

TMP_PROJECT3="$(/usr/bin/mktemp -d)"
TMP_HOME3="$(/usr/bin/mktemp -d)"
# 创建默认路径下的 opencode.json（使 reviewer_ready 通过）
mkdir -p "$TMP_HOME3/.config/opencode"
make_oc_config "$TMP_HOME3/.config/opencode"

# 不设置 DEV_FLOW_OPENCODE_CONFIG → 用默认路径
# 必须同时 unset OPENCODE_CONFIG（实际环境可能已设置）
env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT3" \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_PROJECT3/.dev-flow/review-backend.local.json'))
adapter = c['adapters']['agent/openai-reviewer']
assert 'config_path' not in adapter, f'config_path should not be persisted for default path: {adapter}'
print('OK: default path → config_path not persisted (backward compatible)')
"

/bin/rm -rf -- "$TMP_PROJECT3" "$TMP_HOME3"

# ============================================================
# 8. 自定义路径是 symlink → fail closed
# ============================================================
echo "=== test 8: symlinked custom opencode config path → fail closed ==="

TMP_PROJECT4="$(/usr/bin/mktemp -d)"
TMP_OC_REAL="$TMP/custom-oc-real"
make_oc_config "$TMP_OC_REAL"
TMP_OC_LINK="$TMP/custom-oc-link"
mkdir -p "$TMP_OC_LINK"
ln -s "$TMP_OC_REAL/opencode.json" "$TMP_OC_LINK/opencode.json"

if DEV_FLOW_OPENCODE_CONFIG="$TMP_OC_LINK/opencode.json" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT4" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: symlinked config path should fail closed" >&2
  exit 1
fi
echo "OK: symlinked custom opencode config path fails closed"

/bin/rm -rf -- "$TMP_PROJECT4" "$TMP_OC_LINK"

# ============================================================
# 9. 自定义路径不存在 → fail closed
# ============================================================
echo "=== test 9: non-existent custom opencode config path → fail closed ==="

TMP_PROJECT5="$(/usr/bin/mktemp -d)"

# reviewer_ready 会先检查文件不存在 → install_reviewer 失败
# 但即使绕过 install_reviewer（如 fallback adapter），make_adapter 也会 fail closed
if DEV_FLOW_OPENCODE_CONFIG="$TMP/nonexistent-oc/opencode.json" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT5" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: non-existent config path should fail closed" >&2
  exit 1
fi
echo "OK: non-existent custom opencode config path fails closed"

/bin/rm -rf -- "$TMP_PROJECT5"

# ============================================================
# 10. fallback adapter 也持久化 config_path（primary 非 agent）
# ============================================================
echo "=== test 10: fallback agent/openai-reviewer persists config_path ==="

TMP_PROJECT6="$(/usr/bin/mktemp -d)"
TMP_OC_FB="$TMP/custom-oc-fb"
make_oc_config "$TMP_OC_FB"
CUSTOM_OC_FB="$TMP_OC_FB/opencode.json"

# primary = gstack, fallback 包含 agent/openai-reviewer
# 即使 primary 不是 agent，fallback 的 agent adapter 也应持久化 config_path
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_FB" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT6" \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_PROJECT6/.dev-flow/review-backend.local.json'))
assert 'agent/openai-reviewer' in c.get('fallback_order', []), f'agent not in fallback_order: {c}'
adapter = c['adapters'].get('agent/openai-reviewer', {})
assert 'config_path' in adapter, f'config_path not persisted in fallback adapter: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC_FB', f\"config_path mismatch: {adapter['config_path']}\"
print('OK: fallback agent/openai-reviewer persists config_path')
"

/bin/rm -rf -- "$TMP_PROJECT6"

# ============================================================
# 11. 首次 custom install → 清除 env → 再次运行 installer → config_path 保留且 digest 稳定
# ============================================================
echo "=== test 11: reinstall without env preserves config_path + stable digest ==="

TMP_PROJECT7="$(/usr/bin/mktemp -d)"
TMP_OC7="$TMP/custom-oc7"
make_oc_config "$TMP_OC7"
CUSTOM_OC7="$TMP_OC7/opencode.json"

# 首次安装（带自定义路径）
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC7" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT7" \
  --skip-mcp-config >/dev/null

# 首次 digest
digest_first="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT7" \
  /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve --host opencode 2>&1 | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"

# 再次运行 installer（清除 env，不设自定义路径）
# 期望：从已有 config 读取 config_path 并重新校验，保留不变
env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT7" \
  --skip-mcp-config >/dev/null

# 验证 config_path 仍保留
/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_PROJECT7/.dev-flow/review-backend.local.json'))
adapter = c['adapters']['agent/openai-reviewer']
assert 'config_path' in adapter, f'config_path lost after reinstall: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC7', f\"config_path changed: {adapter['config_path']}\"
print('OK: config_path preserved after reinstall without env')
"

# 验证 digest 稳定（不变）
digest_second="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT7" \
  /usr/bin/python3 "$ROOT/scripts/lib/review_backend_resolver.py" resolve --host opencode 2>&1 | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["config_digest"])')"

[[ "$digest_first" == "$digest_second" ]] || {
  echo "FAIL: digest changed after reinstall: $digest_first → $digest_second" >&2
  exit 1
}
echo "OK: digest stable after reinstall ($digest_first)"

/bin/rm -rf -- "$TMP_PROJECT7"

# ============================================================
# 12. 切换 primary/fallback 后 config_path 仍保留
# ============================================================
echo "=== test 12: switch primary preserves config_path ==="

TMP_PROJECT8="$(/usr/bin/mktemp -d)"
TMP_OC8="$TMP/custom-oc8"
make_oc_config "$TMP_OC8"
CUSTOM_OC8="$TMP_OC8/opencode.json"

# 首次安装 primary=agent/openai-reviewer
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC8" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT8" \
  --skip-mcp-config >/dev/null

# 切换 primary=gstack（清除 env），agent 变为 fallback
# 期望：agent fallback 的 config_path 从已有 config 读取并保留
env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT8" \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_PROJECT8/.dev-flow/review-backend.local.json'))
assert c['primary'] == 'skill/gstack', f'primary should be gstack: {c[\"primary\"]}'
assert 'agent/openai-reviewer' in c.get('fallback_order', []), f'agent not in fallback_order: {c}'
adapter = c['adapters'].get('agent/openai-reviewer', {})
assert 'config_path' in adapter, f'config_path lost after primary switch: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC8', f\"config_path changed: {adapter['config_path']}\"
print('OK: config_path preserved after switching primary (agent → fallback)')
"

/bin/rm -rf -- "$TMP_PROJECT8"

# ============================================================
# 13. 已存 config_path 失效（文件删除）→ 重装阻塞 fail closed
# ============================================================
echo "=== test 13: stale config_path → reinstall fails closed ==="

TMP_PROJECT9="$(/usr/bin/mktemp -d)"
TMP_OC9="$TMP/custom-oc9"
make_oc_config "$TMP_OC9"
CUSTOM_OC9="$TMP_OC9/opencode.json"

# 首次安装
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC9" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT9" \
  --skip-mcp-config >/dev/null

# 删除 opencode config 文件（使已存 config_path 失效）
/bin/rm -f -- "$CUSTOM_OC9"

# 再次运行 installer（清除 env）→ 期望 fail closed
if env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT9" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: stale config_path should fail closed on reinstall" >&2
  exit 1
fi
echo "OK: stale config_path fails closed on reinstall (not silently dropped)"

/bin/rm -rf -- "$TMP_PROJECT9"

# ============================================================
# 14. user 级：首次 custom install → 清除 env → 重装 → config_path 保留
# ============================================================
echo "=== test 14: user-level reinstall preserves config_path ==="

TMP_USER_HOME2="$(/usr/bin/mktemp -d)"
TMP_OC_USER2="$TMP/custom-oc-user2"
make_oc_config "$TMP_OC_USER2"
CUSTOM_OC_USER2="$TMP_OC_USER2/opencode.json"

# 首次安装
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_USER2" HOME="$TMP_USER_HOME2" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config >/dev/null

# 再次运行 installer（清除 env）
env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_USER_HOME2" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_USER_HOME2/.config/dev-flow/config.json'))
adapter = c['hosts']['opencode']['adapters']['agent/openai-reviewer']
assert 'config_path' in adapter, f'config_path lost after user reinstall: {adapter}'
assert adapter['config_path'] == '$CUSTOM_OC_USER2', f\"config_path changed: {adapter['config_path']}\"
print('OK: user-level config_path preserved after reinstall without env')
"

/bin/rm -rf -- "$TMP_USER_HOME2"

# ============================================================
# 15. probe 优先级：A 持久化后，env=B 探活读取 B；清除 env 读取 A
# ============================================================
echo "=== test 15: probe env override > adapter config_path ==="

TMP_PROJECT10="$(/usr/bin/mktemp -d)"
TMP_OC_A="$TMP/custom-oc-A"
make_oc_config "$TMP_OC_A"
CUSTOM_OC_A="$TMP_OC_A/opencode.json"
TMP_OC_B="$TMP/custom-oc-B"
make_oc_config "$TMP_OC_B"
CUSTOM_OC_B="$TMP_OC_B/opencode.json"

# 安装时持久化 config_path=A
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_A" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --project "$TMP_PROJECT10" \
  --skip-mcp-config >/dev/null

# 验证持久化的是 A
/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_PROJECT10/.dev-flow/review-backend.local.json'))
assert c['adapters']['agent/openai-reviewer']['config_path'] == '$CUSTOM_OC_A'
print('OK: persisted config_path = A')
"

# 探活：env=B → probe 应读 B（env 优先于 adapter config_path）
probe_b="$(DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_B" \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT10" \
  DEV_FLOW_SESSION_ID=test-probe-env \
  DEV_FLOW_HOST=opencode \
  bash "$ROOT/scripts/review-health-probe.sh" 2>&1)" || {
  echo "FAIL: probe with env=B should succeed" >&2
  echo "$probe_b" >&2
  exit 1
}
probe_b_status="$(echo "$probe_b" | json_get status)"
[[ "$probe_b_status" == "available" ]] || { echo "FAIL: probe env=B status=$probe_b_status" >&2; exit 1; }
echo "OK: probe with env=B available (env override takes priority)"

# 探活：清除 env → probe 应读 A（adapter config_path）
probe_a="$(env -u DEV_FLOW_OPENCODE_CONFIG -u OPENCODE_CONFIG \
  HOME="$TMP_HOME" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT10" \
  DEV_FLOW_SESSION_ID=test-probe-noenv \
  DEV_FLOW_HOST=opencode \
  bash "$ROOT/scripts/review-health-probe.sh" 2>&1)" || {
  echo "FAIL: probe without env should succeed (reads A)" >&2
  echo "$probe_a" >&2
  exit 1
}
probe_a_status="$(echo "$probe_a" | json_get status)"
[[ "$probe_a_status" == "available" ]] || { echo "FAIL: probe no-env status=$probe_a_status" >&2; exit 1; }
echo "OK: probe without env available (reads persisted config_path A)"

/bin/rm -rf -- "$TMP_PROJECT10"

# ============================================================
# 16. project config 损坏 → installer fail closed，不静默重写
# ============================================================
echo "=== test 16: corrupted project config → installer fail closed ==="

TMP_PROJECT11="$(/usr/bin/mktemp -d)"
mkdir -p "$TMP_PROJECT11/.dev-flow"

# 写入损坏的 JSON（非 object，是 array）
printf '[1, 2, 3]\n' > "$TMP_PROJECT11/.dev-flow/review-backend.local.json"
# 记录 mtime 和 content
mtime_before="$(/usr/bin/stat -f '%m' "$TMP_PROJECT11/.dev-flow/review-backend.local.json")"
content_before="$(/bin/cat "$TMP_PROJECT11/.dev-flow/review-backend.local.json")"

# installer 应 fail closed
if DEV_FLOW_OPENCODE_CONFIG="$TMP/nonexistent.json" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT11" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: corrupted project config (array) should fail closed" >&2
  exit 1
fi
echo "OK: corrupted project config (array) fails closed"

# 验证文件未被覆盖
content_after="$(/bin/cat "$TMP_PROJECT11/.dev-flow/review-backend.local.json")"
[[ "$content_before" == "$content_after" ]] || {
  echo "FAIL: corrupted project config was overwritten" >&2
  exit 1
}
echo "OK: corrupted project config content not overwritten"

# 也测试 JSON 解析失败（坏 JSON）
printf '{bad json\n' > "$TMP_PROJECT11/.dev-flow/review-backend.local.json"
if DEV_FLOW_OPENCODE_CONFIG="$TMP/nonexistent.json" HOME="$TMP_HOME" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend gstack \
  --project "$TMP_PROJECT11" \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: corrupted project config (bad JSON) should fail closed" >&2
  exit 1
fi
echo "OK: corrupted project config (bad JSON) fails closed"

/bin/rm -rf -- "$TMP_PROJECT11"

# ============================================================
# 17. user config 损坏 → installer fail closed，不丢其他 host profile
# ============================================================
echo "=== test 17: corrupted user config → installer fail closed ==="

TMP_USER_HOME3="$(/usr/bin/mktemp -d)"
TMP_OC_U3="$TMP/custom-oc-u3"
make_oc_config "$TMP_OC_U3"
CUSTOM_OC_U3="$TMP_OC_U3/opencode.json"
mkdir -p "$TMP_USER_HOME3/.config/dev-flow"

# 写入损坏的 JSON（非 object，是 array）
printf '[1, 2, 3]\n' > "$TMP_USER_HOME3/.config/dev-flow/config.json"

if DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_U3" HOME="$TMP_USER_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: corrupted user config (array) should fail closed" >&2
  exit 1
fi
echo "OK: corrupted user config (array) fails closed"

# 验证文件未被覆盖
content_after="$(/bin/cat "$TMP_USER_HOME3/.config/dev-flow/config.json")"
[[ "$content_after" == '[1, 2, 3]'* ]] || {
  echo "FAIL: corrupted user config was overwritten" >&2
  exit 1
}
echo "OK: corrupted user config content not overwritten"

# 测试 hosts 非 object
printf '{"schema_version":2,"hosts":"not-an-object"}\n' > "$TMP_USER_HOME3/.config/dev-flow/config.json"
if DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_U3" HOME="$TMP_USER_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: user config with non-object hosts should fail closed" >&2
  exit 1
fi
echo "OK: user config with non-object hosts fails closed"

# 测试 host profile 非 object
printf '{"schema_version":2,"hosts":{"opencode":"not-an-object"}}\n' > "$TMP_USER_HOME3/.config/dev-flow/config.json"
if DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_U3" HOME="$TMP_USER_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: user config with non-object host profile should fail closed" >&2
  exit 1
fi
echo "OK: user config with non-object host profile fails closed"

# 测试 JSON 解析失败
printf '{bad json\n' > "$TMP_USER_HOME3/.config/dev-flow/config.json"
if DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_U3" HOME="$TMP_USER_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config 2>/dev/null; then
  echo "FAIL: corrupted user config (bad JSON) should fail closed" >&2
  exit 1
fi
echo "OK: corrupted user config (bad JSON) fails closed"

# 正面：已有合法多 host profile → 安装新 host 不丢其他 host
printf '{"schema_version":2,"hosts":{"cursor":{"primary":"mcp/orchestrator","fallback_policy":"allow","fallback_order":[],"adapters":{"mcp/orchestrator":{"type":"mcp","identifier":"orchestrator-mcp"}}}}}\n' > "$TMP_USER_HOME3/.config/dev-flow/config.json"
DEV_FLOW_OPENCODE_CONFIG="$CUSTOM_OC_U3" HOME="$TMP_USER_HOME3" \
  bash "$ROOT/scripts/install-review-backend.sh" \
  --opencode \
  --skills-root "$TMP/skills" \
  --review-backend agent/openai-reviewer \
  --save-level user \
  --skip-mcp-config >/dev/null

/usr/bin/python3 -c "
import json
c = json.load(open('$TMP_USER_HOME3/.config/dev-flow/config.json'))
# cursor profile 应保留
assert 'cursor' in c['hosts'], f'cursor profile lost: {c[\"hosts\"].keys()}'
assert c['hosts']['cursor']['primary'] == 'mcp/orchestrator', f'cursor profile corrupted'
# opencode profile 应新增
assert 'opencode' in c['hosts'], f'opencode profile missing'
assert c['hosts']['opencode']['primary'] == 'agent/openai-reviewer'
print('OK: existing host profile preserved when adding new host')
"

/bin/rm -rf -- "$TMP_USER_HOME3"

echo ""
echo "PASS: custom opencode config path persistence (project + user + fallback + reinstall + fail-closed + env-override + corrupted-config)"
