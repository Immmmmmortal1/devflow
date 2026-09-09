#!/usr/bin/env bash
# safe_write_external 祖先 symlink 测试
# 验证：路径链中间存在 symlink（非直接 parent）时必须拒绝
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

# ============================================================
# 1. 祖先目录是 symlink → 必须拒绝
# ============================================================
# 结构: $TMP/trusted_root/real_dir/ (真实目录)
#        $TMP/trusted_root/link_dir -> real_dir (symlink)
#        target = $TMP/trusted_root/link_dir/subdir/file.json
#        期望: 拒绝（link_dir 是 symlink）

/bin/mkdir -p "$TMP/trusted_root/real_dir/subdir"
/bin/ln -s real_dir "$TMP/trusted_root/link_dir"

target="$TMP/trusted_root/link_dir/subdir/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject ancestor symlink (link_dir)" >&2
  exit 1
fi
echo "OK: safe_write_external rejects ancestor symlink in path chain (link_dir)"

# ============================================================
# 2. 更深层祖先是 symlink → 必须拒绝
# ============================================================
# 结构: $TMP/trusted_root/a/b_real/ (真实目录)
#        $TMP/trusted_root/a/b_link -> b_real (symlink)
#        target = $TMP/trusted_root/a/b_link/c/d/file.json
#        期望: 拒绝（b_link 是 symlink，即使 target 在更深处）

/bin/mkdir -p "$TMP/trusted_root/a/b_real/c/d"
/bin/ln -s b_real "$TMP/trusted_root/a/b_link"

target2="$TMP/trusted_root/a/b_link/c/d/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target2', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject deep ancestor symlink (b_link)" >&2
  exit 1
fi
echo "OK: safe_write_external rejects deep ancestor symlink in path chain (b_link)"

# ============================================================
# 3. 直接 parent 是 symlink → 必须拒绝
# ============================================================
# 结构: $TMP/trusted_root/real_parent/ (真实目录)
#        $TMP/trusted_root/link_parent -> real_parent (symlink)
#        target = $TMP/trusted_root/link_parent/file.json
#        期望: 拒绝（link_parent 是 symlink）

/bin/mkdir -p "$TMP/trusted_root/real_parent3"
/bin/ln -s real_parent3 "$TMP/trusted_root/link_parent3"

target3="$TMP/trusted_root/link_parent3/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target3', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject direct parent symlink" >&2
  exit 1
fi
echo "OK: safe_write_external rejects direct parent symlink"

# ============================================================
# 4. target 自身是 symlink → 必须拒绝
# ============================================================
# 结构: $TMP/trusted_root/real_file (真实文件)
#        $TMP/trusted_root/link_file -> real_file (symlink)
#        target = $TMP/trusted_root/link_file
#        期望: 拒绝（target 是 symlink）

/bin/mkdir -p "$TMP/trusted_root/dir4"
printf 'old' > "$TMP/trusted_root/dir4/real_file4"
/bin/ln -s real_file4 "$TMP/trusted_root/dir4/link_file4"

target4="$TMP/trusted_root/dir4/link_file4"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target4', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject target itself being a symlink" >&2
  exit 1
fi
echo "OK: safe_write_external rejects target itself being a symlink"

# ============================================================
# 5. trusted_external_root 自身是 symlink → 必须拒绝
# ============================================================
# 结构: $TMP/real_root/ (真实目录)
#        $TMP/link_root -> real_root (symlink)
#        target = $TMP/link_root/file.json
#        期望: 拒绝（trusted_external_root 是 symlink）

/bin/mkdir -p "$TMP/real_root5"
/bin/ln -s real_root5 "$TMP/link_root5"

target5="$TMP/link_root5/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target5', '{}', trusted_external_root='$TMP/link_root5')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject symlinked trusted_external_root" >&2
  exit 1
fi
echo "OK: safe_write_external rejects symlinked trusted_external_root"

# ============================================================
# 6. 正常路径（无 symlink）→ 成功写入
# ============================================================
# 结构: $TMP/trusted_root/dir6/subdir6/file.json (全真实目录)
#        期望: 成功

/bin/mkdir -p "$TMP/trusted_root/dir6/subdir6"
target6="$TMP/trusted_root/dir6/subdir6/file.json"

/usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target6', '{\"ok\":true}', trusted_external_root='$TMP/trusted_root')
"

[[ -f "$target6" ]] || { echo "FAIL: file not created at $target6" >&2; exit 1; }
content="$(/bin/cat "$target6")"
[[ "$content" == '{"ok":true}' ]] || { echo "FAIL: content mismatch: $content" >&2; exit 1; }
echo "OK: safe_write_external succeeds with normal path (no symlinks)"

# ============================================================
# 7. symlink 指向 trusted_external_root 内部 → 仍拒绝
# ============================================================
# 结构: $TMP/trusted_root/real_dir7/ (真实目录)
#        $TMP/trusted_root/link_dir7 -> real_dir7 (symlink, 指向内部)
#        target = $TMP/trusted_root/link_dir7/file.json
#        期望: 拒绝（即使 symlink 指向 trusted root 内部，仍拒绝）

/bin/mkdir -p "$TMP/trusted_root/real_dir7"
/bin/ln -s real_dir7 "$TMP/trusted_root/link_dir7"

target7="$TMP/trusted_root/link_dir7/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target7', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject symlink even if it points inside trusted root" >&2
  exit 1
fi
echo "OK: safe_write_external rejects symlink even when pointing inside trusted root"

# ============================================================
# 8. 新目录自动创建（无 symlink）→ 成功
# ============================================================
# 结构: $TMP/trusted_root/new_dir8/new_subdir8/file.json (目录不存在)
#        期望: safe_write_external 自动创建目录并写入

target8="$TMP/trusted_root/new_dir8/new_subdir8/file.json"

/usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target8', '{\"created\":true}', trusted_external_root='$TMP/trusted_root')
"

[[ -f "$target8" ]] || { echo "FAIL: file not created at $target8" >&2; exit 1; }
echo "OK: safe_write_external auto-creates directories (no symlinks)"

# ============================================================
# 9. 路径逃逸到 trusted_external_root 之外 → 拒绝
# ============================================================
# 结构: target = $TMP/outside_root/file.json (不在 trusted_root 下)
#        期望: 拒绝

/bin/mkdir -p "$TMP/outside_root9"
target9="$TMP/outside_root9/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target9', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject path outside trusted_external_root" >&2
  exit 1
fi
echo "OK: safe_write_external rejects path outside trusted_external_root"

# ============================================================
# 10. resolve 后逃逸（symlink 链使 resolve 后路径在 root 之外）→ 拒绝
# ============================================================
# 结构: $TMP/trusted_root/escape_link -> $TMP/outside_root10 (symlink 指向外部)
#        target = $TMP/trusted_root/escape_link/file.json
#        期望: 拒绝（symlink 在路径链中被 lstat 拦截）
#        注：此测试验证 lstat 检查在 resolve 边界检查之前拦截

/bin/mkdir -p "$TMP/outside_root10"
/bin/ln -s "$TMP/outside_root10" "$TMP/trusted_root/escape_link10"

target10="$TMP/trusted_root/escape_link10/file.json"

if /usr/bin/python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
from atomic_json_write import safe_write_external
safe_write_external('$target10', '{}', trusted_external_root='$TMP/trusted_root')
" 2>/dev/null; then
  echo "FAIL: safe_write_external should reject symlink escaping trusted root" >&2
  exit 1
fi
echo "OK: safe_write_external rejects symlink that would escape trusted root"

echo ""
echo "PASS: safe_write_external ancestor symlink rejection (10 tests)"
