#!/usr/bin/env bash
# Route 白名单校验：从 skills/code-review-workflow/routes/ 目录扫描实际 route markdown。
# review-loop.md 和 index.md 不是可 dispatch 的 route，排除。
# Source only；提供 validate_route_name 函数。

# 用法：validate_route_name <route> <devflow_root>
# 返回 0 = 有效；返回 1 = 无效（错误信息输出到 stderr）
validate_route_name() {
  local route="$1"
  local devflow_root="$2"

  # 基本格式校验：只允许 [a-z0-9-]
  if [[ -z "$route" || "$route" =~ [^a-z0-9-] ]]; then
    echo "Invalid route name: '$route' (allowed: [a-z0-9-]+)" >&2
    return 1
  fi

  # 检查对应 markdown 文件存在
  local route_file="$devflow_root/skills/code-review-workflow/routes/${route}.md"
  if [[ ! -f "$route_file" ]]; then
    echo "Unknown route: '$route' (no corresponding route file at skills/code-review-workflow/routes/${route}.md)" >&2
    return 1
  fi

  # 排除 index.md 和 review-loop.md（不是可 dispatch 的 route）
  if [[ "$route" == "index" || "$route" == "review-loop" ]]; then
    echo "Route '$route' is not a dispatchable route (index/review-loop are meta files)" >&2
    return 1
  fi

  return 0
}

# 列出所有有效 route（输出到 stdout，每行一个）
list_valid_routes() {
  local devflow_root="$1"
  local routes_dir="$devflow_root/skills/code-review-workflow/routes"
  if [[ ! -d "$routes_dir" ]]; then
    return 0
  fi
  for f in "$routes_dir"/*.md; do
    [[ -f "$f" ]] || continue
    local name
    name="$(basename "$f" .md)"
    [[ "$name" == "index" || "$name" == "review-loop" ]] && continue
    echo "$name"
  done
}
