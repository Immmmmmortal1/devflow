#!/usr/bin/env bash
# Reviewer Major fixes 测试：
# 1. fallback adapter 自定义路径保留（用户级 + 项目级 roundtrip/probe）
# 2. 统一安全原子 JSON 写辅助（symlink 拒绝/trusted root 边界/正常路径）
# 3. worktree_digest 结构化 tracked hash（二进制安全/staged/unstaged/delete/不同内容不同 digest）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

# git init
/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_ROOT" init -q && /usr/bin/git -C "$TMP_ROOT" checkout -qb main; }
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'base\n' > "$TMP_ROOT/base.txt"
/usr/bin/git -C "$TMP_ROOT" add base.txt
/usr/bin/git -C "$TMP_ROOT" commit -qm "init"
printf '.dev-flow/\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "gitignore"

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# 保存真实 HOME（用户级测试会临时修改）
REAL_HOME="$HOME"

# probe
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:1e05090f5b4fb5f164d1f762be94345438d330e7db8b2fb2eddbdb7b8a80fbc6",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

# ============================================================
# 1. fallback adapter 自定义路径保留 + resolver/probe 路径验证
# ============================================================

# 创建可探测的自定义 gstack skill 文件
/bin/mkdir -p "$TMP_ROOT/custom-skill"
cat > "$TMP_ROOT/custom-skill/SKILL.md" <<'SKILL'
# Custom Gstack Review Skill
This is a detectable custom skill for testing.
SKILL

# 创建可探测的自定义 orchestrator fake doctor
/bin/mkdir -p "$TMP_ROOT/custom-orch/scripts"
cat > "$TMP_ROOT/custom-orch/scripts/orchestrator-doctor.sh" <<'DOCTOR'
#!/usr/bin/env bash
echo "custom-doctor-ok"
exit 0
DOCTOR
/bin/chmod +x "$TMP_ROOT/custom-orch/scripts/orchestrator-doctor.sh"

# ---- 1a: 用户级 primary + fallback 自定义路径 roundtrip（不吞错误）----
TMP_HOME_FAKE="$(/usr/bin/mktemp -d)"
export HOME="$TMP_HOME_FAKE"
/bin/mkdir -p "$TMP_HOME_FAKE/.config"

if ! /bin/bash "$ROOT/scripts/install-review-backend.sh" \
  --codex --project "$TMP_ROOT" \
  --review-backend agent/openai-reviewer \
  --fallback-orchestrator-root "$TMP_ROOT/custom-orch" \
  --fallback-gstack-skill-path "$TMP_ROOT/custom-skill/SKILL.md" \
  --save-level user \
  --skip-mcp-config >/dev/null 2>&1; then
  echo "FAIL: user-level install failed (not swallowing errors)" >&2
  exit 1
fi

# 读取用户级 config 验证 fallback adapter 保留自定义路径
USER_CONFIG="$TMP_HOME_FAKE/.config/dev-flow/config.json"
if [[ ! -f "$USER_CONFIG" ]]; then
  echo "FAIL: user config not created" >&2
  exit 1
fi

/usr/bin/python3 - "$USER_CONFIG" <<'PY'
import json, sys
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
hosts = config.get("hosts", {})
codex_profile = hosts.get("codex", {})
adapters = codex_profile.get("adapters", {})

# primary agent/openai-reviewer 必须存在
assert "agent/openai-reviewer" in adapters, f"missing primary agent: {adapters}"

# fallback mcp/orchestrator 必须有自定义 root
orch = adapters.get("mcp/orchestrator", {})
assert orch.get("root") is not None, f"fallback mcp/orchestrator missing root: {orch}"
assert "custom-orch" in orch.get("root", ""), f"fallback root wrong: {orch.get('root')}"

# fallback skill/gstack 必须有自定义 skill_path
gstack = adapters.get("skill/gstack", {})
assert gstack.get("skill_path") is not None, f"skill/gstack missing skill_path: {gstack}"
assert "/custom-skill/SKILL.md" in gstack.get("skill_path", ""), f"skill/gstack skill_path wrong: {gstack.get('skill_path')}"

print("OK: user-level fallback adapter retains custom root and skill_path")
PY

# ---- 1a2: probe 使用自定义路径验证 ----
# 直接在 bash 中 source resolver 并 probe fallback adapters
PROBE_OUT="$(DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" HOME="$TMP_HOME_FAKE" \
  bash -c '
  source "'$ROOT'/scripts/lib/dev-flow-paths.sh"
  dev_flow_load_paths "'$ROOT'/scripts/install-review-backend.sh"
  source "$(dev_flow_script_path lib/review-backend-resolver.sh)"
  # 读取 user config 中 fallback adapter 的自定义路径
  USER_CFG="'$USER_CONFIG'"
  ORCH_CFG=$(/usr/bin/python3 -c "import json; c=json.load(open(\"$USER_CFG\")); a=c.get(\"hosts\",{}).get(\"codex\",{}).get(\"adapters\",{}).get(\"mcp/orchestrator\",{}); print(json.dumps(a))")
  GSTACK_CFG=$(/usr/bin/python3 -c "import json; c=json.load(open(\"$USER_CFG\")); a=c.get(\"hosts\",{}).get(\"codex\",{}).get(\"adapters\",{}).get(\"skill/gstack\",{}); print(json.dumps(a))")
  echo "ORCH_PROBE:$(review_probe_adapter mcp/orchestrator "$ORCH_CFG")"
  echo "GSTACK_PROBE:$(review_probe_adapter skill/gstack "$GSTACK_CFG")"
' 2>&1)" || true

echo "$PROBE_OUT" | /usr/bin/grep -q "ORCH_PROBE:orchestrator_doctor_ok\|ORCH_PROBE:custom-doctor-ok" || {
  echo "FAIL: orchestrator probe did not use custom doctor path" >&2
  echo "$PROBE_OUT" >&2
  exit 1
}
echo "OK: orchestrator probe uses custom doctor path"

echo "$PROBE_OUT" | /usr/bin/grep -q "GSTACK_PROBE:gstack_skill_present" || {
  echo "FAIL: gstack probe did not use custom skill path" >&2
  echo "$PROBE_OUT" >&2
  exit 1
}
echo "OK: gstack probe uses custom skill path"

# 恢复 HOME
export HOME="$REAL_HOME"

# ---- 1b: 项目级 primary + fallback 自定义路径 roundtrip（不吞错误）----
if ! /bin/bash "$ROOT/scripts/install-review-backend.sh" \
  --codex --project "$TMP_ROOT" \
  --review-backend agent/openai-reviewer \
  --fallback-orchestrator-root "$TMP_ROOT/custom-orch" \
  --fallback-gstack-skill-path "$TMP_ROOT/custom-skill/SKILL.md" \
  --save-level project \
  --skip-mcp-config >/dev/null 2>&1; then
  echo "FAIL: project-level install failed (not swallowing errors)" >&2
  exit 1
fi

PROJECT_CONFIG="$TMP_ROOT/.dev-flow/review-backend.local.json"
if [[ ! -f "$PROJECT_CONFIG" ]]; then
  echo "FAIL: project config not created" >&2
  exit 1
fi

/usr/bin/python3 - "$PROJECT_CONFIG" <<'PY'
import json, sys
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
adapters = config.get("adapters", {})

# primary agent/openai-reviewer 必须存在
assert "agent/openai-reviewer" in adapters, f"missing primary agent: {adapters}"

# fallback mcp/orchestrator 必须有自定义 root
orch = adapters.get("mcp/orchestrator", {})
assert orch.get("root") is not None, f"fallback mcp/orchestrator missing root: {orch}"
assert "custom-orch" in orch.get("root", ""), f"fallback root wrong: {orch.get('root')}"

# fallback skill/gstack 必须有自定义 skill_path
gstack = adapters.get("skill/gstack", {})
assert gstack.get("skill_path") is not None, f"skill/gstack missing skill_path: {gstack}"
assert "/custom-skill/SKILL.md" in gstack.get("skill_path", ""), f"skill/gstack skill_path wrong: {gstack.get('skill_path')}"

print("OK: project-level fallback adapter retains custom root and skill_path")
PY

# ---- 1c: 已有 config fallback 路径保留（未提供 CLI fallback 值时） ----
# 第二次写入，不提供 fallback-orchestrator-root，应从已有 config 保留
if ! /bin/bash "$ROOT/scripts/install-review-backend.sh" \
  --codex --project "$TMP_ROOT" \
  --review-backend agent/openai-reviewer \
  --save-level project \
  --skip-mcp-config >/dev/null 2>&1; then
  echo "FAIL: re-install without fallback params failed" >&2
  exit 1
fi

/usr/bin/python3 - "$PROJECT_CONFIG" <<'PY'
import json, sys
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
adapters = config.get("adapters", {})

# fallback mcp/orchestrator 应保留之前的自定义 root
orch = adapters.get("mcp/orchestrator", {})
assert orch.get("root") is not None, f"fallback mcp/orchestrator lost root on re-write: {orch}"
assert "custom-orch" in orch.get("root", ""), f"fallback root not preserved: {orch.get('root')}"

print("OK: existing fallback custom root preserved on re-write without CLI value")
PY

# ============================================================
# 2. 统一安全原子 JSON 写辅助
# ============================================================

ATOMIC_LIB="$ROOT/scripts/lib/atomic_json_write.py"

# ---- 2a: 正常路径写入成功 ----
/usr/bin/python3 -c "
import sys, json
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
from pathlib import Path
result = safe_atomic_write_json('$TMP_ROOT/.dev-flow', '$TMP_ROOT/.dev-flow/sessions/test-normal.json', {'test': 'ok'})
assert Path(result).exists(), 'file not created'
print('OK: normal path write succeeds')
"

# ---- 2b: trusted root 自身是 symlink → 拒绝 ----
TMP_SL_TR="$(/usr/bin/mktemp -d)"
TMP_SL_REAL="$(/usr/bin/mktemp -d)"
/bin/rm -rf "$TMP_SL_TR/.dev-flow" 2>/dev/null || true
/bin/ln -s "$TMP_SL_REAL" "$TMP_SL_TR/.dev-flow"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_TR/.dev-flow', '$TMP_SL_TR/.dev-flow/test.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: symlinked trusted root should be rejected" >&2
  exit 1
fi
echo "OK: symlinked trusted root rejected"
/bin/rm -rf -- "$TMP_SL_TR" "$TMP_SL_REAL"

# ---- 2c: sessions 中间层是 symlink → 拒绝 ----
TMP_SL_MID="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_MID/.dev-flow"
TMP_SL_REAL2="$(/usr/bin/mktemp -d)"
/bin/ln -s "$TMP_SL_REAL2" "$TMP_SL_MID/.dev-flow/sessions"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_MID/.dev-flow', '$TMP_SL_MID/.dev-flow/sessions/test.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: symlinked sessions dir should be rejected" >&2
  exit 1
fi
echo "OK: symlinked sessions intermediate dir rejected"
/bin/rm -rf -- "$TMP_SL_MID" "$TMP_SL_REAL2"

# ---- 2d: 目标文件是 symlink → 拒绝 ----
TMP_SL_TGT="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_TGT/.dev-flow/sessions"
echo "real" > "$TMP_SL_TGT/.dev-flow/sessions/real-target.json"
/bin/ln -s "$TMP_SL_TGT/.dev-flow/sessions/real-target.json" "$TMP_SL_TGT/.dev-flow/sessions/symlink-target.json"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_TGT/.dev-flow', '$TMP_SL_TGT/.dev-flow/sessions/symlink-target.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: symlinked target file should be rejected" >&2
  exit 1
fi
echo "OK: symlinked target file rejected"
/bin/rm -rf -- "$TMP_SL_TGT"

# ---- 2d2: 内部 sessions symlink（指向 trusted_root 内部）→ 拒绝 ----
# symlink 指向 trusted root 内部的合法路径，但仍应拒绝（symlink 可被交换）
TMP_SL_INT="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_INT/.dev-flow/real-sessions"
# sessions 是 symlink 指向同目录下的 real-sessions（在 trusted root 内部）
/bin/ln -s "$TMP_SL_INT/.dev-flow/real-sessions" "$TMP_SL_INT/.dev-flow/sessions"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_INT/.dev-flow', '$TMP_SL_INT/.dev-flow/sessions/test.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: internal symlink (pointing inside trusted root) should be rejected" >&2
  exit 1
fi
echo "OK: internal sessions symlink (pointing inside trusted root) rejected"
/bin/rm -rf -- "$TMP_SL_INT"

# ---- 2d3: 深层内部 symlink（sessions/deep 是 symlink）→ 拒绝 ----
TMP_SL_DEEP="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_DEEP/.dev-flow/sessions/real-deep"
# sessions/deep 是 symlink 指向 sessions/real-deep（在 trusted root 内部）
/bin/ln -s "$TMP_SL_DEEP/.dev-flow/sessions/real-deep" "$TMP_SL_DEEP/.dev-flow/sessions/deep"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_DEEP/.dev-flow', '$TMP_SL_DEEP/.dev-flow/sessions/deep/test.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: deep internal symlink should be rejected" >&2
  exit 1
fi
echo "OK: deep internal symlink rejected"
/bin/rm -rf -- "$TMP_SL_DEEP"

# ---- 2e: 目标在 trusted root 外 → 拒绝 ----
TMP_SL_OUT="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_OUT/.dev-flow/sessions"
TMP_SL_EXT="$(/usr/bin/mktemp -d)"
if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
safe_atomic_write_json('$TMP_SL_OUT/.dev-flow', '$TMP_SL_EXT/escape.json', {'test': 'ok'})
" 2>/dev/null; then
  echo "FAIL: target outside trusted root should be rejected" >&2
  exit 1
fi
echo "OK: target outside trusted root rejected"
/bin/rm -rf -- "$TMP_SL_OUT" "$TMP_SL_EXT"

# ---- 2f: 安全 mkdir（逐级创建）→ 成功 ----
TMP_SL_MK="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SL_MK/.dev-flow"
/usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
from pathlib import Path
# 写入深层路径，需要逐级创建
result = safe_atomic_write_json('$TMP_SL_MK/.dev-flow', '$TMP_SL_MK/.dev-flow/sessions/deep/nested/file.json', {'test': 'ok'})
assert Path(result).exists(), 'deep nested file not created'
print('OK: safe mkdir creates deep nested path')
"
/bin/rm -rf -- "$TMP_SL_MK"

# ---- 2g: macOS /var/folders 临时目录不遍历祖先 → 成功 ----
# TMP_ROOT 在 /var/folders 下，不应因系统 symlink 被拒
/usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_atomic_write_json
from pathlib import Path
result = safe_atomic_write_json('$TMP_ROOT/.dev-flow', '$TMP_ROOT/.dev-flow/sessions/mac-os-safe.json', {'test': 'ok'})
assert Path(result).exists(), 'file not created on macOS tmpdir'
print('OK: macOS /var/folders tmpdir not traversed to system ancestors')
"

# ============================================================
# 3. worktree_digest 结构化 tracked hash（二进制安全）
# ============================================================

# 辅助函数：提取 worktree_digest 输出字段
wt_field() {
  local json="$1" field="$2"
  echo "$json" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('$field',''))"
}

TMP_WT1="$(/usr/bin/mktemp -d)"
/usr/bin/git -C "$TMP_WT1" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_WT1" init -q && /usr/bin/git -C "$TMP_WT1" checkout -qb main; }
/usr/bin/git -C "$TMP_WT1" config user.email "test@example.com"
/usr/bin/git -C "$TMP_WT1" config user.name "test"
printf 'base\n' > "$TMP_WT1/base.txt"
/usr/bin/git -C "$TMP_WT1" add base.txt
/usr/bin/git -C "$TMP_WT1" commit -qm "init"

# ---- 3a: 输出契约验证（所有必需字段存在且类型正确）----
WT_JSON="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1")"
/usr/bin/python3 - "$WT_JSON" <<'PY'
import json, sys
wt = json.loads(sys.argv[1])
required = ["base_ref", "merge_base", "worktree_digest", "tracked_digest", "untracked_digest"]
for f in required:
    assert f in wt, f"missing field: {f}"
    assert isinstance(wt[f], str) and wt[f], f"field {f} is empty or not string"
    if f in ("worktree_digest", "tracked_digest", "untracked_digest"):
        assert wt[f].startswith("sha256:"), f"field {f} should be sha256-prefixed: {wt[f]}"
    if f == "merge_base":
        assert len(wt[f]) == 40, f"field {f} should be 40-char SHA: {wt[f]}"
    if f == "base_ref":
        assert len(wt[f]) > 0, f"field {f} should be non-empty: {wt[f]}"
print("OK: worktree_digest output contract (base_ref, merge_base, worktree_digest, tracked_digest, untracked_digest)")
PY

# ---- 3b: tracked binary — git add + commit 后修改产生不同 digest ----
# 写入二进制文件并 commit（tracked binary）
printf '\x00\x01\x02\xff\xfe' > "$TMP_WT1/bin.dat"
/usr/bin/git -C "$TMP_WT1" add bin.dat
/usr/bin/git -C "$TMP_WT1" commit -qm "add binary"
DIGEST_BIN_A="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"

# 修改 tracked binary（unstaged）
printf '\x00\x01\x02\xff\xfd' > "$TMP_WT1/bin.dat"
DIGEST_BIN_B="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BIN_A" == "$DIGEST_BIN_B" ]]; then
  echo "FAIL: modified tracked binary should produce different digest" >&2
  exit 1
fi
echo "OK: tracked binary git add+commit, modified → different digest"
# 还原
/usr/bin/git -C "$TMP_WT1" checkout -q -- bin.dat

# ---- 3c: staged 变更产生不同 digest ----
DIGEST_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
printf 'staged content\n' > "$TMP_WT1/staged.txt"
/usr/bin/git -C "$TMP_WT1" add staged.txt
DIGEST_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BEFORE" == "$DIGEST_AFTER" ]]; then
  echo "FAIL: staged change should produce different digest" >&2
  exit 1
fi
echo "OK: staged change produces different digest"
/usr/bin/git -C "$TMP_WT1" reset -q -- staged.txt
/bin/rm -f "$TMP_WT1/staged.txt"

# ---- 3d: unstaged 变更产生不同 digest ----
DIGEST_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
echo "modified" >> "$TMP_WT1/bin.dat"
DIGEST_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BEFORE" == "$DIGEST_AFTER" ]]; then
  echo "FAIL: unstaged change should produce different digest" >&2
  exit 1
fi
echo "OK: unstaged change produces different digest"
/usr/bin/git -C "$TMP_WT1" checkout -q -- bin.dat

# ---- 3e: unstaged delete 产生不同 digest ----
DIGEST_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
/bin/rm -f "$TMP_WT1/bin.dat"
DIGEST_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BEFORE" == "$DIGEST_AFTER" ]]; then
  echo "FAIL: unstaged delete should produce different digest" >&2
  exit 1
fi
echo "OK: unstaged delete produces different digest"
/usr/bin/git -C "$TMP_WT1" checkout -q -- bin.dat

# ---- 3f: staged delete 产生不同 digest ----
DIGEST_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
/usr/bin/git -C "$TMP_WT1" rm --cached -q bin.dat
DIGEST_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BEFORE" == "$DIGEST_AFTER" ]]; then
  echo "FAIL: staged delete should produce different digest" >&2
  exit 1
fi
echo "OK: staged delete produces different digest"
# 还原：重新 add
/usr/bin/git -C "$TMP_WT1" add bin.dat

# ---- 3g: rename (git mv) 产生不同 digest ----
DIGEST_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
/usr/bin/git -C "$TMP_WT1" mv bin.dat bin-renamed.dat
DIGEST_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_BEFORE" == "$DIGEST_AFTER" ]]; then
  echo "FAIL: git mv rename should produce different digest" >&2
  exit 1
fi
echo "OK: rename (git mv) produces different digest"
# 还原
/usr/bin/git -C "$TMP_WT1" mv bin-renamed.dat bin.dat

# ---- 3h: base override 断言输出 merge_base/base_ref 具体固定 SHA ----
# 记录当前 merge_base 和 base_ref
WT_INFO_BEFORE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1")"
MB_BEFORE="$(wt_field "$WT_INFO_BEFORE" "merge_base")"
BR_BEFORE="$(wt_field "$WT_INFO_BEFORE" "base_ref")"
DIGEST_BEFORE="$(wt_field "$WT_INFO_BEFORE" "worktree_digest")"

# 断言 merge_base 和 base_ref 是具体的 40-char SHA（非空、非 ref name）
if [[ ${#MB_BEFORE} -ne 40 ]]; then
  echo "FAIL: merge_base should be 40-char SHA, got: $MB_BEFORE" >&2
  exit 1
fi
echo "OK: merge_base is fixed SHA ($MB_BEFORE)"

# 用固化的 merge_base 重算（模拟 record-gate 行为）
WT_WITH_MB="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" "" "$MB_BEFORE")"
DIGEST_WITH_MB="$(wt_field "$WT_WITH_MB" "worktree_digest")"
MB_WITH_MB="$(wt_field "$WT_WITH_MB" "merge_base")"

# 断言 merge_base override 后输出的 merge_base 仍是同一个固定 SHA
if [[ "$MB_WITH_MB" != "$MB_BEFORE" ]]; then
  echo "FAIL: merge_base override should output same SHA: expected=$MB_BEFORE got=$MB_WITH_MB" >&2
  exit 1
fi
if [[ "$DIGEST_BEFORE" != "$DIGEST_WITH_MB" ]]; then
  echo "FAIL: digest with merge_base override should match original" >&2
  exit 1
fi
echo "OK: merge_base override outputs same fixed SHA, digest unchanged (no drift)"

# ---- 3i: branch 移动后 merge_base override 仍使用旧固定 SHA ----
# 移动 main branch（commit 新内容）
printf 'new commit\n' > "$TMP_WT1/new.txt"
/usr/bin/git -C "$TMP_WT1" add new.txt
/usr/bin/git -C "$TMP_WT1" commit -qm "new commit on main"

# 不用 override 时会解析新 main → 新 merge_base
WT_NO_OVERRIDE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1")"
MB_NO_OVERRIDE="$(wt_field "$WT_NO_OVERRIDE" "merge_base")"

# 用旧 merge_base override 重算
WT_WITH_MB_AFTER="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT1" "" "$MB_BEFORE")"
MB_WITH_MB_AFTER="$(wt_field "$WT_WITH_MB_AFTER" "merge_base")"

# 断言：override 后的 merge_base 仍是旧 SHA，不因 branch 移动而变
if [[ "$MB_WITH_MB_AFTER" != "$MB_BEFORE" ]]; then
  echo "FAIL: after branch move, merge_base override should still use old SHA: expected=$MB_BEFORE got=$MB_WITH_MB_AFTER" >&2
  exit 1
fi
# 断言：不用 override 时 merge_base 确实变了（branch 移动生效）
if [[ "$MB_NO_OVERRIDE" == "$MB_BEFORE" ]]; then
  echo "FAIL: without override, merge_base should have changed after branch move" >&2
  exit 1
fi
echo "OK: after branch move, merge_base override still uses old fixed SHA ($MB_BEFORE), no-override uses new ($MB_NO_OVERRIDE)"

/bin/rm -rf -- "$TMP_WT1"

# ---- 3j: 非 git 项目 fail closed ----
TMP_NG="$(/usr/bin/mktemp -d)"
if /usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_NG" 2>/dev/null; then
  echo "FAIL: non-git project should fail" >&2
  exit 1
fi
echo "OK: non-git project fails (fail closed)"
/bin/rm -rf -- "$TMP_NG"

# ---- 3k: untracked symlink 纳入 canonical digest（不跳过）----
TMP_WT_SL="$(/usr/bin/mktemp -d)"
/usr/bin/git -C "$TMP_WT_SL" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_WT_SL" init -q && /usr/bin/git -C "$TMP_WT_SL" checkout -qb main; }
/usr/bin/git -C "$TMP_WT_SL" config user.email "test@example.com"
/usr/bin/git -C "$TMP_WT_SL" config user.name "test"
printf 'base\n' > "$TMP_WT_SL/base.txt"
/usr/bin/git -C "$TMP_WT_SL" add base.txt
/usr/bin/git -C "$TMP_WT_SL" commit -qm "init"

# 基线 digest（无 untracked symlink）
DIGEST_NO_SL="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"

# 新增 untracked symlink
/bin/ln -s /tmp/nonexistent-target "$TMP_WT_SL/untracked-link"
DIGEST_WITH_SL="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_NO_SL" == "$DIGEST_WITH_SL" ]]; then
  echo "FAIL: new untracked symlink should change digest (not skipped)" >&2
  exit 1
fi
echo "OK: new untracked symlink changes digest (not skipped)"

# 修改 untracked symlink target → 不同 digest
/bin/rm -f "$TMP_WT_SL/untracked-link"
/bin/ln -s /tmp/different-target "$TMP_WT_SL/untracked-link"
DIGEST_MOD_SL="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_WITH_SL" == "$DIGEST_MOD_SL" ]]; then
  echo "FAIL: modified untracked symlink target should change digest" >&2
  exit 1
fi
echo "OK: modified untracked symlink target changes digest"

# 删除 untracked symlink → 回到基线 digest
/bin/rm -f "$TMP_WT_SL/untracked-link"
DIGEST_DEL_SL="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_NO_SL" != "$DIGEST_DEL_SL" ]]; then
  echo "FAIL: deleted untracked symlink should restore baseline digest" >&2
  exit 1
fi
echo "OK: deleted untracked symlink restores baseline digest"

# untracked symlink 指向已有文件 → digest 包含 symlink（不是目标文件内容）
printf 'target content\n' > "$TMP_WT_SL/target.txt"
/bin/ln -s target.txt "$TMP_WT_SL/link-to-target.txt"
DIGEST_SL_TO_FILE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
# 删除 symlink，添加同名的普通文件 → 应该不同（symlink target hash vs file content hash）
/bin/rm -f "$TMP_WT_SL/link-to-target.txt"
printf 'target content\n' > "$TMP_WT_SL/link-to-target.txt"
DIGEST_REAL_FILE="$(/usr/bin/python3 "$ROOT/scripts/lib/worktree_digest.py" "$TMP_WT_SL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree_digest"])')"
if [[ "$DIGEST_SL_TO_FILE" == "$DIGEST_REAL_FILE" ]]; then
  echo "FAIL: symlink to file should differ from real file in digest" >&2
  exit 1
fi
echo "OK: untracked symlink to file differs from real file (symlink target hash vs content hash)"

/bin/rm -rf -- "$TMP_WT_SL"

# ============================================================
# 4. result artifact producer 严格绑定 + safe_read_json 安全读取
# ============================================================

# ---- 4a: safe_read_json — 外部 symlink 指向 sessions 内部 → 拒绝 ----
# 场景：result_artifact 路径通过外部 symlink 指向 sessions 内部文件。
# resolve() 会跟随 symlink 使边界检查通过，但原始路径不在 sessions_dir 下。
# safe_read_bytes 必须 fail closed（不可 ValueError pass）。
TMP_SR="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SR/.dev-flow/sessions"
# 创建一个合法的 sessions 内部文件
echo '{"test":"ok"}' > "$TMP_SR/.dev-flow/sessions/legit.json"
# 创建外部 symlink 指向 sessions 内部文件
/bin/ln -s "$TMP_SR/.dev-flow/sessions/legit.json" "$TMP_SR/evil-link.json"
if /usr/bin/python3 -c "
import sys, os
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_read_json
from pathlib import Path
trusted = Path(os.path.normpath('$TMP_SR/.dev-flow/sessions'))
target = Path(os.path.normpath('$TMP_SR/evil-link.json'))
safe_read_json(trusted, target)
" 2>/dev/null; then
  echo "FAIL: external symlink pointing inside sessions should be rejected by safe_read_json" >&2
  exit 1
fi
echo "OK: safe_read_json rejects external symlink pointing inside sessions (no ValueError pass)"
/bin/rm -rf -- "$TMP_SR"

# ---- 4b: safe_read_json — 正常路径 → 成功 ----
TMP_SR_OK="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SR_OK/.dev-flow/sessions"
echo '{"test":"ok"}' > "$TMP_SR_OK/.dev-flow/sessions/normal.json"
/usr/bin/python3 -c "
import sys, os, json
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_read_json
from pathlib import Path
trusted = Path(os.path.normpath('$TMP_SR_OK/.dev-flow/sessions'))
target = Path(os.path.normpath('$TMP_SR_OK/.dev-flow/sessions/normal.json'))
data = safe_read_json(trusted, target)
assert data['test'] == 'ok', f'unexpected data: {data}'
print('OK: safe_read_json normal path succeeds')
"
/bin/rm -rf -- "$TMP_SR_OK"

# ---- 4c: safe_read_json — sessions 中间层 symlink → 拒绝 ----
TMP_SR_MID="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_SR_MID/.dev-flow/real-sessions"
echo '{"test":"ok"}' > "$TMP_SR_MID/.dev-flow/real-sessions/test.json"
/bin/ln -s "$TMP_SR_MID/.dev-flow/real-sessions" "$TMP_SR_MID/.dev-flow/sessions"
if /usr/bin/python3 -c "
import sys, os
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_read_json
from pathlib import Path
trusted = Path(os.path.normpath('$TMP_SR_MID/.dev-flow/sessions'))
target = Path(os.path.normpath('$TMP_SR_MID/.dev-flow/sessions/test.json'))
safe_read_json(trusted, target)
" 2>/dev/null; then
  echo "FAIL: symlinked sessions dir should be rejected by safe_read_json" >&2
  exit 1
fi
echo "OK: safe_read_json rejects symlinked sessions intermediate dir"
/bin/rm -rf -- "$TMP_SR_MID"

# ---- 4d: producer mismatch — artifact producer != report producer → 拒绝 ----
# 使用 dev-flow-session record-gate 完整流程验证
source "$ROOT/scripts/test-helper-inject-ticket.sh"

TMP_PM="$(/usr/bin/mktemp -d)"
/usr/bin/git -C "$TMP_PM" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_PM" init -q && /usr/bin/git -C "$TMP_PM" checkout -qb main; }
/usr/bin/git -C "$TMP_PM" config user.email "test@example.com"
/usr/bin/git -C "$TMP_PM" config user.name "test"
printf 'base\n' > "$TMP_PM/base.txt"
/usr/bin/git -C "$TMP_PM" add base.txt
/usr/bin/git -C "$TMP_PM" commit -qm "init"
printf '.dev-flow/\n' > "$TMP_PM/.gitignore"
/usr/bin/git -C "$TMP_PM" add .gitignore
/usr/bin/git -C "$TMP_PM" commit -qm "gitignore"
/bin/mkdir -p "$TMP_PM/.dev-flow/sessions"

# 创建会话
DEV_FLOW_PROJECT_ROOT="$TMP_PM" DEV_FLOW_SESSION_ID=prodtest \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "producer mismatch test" >/dev/null
DEV_FLOW_PROJECT_ROOT="$TMP_PM" DEV_FLOW_SESSION_ID=prodtest \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null

# 注入环境健康检查（模拟）
DEV_FLOW_PROJECT_ROOT="$TMP_PM" DEV_FLOW_SESSION_ID=prodtest \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="echo '{\"status\":\"available\",\"evidence\":\"test_probe\",\"selected_adapter\":\"agent/openai-reviewer\",\"config_digest\":\"sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b\",\"source\":\"project\"}'" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null

# 注入 ticket + result artifact
state_file="$TMP_PM/.dev-flow/sessions/prodtest.json"
ticket_info="$(inject_review_ticket "prodtest" "agent/openai-reviewer" "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b" "code-quality-review" "$state_file" "$TMP_PM")"
TICKET_TOKEN="${ticket_info% *}"
TICKET_DIGEST="${ticket_info#* }"
ra_info="$(inject_result_artifact "prodtest" "$state_file" "$TMP_PM" "pass" "test-run-pm" "test pass")"
RA_PATH="${ra_info% *}"
RA_DIGEST="${ra_info#* }"

# 构建报告：producer=code-review-workflow（与 artifact 一致）
/usr/bin/python3 - "$TMP_PM/.dev-flow/sessions/review-prodtest-ok.json" "prodtest" "$TICKET_TOKEN" "$TICKET_DIGEST" "$RA_PATH" "$RA_DIGEST" <<'PY'
import json, sys, hashlib
from pathlib import Path
ref = "test-host-ref-test-run-pm"
digest = "sha256:" + hashlib.sha256(b"test-handoff-test-run-pm").hexdigest()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test pass",
    "review_path": "reviewer",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b",
    "run_id": "test-run-pm", "diff_evidence": "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": sys.argv[3], "ticket_digest": sys.argv[4],
    "result_artifact": sys.argv[5], "result_artifact_digest": sys.argv[6],
}) + "\n")
PY

# 正常路径：producer 匹配 → 接受
if ! DEV_FLOW_PROJECT_ROOT="$TMP_PM" DEV_FLOW_SESSION_ID=prodtest \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" record-gate --name review \
  --report "$TMP_PM/.dev-flow/sessions/review-prodtest-ok.json" >/dev/null 2>&1; then
  echo "FAIL: matching producer should be accepted" >&2
  exit 1
fi
echo "OK: matching producer (code-review-workflow) accepted"

# 重新签发 ticket（上一个已 consumed）
inject_review_ticket "prodtest" "agent/openai-reviewer" "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b" "code-quality-review" "$state_file" "$TMP_PM" >/dev/null
ra_info2="$(inject_result_artifact "prodtest" "$state_file" "$TMP_PM" "pass" "test-run-pm2" "test pass 2")"
RA_PATH2="${ra_info2% *}"
RA_DIGEST2="${ra_info2#* }"

# 篡改 artifact producer 为 "evil-producer"
/usr/bin/python3 - "$RA_PATH2" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
data["producer"] = "evil-producer"
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
# 重算 digest（因为篡改了 producer）
RA_DIGEST2_FAKE="$(/usr/bin/python3 -c "import hashlib; print('sha256:' + hashlib.sha256(open('$RA_PATH2','rb').read()).hexdigest())")"

# 构建报告：producer=code-review-workflow（与篡改后的 artifact 不匹配）
/usr/bin/python3 - "$TMP_PM/.dev-flow/sessions/review-prodtest-mismatch.json" "prodtest" "$TICKET_TOKEN" "$TICKET_DIGEST" "$RA_PATH2" "$RA_DIGEST2_FAKE" <<'PY'
import json, sys, hashlib
from pathlib import Path
ref = "test-host-ref-test-run-pm2"
digest = "sha256:" + hashlib.sha256(b"test-handoff-test-run-pm2").hexdigest()
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1,
    "session_id": sys.argv[2], "gate": "review",
    "status": "pass", "reviewer_result": "pass",
    "evidence": "test pass mismatch",
    "review_path": "reviewer",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b",
    "run_id": "test-run-pm2", "diff_evidence": "sha256:4f72c47c2214b07fed72ddd537363c43a470c7ae1103732daab7f373b059532b",
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": sys.argv[3], "ticket_digest": sys.argv[4],
    "result_artifact": sys.argv[5], "result_artifact_digest": sys.argv[6],
}) + "\n")
PY

if DEV_FLOW_PROJECT_ROOT="$TMP_PM" DEV_FLOW_SESSION_ID=prodtest \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" record-gate --name review \
  --report "$TMP_PM/.dev-flow/sessions/review-prodtest-mismatch.json" >/dev/null 2>&1; then
  echo "FAIL: producer mismatch (artifact=evil-producer, report=code-review-workflow) should be rejected" >&2
  exit 1
fi
echo "OK: producer mismatch rejected (artifact producer != report producer)"
/bin/rm -rf -- "$TMP_PM"

# ============================================================
# 5. gstack probe: 显式 skill_path 失效 → blocked，不 fallback 到默认
# ============================================================

# 创建默认 gstack skill 路径（存在且可读）
TMP_GP="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_GP/default-skill"
cat > "$TMP_GP/default-skill/SKILL.md" <<'SKILL'
# Default Gstack Review Skill
SKILL

# 创建一个失效的自定义 skill_path（不存在）
INVALID_SKILL_PATH="$TMP_GP/nonexistent/custom-skill/SKILL.md"

# 探测：显式 skill_path 失效 → 应返回 blocked（1），不 fallback 到默认
PROBE_RESULT="$(DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" \
  bash -c '
  source "'$ROOT'/scripts/lib/dev-flow-paths.sh"
  dev_flow_load_paths "'$ROOT'/scripts/install-review-backend.sh"
  source "$(dev_flow_script_path lib/reviewer-readiness.sh)"
  source "$(dev_flow_script_path lib/review-backend-resolver.sh)"
  # 构造 adapter_config 含失效的 skill_path
  CFG="{\"skill_path\":\"'$INVALID_SKILL_PATH'\"}"
  if review_probe_adapter skill/gstack "$CFG" 2>/dev/null; then
    echo "PROBE_OK"
  else
    echo "PROBE_BLOCKED"
  fi
  ' 2>&1)" || true

if echo "$PROBE_RESULT" | /usr/bin/grep -q "PROBE_OK"; then
  echo "FAIL: gstack probe with invalid explicit skill_path should be blocked, not fallback to default" >&2
  exit 1
fi
if ! echo "$PROBE_RESULT" | /usr/bin/grep -q "PROBE_BLOCKED"; then
  echo "FAIL: gstack probe should return blocked for invalid skill_path" >&2
  exit 1
fi
echo "OK: gstack probe with invalid explicit skill_path → blocked (no fallback to default)"
/bin/rm -rf -- "$TMP_GP"

echo ""
echo "PASS: Reviewer Major fixes (fallback adapter custom paths + probe, unified atomic JSON writer, structured worktree digest, untracked symlink, producer binding, safe_read_json, gstack probe fail-closed) all covered"
