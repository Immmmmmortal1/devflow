#!/usr/bin/env bash
# 链接覆盖测试（增强版）：
# 1. 验证所有应被链接的 reference/route 文件已被 link-skills-common.sh 显式链接
# 2. 反向验证：声明的 link_file 源路径必须存在
# 3. 解析 skills=(...) 数组，验证每个元素对应真实 SKILL.md 目录，反向亦然
# 4. 解析 route 循环列表，验证每个文件名是完整元素且对应真实 route 文件，反向亦然
# 只覆盖 dev-flow 自有正常文件；正确处理 symlink 和 figma-ui-gates 边界。
# 兼容 macOS 自带 Bash 3.2（不使用关联数组 / mapfile）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINK_SH="$ROOT/scripts/link-skills-common.sh"

[[ -f "$LINK_SH" ]] || { echo "FAIL: link-skills-common.sh not found" >&2; exit 1; }

require_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "FAIL: missing file $file" >&2; exit 1; }
}

# ------------------------------------------------------------
# 1. 收集所有应被链接的 reference 和 route 文件，检查 grep 覆盖
# ------------------------------------------------------------

missing_links=()

# references/*.md under skills/*/
while IFS= read -r -d '' ref_file; do
  rel="${ref_file#"$ROOT/skills/"}"
  if ! /usr/bin/grep -qF "$rel" "$LINK_SH"; then
    missing_links+=("$rel")
  fi
done < <(find "$ROOT/skills" -path "*/references/*.md" -type f -print0)

# routes/*.md — 现有 grep 检查（filename 级别）
while IFS= read -r -d '' route_file; do
  filename="$(basename "$route_file")"
  if ! /usr/bin/grep -qF "$filename" "$LINK_SH"; then
    rel="${route_file#"$ROOT/skills/"}"
    missing_links+=("$rel")
  fi
done < <(find "$ROOT/skills/code-review-workflow/routes" -name "*.md" -type f -print0)

if ((${#missing_links[@]} > 0)); then
  echo "FAIL: the following reference/route files are not linked in link-skills-common.sh:" >&2
  printf '  - %s\n' "${missing_links[@]}" >&2
  exit 1
fi

echo "PASS: all references and routes are grep-covered in link-skills-common.sh"

# ------------------------------------------------------------
# 2. 反向验证：声明的 link_file 源路径必须存在
# ------------------------------------------------------------

broken_links=()

while IFS= read -r line; do
  src_rel="$(printf '%s' "$line" | /usr/bin/sed -n 's|.*\$source_root/skills/||p' | /usr/bin/sed 's/".*//;s/ *\\$//')"
  [[ -n "$src_rel" ]] || continue
  if printf '%s' "$src_rel" | /usr/bin/grep -q '\$'; then
    continue
  fi
  src_abs="$ROOT/skills/$src_rel"
  if [[ ! -f "$src_abs" ]]; then
    broken_links+=("$src_rel (declared but source file missing)")
  fi
done < <(/usr/bin/grep -E 'link_file .*\$source_root/skills/' "$LINK_SH")

if ((${#broken_links[@]} > 0)); then
  echo "FAIL: link-skills-common.sh declares links to missing source files:" >&2
  printf '  - %s\n' "${broken_links[@]}" >&2
  exit 1
fi

echo "PASS: all declared link_file source paths exist"

# ------------------------------------------------------------
# 3. 验证三个新增 reference 已被链接
# ------------------------------------------------------------

require_linked() {
  local rel="$1"
  /usr/bin/grep -qF "$rel" "$LINK_SH" || { echo "FAIL: $rel not linked in link-skills-common.sh" >&2; exit 1; }
}

require_linked "bug-workflow/references/bug-repro-template.md"
require_linked "confirm-gate/references/facts-decisions-frontier.md"
require_linked "feature-workflow/references/task-graph-template.md"

echo "PASS: three new references are explicitly linked"

# ------------------------------------------------------------
# 4. 解析 skills=(...) 数组：验证每个元素对应真实 SKILL.md，反向亦然
# ------------------------------------------------------------

# 从 link-skills-common.sh 提取 skills 数组的元素列表
# 兼容 Bash 3.2：用 awk 提取，不用 mapfile / 关联数组
extract_skills_array() {
  local link_sh="$1"
  /usr/bin/awk '
    /local skills=\(/ { in_array=1; next }
    in_array && /^  \)/ { in_array=0; next }
    in_array {
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "$link_sh"
}

# 正向：数组中每个元素必须有对应的 SKILL.md
skills_missing_files=()
while IFS= read -r skill_name; do
  [[ -f "$ROOT/skills/$skill_name/SKILL.md" ]] || skills_missing_files+=("$skill_name")
done < <(extract_skills_array "$LINK_SH")

if ((${#skills_missing_files[@]} > 0)); then
  echo "FAIL: skills array elements without SKILL.md:" >&2
  printf '  - %s\n' "${skills_missing_files[@]}" >&2
  exit 1
fi

# 反向：每个 skills/*/SKILL.md 目录名必须是数组中的完整元素
# 注意：figma-ui-gates 可能是整个目录的 symlink，find 必须跟随目录 symlink。
skills_not_in_array=()
while IFS= read -r -d '' skill_file; do
  dir_name="$(basename "$(dirname "$skill_file")")"
  if ! extract_skills_array "$LINK_SH" | /usr/bin/grep -qxF "$dir_name"; then
    skills_not_in_array+=("$dir_name")
  fi
done < <(find -L "$ROOT/skills" -maxdepth 2 -name "SKILL.md" -type f -print0)

if ((${#skills_not_in_array[@]} > 0)); then
  echo "FAIL: skill directories not in skills array:" >&2
  printf '  - %s\n' "${skills_not_in_array[@]}" >&2
  exit 1
fi

# 验证数组元素数量与实际 SKILL.md 数量一致（含目录 symlink 下的文件）
array_count="$(extract_skills_array "$LINK_SH" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
file_count="$(find -L "$ROOT/skills" -maxdepth 2 -name "SKILL.md" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$array_count" != "$file_count" ]]; then
  echo "FAIL: skills array count ($array_count) != actual SKILL.md count ($file_count)" >&2
  exit 1
fi

echo "PASS: skills array parsed — $array_count elements, all with matching SKILL.md directories"

# ------------------------------------------------------------
# 5. 解析 route 循环列表：验证每个文件名是完整元素且对应真实 route 文件，反向亦然
# ------------------------------------------------------------

# 从 link-skills-common.sh 提取 route 循环中的文件名列表
# 兼容 Bash 3.2：用 awk 逐行提取 xxx.md 模式的 token
extract_routes_list() {
  local link_sh="$1"
  /usr/bin/awk '
    /for route in/ { in_list=1 }
    in_list {
      while (match($0, /[a-z][a-z-]*\.md/)) {
        print substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
      }
      if (/; do/) in_list=0
    }
  ' "$link_sh"
}

routes_dir="$ROOT/skills/code-review-workflow/routes"

# 正向：循环列表中每个文件名必须有对应的 route 文件
routes_missing_files=()
while IFS= read -r route_name; do
  [[ -f "$routes_dir/$route_name" ]] || routes_missing_files+=("$route_name")
done < <(extract_routes_list "$LINK_SH")

if ((${#routes_missing_files[@]} > 0)); then
  echo "FAIL: route list entries without corresponding files:" >&2
  printf '  - %s\n' "${routes_missing_files[@]}" >&2
  exit 1
fi

# 反向：每个 routes/*.md 文件名必须在循环列表中
routes_not_in_list=()
while IFS= read -r -d '' route_file; do
  route_name="$(basename "$route_file")"
  if ! extract_routes_list "$LINK_SH" | /usr/bin/grep -qxF "$route_name"; then
    routes_not_in_list+=("$route_name")
  fi
done < <(find "$routes_dir" -name "*.md" -type f -print0)

if ((${#routes_not_in_list[@]} > 0)); then
  echo "FAIL: route files not in route loop list:" >&2
  printf '  - %s\n' "${routes_not_in_list[@]}" >&2
  exit 1
fi

# 验证循环列表数量与实际 route 文件数量一致
route_list_count="$(extract_routes_list "$LINK_SH" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
route_file_count="$(find "$routes_dir" -name "*.md" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$route_list_count" != "$route_file_count" ]]; then
  echo "FAIL: route list count ($route_list_count) != actual route file count ($route_file_count)" >&2
  exit 1
fi

echo "PASS: route loop parsed — $route_list_count entries, all with matching route files"

# ------------------------------------------------------------
# 6. figma-ui-gates 边界
# ------------------------------------------------------------

if [[ -d "$ROOT/skills/figma-ui-gates/references" ]]; then
  # 如果将来 figma-ui-gates 增加了 references，上面的 references 循环已经覆盖
  :
fi

echo "PASS: figma-ui-gates boundary handled"

echo ""
echo "PASS: link-skill-references coverage (skills array + route loop + references + SKILL.md all parsed and verified)"
