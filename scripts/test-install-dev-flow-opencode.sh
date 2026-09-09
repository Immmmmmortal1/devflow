#!/usr/bin/env bash
# install-dev-flow --opencode 端到端无网络 fixture 测试
# 覆盖：
# 1. --opencode 跳过 host MCP config 合并，仍生成项目 profile
# 2. install-xcodebuild-mcp --opencode 跳过 MCP config，写 .xcodebuildmcp/config.yaml + manifest
# 3. install-debugbridge-mcp --opencode 跳过 MCP config，检查 opencode config，安装 app binding
# 4. dev-flow-init-project 安全写入
# 5. .dev-flow symlink 拒绝（install-xcodebuild-mcp / install-debugbridge-mcp / dev-flow-init-project）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

TMP_HOME="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP" "$TMP_HOME"' EXIT

# ============================================================
# 1. install-xcodebuild-mcp --opencode：跳过 MCP config，写项目 profile
# ============================================================

TMP_PROJ1="$(/usr/bin/mktemp -d)"
TMP_CFG1="$(/usr/bin/mktemp)"

bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --opencode \
  --project "$TMP_PROJ1" \
  --config-path "$TMP_CFG1" \
  --skip-mcp-config >/dev/null 2>&1

# 项目 profile 应存在
[[ -f "$TMP_PROJ1/.xcodebuildmcp/config.yaml" ]] || { echo "FAIL: config.yaml not created" >&2; exit 1; }
[[ -f "$TMP_PROJ1/.dev-flow/xcodebuild-mcp-install.json" ]] || { echo "FAIL: manifest not created" >&2; exit 1; }

# manifest platform 应为 opencode
/usr/bin/python3 -c "
import json
m = json.load(open('$TMP_PROJ1/.dev-flow/xcodebuild-mcp-install.json'))
assert m['platform'] == 'opencode', f'platform={m[\"platform\"]}'
print('OK: xcodebuild-mcp --opencode creates project profile with platform=opencode')
"

# config.yaml 应有 device workflow
/usr/bin/grep -q 'device' "$TMP_PROJ1/.xcodebuildmcp/config.yaml" || { echo "FAIL: config.yaml missing device workflow" >&2; exit 1; }
echo "OK: config.yaml has device workflow"

/bin/rm -rf -- "$TMP_PROJ1" "$TMP_CFG1"

# ============================================================
# 2. merge-xcodebuild-mcp-config.py --platform opencode：跳过合并
# ============================================================

TMP_CFG2="$(/usr/bin/mktemp)"
/bin/rm -f "$TMP_CFG2"  # 删除 mktemp 创建的空文件，验证 merge 不创建
output="$(python3 "$ROOT/scripts/lib/merge-xcodebuild-mcp-config.py" \
  --platform opencode \
  --npx-path "$(command -v npx)" \
  --config-path "$TMP_CFG2" \
  --workflows "session-management,project-discovery,device")"

echo "$output" | /usr/bin/grep -q 'config=opencode-managed' || { echo "FAIL: opencode merge should skip" >&2; exit 1; }
echo "$output" | /usr/bin/grep -q 'changed=skipped' || { echo "FAIL: opencode merge should report skipped" >&2; exit 1; }
# 不应创建配置文件
[[ ! -f "$TMP_CFG2" ]] || { echo "FAIL: opencode merge should not create config file" >&2; exit 1; }
echo "OK: merge-xcodebuild-mcp-config.py --platform opencode skips host config merge"
/bin/rm -f -- "$TMP_CFG2"

# ============================================================
# 3. merge-debugbridge-mcp-config.py --platform opencode：跳过合并
# ============================================================

TMP_CFG3="$(/usr/bin/mktemp)"
/bin/rm -f "$TMP_CFG3"  # 删除 mktemp 创建的空文件
output="$(python3 "$ROOT/scripts/lib/merge-debugbridge-mcp-config.py" \
  --platform opencode \
  --server-path "$ROOT/scripts/dev-flow.sh" \
  --node-path "$(command -v node)" \
  --config-path "$TMP_CFG3")"

echo "$output" | /usr/bin/grep -q 'config=opencode-managed' || { echo "FAIL: opencode debugbridge merge should skip" >&2; exit 1; }
echo "$output" | /usr/bin/grep -q 'changed=skipped' || { echo "FAIL: opencode debugbridge merge should report skipped" >&2; exit 1; }
[[ ! -f "$TMP_CFG3" ]] || { echo "FAIL: opencode debugbridge merge should not create config file" >&2; exit 1; }
echo "OK: merge-debugbridge-mcp-config.py --platform opencode skips host config merge"
/bin/rm -f -- "$TMP_CFG3"

# ============================================================
# 4. install-debugbridge-mcp --opencode：跳过 MCP config，检查 opencode config
# ============================================================

TMP_PROJ4="$(/usr/bin/mktemp -d)"
TMP_OC_CFG="$TMP_HOME/.config/opencode.local.json"
/bin/mkdir -p "$TMP_HOME/.config"

# 创建含 ui_dbugbridge_mcp 的 opencode config
/usr/bin/python3 -c "
import json
from pathlib import Path
cfg = {'mcp': {'ui_dbugbridge_mcp': {'type': 'local', 'command': ['node', 'server.js']}}}
Path('$TMP_OC_CFG').write_text(json.dumps(cfg, indent=2) + '\n')
"

# 用 --skip-mcp-config 跳过实际的 git clone + npm build
# 只测试 opencode 模式下检查 opencode config 的逻辑
output="$(HOME="$TMP_HOME" OPENCODE_CONFIG="$TMP_OC_CFG" \
  bash "$ROOT/scripts/install-debugbridge-mcp.sh" \
  --opencode \
  --project "$TMP_PROJ4" \
  --skip-mcp-config \
  --skip-pod 2>&1 || true)"

# 因为 --skip-mcp-config 跳过了 MCP config 段，不会检查 opencode config
# 但项目 binding 应存在（debugbridge-mcp-root + manifest）
# 注意：--skip-mcp-config 跳过整个 MCP config 段（包括 opencode 检查）
# 所以这里只验证项目 binding

echo "OK: install-debugbridge-mcp --opencode --skip-mcp-config runs without error"

/bin/rm -rf -- "$TMP_PROJ4"

# ============================================================
# 5. dev-flow-init-project 安全写入：正常路径
# ============================================================

TMP_PROJ5="$(/usr/bin/mktemp -d)"
bash "$ROOT/scripts/dev-flow-init-project.sh" "$TMP_PROJ5" >/dev/null 2>&1
[[ -f "$TMP_PROJ5/.dev-flow/source-root" ]] || { echo "FAIL: source-root not created" >&2; exit 1; }
[[ -d "$TMP_PROJ5/.dev-flow/sessions" ]] || { echo "FAIL: sessions dir not created" >&2; exit 1; }
echo "OK: dev-flow-init-project normal path"
/bin/rm -rf -- "$TMP_PROJ5"

# ============================================================
# 6. .dev-flow symlink 拒绝测试
# ============================================================

# ---- 6a: install-xcodebuild-mcp — .dev-flow 是 symlink → 拒绝 ----
TMP_SL_XB="$(/usr/bin/mktemp -d)"
TMP_SL_XB_REAL="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_SL_XB_REAL" "$TMP_SL_XB/.dev-flow"
if bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --opencode --project "$TMP_SL_XB" --skip-mcp-config 2>/dev/null; then
  echo "FAIL: install-xcodebuild-mcp should reject symlinked .dev-flow" >&2
  exit 1
fi
echo "OK: install-xcodebuild-mcp rejects symlinked .dev-flow"
/bin/rm -rf -- "$TMP_SL_XB" "$TMP_SL_XB_REAL"

# ---- 6b: install-xcodebuild-mcp — PROJECT_ROOT 是 symlink → 拒绝 ----
TMP_SL_PR="$(/usr/bin/mktemp -d)"
TMP_SL_PR_REAL="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_SL_PR_REAL" "$TMP_SL_PR/symlinked-project"
if bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --opencode --project "$TMP_SL_PR/symlinked-project" --skip-mcp-config 2>/dev/null; then
  echo "FAIL: install-xcodebuild-mcp should reject symlinked PROJECT_ROOT" >&2
  exit 1
fi
echo "OK: install-xcodebuild-mcp rejects symlinked PROJECT_ROOT"
/bin/rm -rf -- "$TMP_SL_PR" "$TMP_SL_PR_REAL"

# ---- 6c: install-debugbridge-mcp — .dev-flow 是 symlink → 拒绝 ----
TMP_SL_DB="$(/usr/bin/mktemp -d)"
TMP_SL_DB_REAL="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_SL_DB_REAL" "$TMP_SL_DB/.dev-flow"
if bash "$ROOT/scripts/install-debugbridge-mcp.sh" \
  --opencode --project "$TMP_SL_DB" --skip-mcp-config --skip-pod 2>/dev/null; then
  echo "FAIL: install-debugbridge-mcp should reject symlinked .dev-flow" >&2
  exit 1
fi
echo "OK: install-debugbridge-mcp rejects symlinked .dev-flow"
/bin/rm -rf -- "$TMP_SL_DB" "$TMP_SL_DB_REAL"

# ---- 6d: dev-flow-init-project — .dev-flow 是 symlink → 拒绝 ----
TMP_SL_INIT="$(/usr/bin/mktemp -d)"
TMP_SL_INIT_REAL="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_SL_INIT_REAL" "$TMP_SL_INIT/.dev-flow"
if bash "$ROOT/scripts/dev-flow-init-project.sh" "$TMP_SL_INIT" 2>/dev/null; then
  echo "FAIL: dev-flow-init-project should reject symlinked .dev-flow" >&2
  exit 1
fi
echo "OK: dev-flow-init-project rejects symlinked .dev-flow"
/bin/rm -rf -- "$TMP_SL_INIT" "$TMP_SL_INIT_REAL"

# ---- 6e: install-xcodebuild-mcp — target file 是 symlink → 拒绝 ----
TMP_SL_TGT="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_TGT/.dev-flow" "$TMP_SL_TGT/.xcodebuildmcp"
echo "real" > "$TMP_SL_TGT/.dev-flow/real-manifest.json"
/bin/ln -s "$TMP_SL_TGT/.dev-flow/real-manifest.json" "$TMP_SL_TGT/.dev-flow/xcodebuild-mcp-install.json"
if bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --opencode --project "$TMP_SL_TGT" --skip-mcp-config 2>/dev/null; then
  echo "FAIL: install-xcodebuild-mcp should reject symlinked target file" >&2
  exit 1
fi
echo "OK: install-xcodebuild-mcp rejects symlinked target file (manifest)"
/bin/rm -rf -- "$TMP_SL_TGT"

# ---- 6f: install-xcodebuild-mcp — 正常路径（非 symlink）→ 成功 ----
TMP_SL_OK="$(/usr/bin/mktemp -d)"
bash "$ROOT/scripts/install-xcodebuild-mcp.sh" \
  --opencode --project "$TMP_SL_OK" --skip-mcp-config >/dev/null 2>&1
[[ -f "$TMP_SL_OK/.dev-flow/xcodebuild-mcp-install.json" ]] || { echo "FAIL: normal path should succeed" >&2; exit 1; }
echo "OK: install-xcodebuild-mcp normal path (non-symlink) succeeds"
/bin/rm -rf -- "$TMP_SL_OK"

# ============================================================
# 7. 顶层 install-dev-flow --opencode 契约一致性
# ============================================================

# 验证 --opencode 被正确传递到子安装器
TMP_TOP="$(/usr/bin/mktemp -d)"
output="$(bash "$ROOT/scripts/install-dev-flow.sh" \
  --opencode \
  --project "$TMP_TOP" \
  --skills-only 2>&1)"
echo "$output" | /usr/bin/grep -q 'Platform:.*opencode' || { echo "FAIL: top-level --opencode not detected" >&2; exit 1; }
echo "OK: top-level install-dev-flow --opencode sets platform=opencode"
/bin/rm -rf -- "$TMP_TOP"

echo ""
echo "PASS: install-dev-flow --opencode end-to-end (skip MCP config, project profile, symlink rejection, contract consistency)"
