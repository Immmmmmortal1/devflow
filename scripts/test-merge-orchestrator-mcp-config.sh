#!/usr/bin/env bash
# merge-orchestrator-mcp-config.py symlink 安全测试
# 验证：Cursor JSON / Codex TOML 写入使用 safe_write_external，
# 拒绝 target/parent-chain/trusted_root symlink，原子写。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

# safe_write_external 默认 trusted_external_root=HOME；测试用 tmpdir 需显式指定
export DEV_FLOW_TRUSTED_EXTERNAL_ROOT="$TMP"

WRAPPER="$TMP/wrapper.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WRAPPER"
/bin/chmod +x "$WRAPPER"
PYTHONPATH="$ROOT/scripts/lib"

# ============================================================
# 1. 正常 Cursor JSON 写入 → 成功
# ============================================================
echo "=== test 1: normal cursor JSON write ==="
cursor_config="$TMP/cursor_config.json"
/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$cursor_config" >/dev/null

[[ -f "$cursor_config" ]] || { echo "FAIL: cursor config not created" >&2; exit 1; }
/usr/bin/grep -q 'orchestrator_mcp' "$cursor_config" || {
  echo "FAIL: cursor config missing orchestrator_mcp" >&2; exit 1
}
echo "OK: normal cursor JSON write succeeds"

# ============================================================
# 2. 正常 Codex TOML 写入 → 成功
# ============================================================
echo "=== test 2: normal codex TOML write ==="
codex_config="$TMP/codex_config.toml"
/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$codex_config" >/dev/null

[[ -f "$codex_config" ]] || { echo "FAIL: codex config not created" >&2; exit 1; }
/usr/bin/grep -q 'orchestrator_mcp' "$codex_config" || {
  echo "FAIL: codex config missing orchestrator_mcp" >&2; exit 1
}
echo "OK: normal codex TOML write succeeds"

# ============================================================
# 3. Cursor config target 是 symlink → fail closed
# ============================================================
echo "=== test 3: cursor config target is symlink → fail closed ==="
evil_file="$(/usr/bin/mktemp)"
printf 'evil\n' > "$evil_file"
symlink_cursor="$TMP/cursor_symlink.json"
ln -s "$evil_file" "$symlink_cursor"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$symlink_cursor" 2>/dev/null; then
  echo "FAIL: symlinked cursor target should fail closed" >&2
  exit 1
fi

# 验证 evil 文件未被写入
content="$(/bin/cat "$evil_file")"
[[ "$content" == "evil" ]] || {
  echo "FAIL: evil symlink target was overwritten" >&2; exit 1
}
echo "OK: cursor symlink target → fail closed (evil not written)"

/bin/rm -f -- "$evil_file" "$symlink_cursor"

# ============================================================
# 4. Codex config target 是 symlink → fail closed
# ============================================================
echo "=== test 4: codex config target is symlink → fail closed ==="
evil_file2="$(/usr/bin/mktemp)"
printf 'evil2\n' > "$evil_file2"
symlink_codex="$TMP/codex_symlink.toml"
ln -s "$evil_file2" "$symlink_codex"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$symlink_codex" 2>/dev/null; then
  echo "FAIL: symlinked codex target should fail closed" >&2
  exit 1
fi

content2="$(/bin/cat "$evil_file2")"
[[ "$content2" == "evil2" ]] || {
  echo "FAIL: evil codex symlink target was overwritten" >&2; exit 1
}
echo "OK: codex symlink target → fail closed (evil not written)"

/bin/rm -f -- "$evil_file2" "$symlink_codex"

# ============================================================
# 5. Cursor config 父目录是 symlink → fail closed
# ============================================================
echo "=== test 5: cursor config parent dir is symlink → fail closed ==="
/bin/mkdir -p "$TMP/real-cursor-dir"
ln -s real-cursor-dir "$TMP/sym-cursor-dir"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$TMP/sym-cursor-dir/config.json" 2>/dev/null; then
  echo "FAIL: symlinked parent dir should fail closed" >&2
  exit 1
fi
echo "OK: cursor symlinked parent dir → fail closed"

/bin/rm -f "$TMP/sym-cursor-dir"

# ============================================================
# 6. Codex config 父目录是 symlink → fail closed
# ============================================================
echo "=== test 6: codex config parent dir is symlink → fail closed ==="
/bin/mkdir -p "$TMP/real-codex-dir"
ln -s real-codex-dir "$TMP/sym-codex-dir"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$TMP/sym-codex-dir/config.toml" 2>/dev/null; then
  echo "FAIL: symlinked parent dir should fail closed" >&2
  exit 1
fi
echo "OK: codex symlinked parent dir → fail closed"

/bin/rm -f "$TMP/sym-codex-dir"

# ============================================================
# 7. Cursor config 路径越界（trusted_external_root 之外）→ fail closed
# ============================================================
echo "=== test 7: cursor config outside trusted root → fail closed ==="
outside_file="$(/usr/bin/mktemp)"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$outside_file" 2>/dev/null; then
  echo "FAIL: config outside trusted root should fail closed" >&2
  exit 1
fi
echo "OK: cursor config outside trusted root → fail closed"

/bin/rm -f -- "$outside_file"

# ============================================================
# 8. Codex config 路径越界 → fail closed
# ============================================================
echo "=== test 8: codex config outside trusted root → fail closed ==="
outside_file2="$(/usr/bin/mktemp)"

if /usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$outside_file2" 2>/dev/null; then
  echo "FAIL: codex config outside trusted root should fail closed" >&2
  exit 1
fi
echo "OK: codex config outside trusted root → fail closed"

/bin/rm -f -- "$outside_file2"

# ============================================================
# 9. Cursor 幂等写入（相同配置不重复写）
# ============================================================
echo "=== test 9: cursor idempotent write ==="
cursor_config2="$TMP/cursor_idempotent.json"
/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$cursor_config2" >/dev/null

# 第二次写入应返回 changed=no
output2="$(/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$cursor_config2" 2>&1)"
echo "$output2" | /usr/bin/grep -q 'changed=no' || {
  echo "FAIL: idempotent write should return changed=no" >&2; exit 1
}
echo "OK: cursor idempotent write returns changed=no"

# ============================================================
# 10. Codex 幂等写入
# ============================================================
echo "=== test 10: codex idempotent write ==="
codex_config2="$TMP/codex_idempotent.toml"
/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$codex_config2" >/dev/null

output3="$(/usr/bin/python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform codex \
  --wrapper-path "$WRAPPER" \
  --pythonpath "$PYTHONPATH" \
  --config-path "$codex_config2" 2>&1)"
echo "$output3" | /usr/bin/grep -q 'changed=no' || {
  echo "FAIL: idempotent write should return changed=no" >&2; exit 1
}
echo "OK: codex idempotent write returns changed=no"

# ============================================================
# 11. 不写入 API key 到项目配置
# ============================================================
echo "=== test 11: no API key in config ==="
# orchestrator_mcp 只写 command/args/env(PYTHONPATH+TRANSPORT)，不写 API key
if /usr/bin/grep -qi 'api.key\|apikey\|api_key\|token\|secret' "$cursor_config2" 2>/dev/null; then
  echo "FAIL: cursor config contains API key-like string" >&2; exit 1
fi
if /usr/bin/grep -qi 'api.key\|apikey\|api_key\|token\|secret' "$codex_config2" 2>/dev/null; then
  echo "FAIL: codex config contains API key-like string" >&2; exit 1
fi
echo "OK: no API key in cursor/codex config"

echo ""
echo "PASS: merge-orchestrator-mcp-config.py symlink security (target/parent/escape + idempotent + no-apikey)"
