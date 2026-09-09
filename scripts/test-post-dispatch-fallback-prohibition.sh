#!/usr/bin/env bash
# post-dispatch fallback prohibition 文档+gate 一致性测试：
# 1. code-review-workflow/SKILL.md 必须包含 post-dispatch 禁止语义
# 2. code-review-workflow/SKILL.md 不得包含 post-dispatch fallback 切换允许语义
# 3. environment-health-check/SKILL.md 必须声明 fallback 仅 pre-dispatch
# 4. routes/*.md 不得包含 "mid-review.*fallback" / "fails.*fallback" 等冲突语义
# 5. review-loop.md 的 Review path 必须包含 reviewer
# 6. dev-flow-session.sh 的 review_path 验证必须接受 reviewer
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRW_SKILL="$ROOT/skills/code-review-workflow/SKILL.md"
EHC_SKILL="$ROOT/skills/environment-health-check/SKILL.md"
ROUTES_DIR="$ROOT/skills/code-review-workflow/routes"
SESSION_SH="$ROOT/scripts/dev-flow-session.sh"

# ── 1. code-review-workflow/SKILL.md 包含 post-dispatch 禁止语义 ──
/usr/bin/grep -qF 'Post-dispatch failure handling' "$CRW_SKILL" || { echo "FAIL: missing 'Post-dispatch failure handling' section" >&2; exit 1; }
/usr/bin/grep -qF 'no switching is permitted' "$CRW_SKILL" || { echo "FAIL: missing 'no switching is permitted'" >&2; exit 1; }
/usr/bin/grep -qE 'Post-dispatch fallback' "$CRW_SKILL" || { echo "FAIL: missing 'Post-dispatch fallback' language" >&2; exit 1; }
/usr/bin/grep -qE 'prohibited.*review_path.*fallback|review_path.*fallback.*rejected' "$CRW_SKILL" || { echo "FAIL: missing explicit rejection of review_path=fallback" >&2; exit 1; }
/usr/bin/grep -qF 'pre-dispatch' "$CRW_SKILL" || { echo "FAIL: missing 'pre-dispatch' language" >&2; exit 1; }
/usr/bin/grep -qF 'fail-closed' "$CRW_SKILL" || { echo "FAIL: missing 'fail-closed' language" >&2; exit 1; }
echo "PASS: code-review-workflow/SKILL.md has post-dispatch prohibition language"

# ── 2. code-review-workflow/SKILL.md 不得包含冲突语义 ──
# 旧文案 "requires fallback or blocking" 暗示 post-dispatch fallback 是选项
if /usr/bin/grep -qF 'requires fallback or blocking' "$CRW_SKILL"; then
  echo "FAIL: still has 'requires fallback or blocking' (implies post-dispatch fallback is an option)" >&2
  exit 1
fi
# 旧文案 "explicitly enter fallback" 暗示 mid-review 可以切换
if /usr/bin/grep -qF 'explicitly enter fallback' "$CRW_SKILL"; then
  echo "FAIL: still has 'explicitly enter fallback' (implies mid-review fallback switching)" >&2
  exit 1
fi
# 旧文案 "If the primary adapter fails mid-review" 暗示 mid-review 切换是选项
if /usr/bin/grep -qF 'fails mid-review' "$CRW_SKILL"; then
  echo "FAIL: still has 'fails mid-review' language" >&2
  exit 1
fi
echo "PASS: code-review-workflow/SKILL.md has no conflicting post-dispatch fallback language"

# ── 3. environment-health-check/SKILL.md 声明 fallback 仅 pre-dispatch ──
/usr/bin/grep -qF 'Fallback is selected only here' "$EHC_SKILL" || { echo "FAIL: EHC missing 'Fallback is selected only here'" >&2; exit 1; }
/usr/bin/grep -qF 'Post-dispatch fallback switching is prohibited' "$EHC_SKILL" || { echo "FAIL: EHC missing post-dispatch prohibition" >&2; exit 1; }
/usr/bin/grep -qF 'locked on the first review report' "$EHC_SKILL" || { echo "FAIL: EHC missing lock language" >&2; exit 1; }
echo "PASS: environment-health-check/SKILL.md declares pre-dispatch-only fallback"

# ── 4. routes/*.md 不得包含冲突语义 ──
for f in "$ROUTES_DIR"/*.md; do
  if /usr/bin/grep -qE 'mid-review.*fallback|fails.*fallback|unavailable.*fallback.*run|timeout.*fallback.*run' "$f"; then
    echo "FAIL: $f has conflicting post-dispatch fallback language" >&2
    exit 1
  fi
done
echo "PASS: routes/*.md have no conflicting post-dispatch fallback language"

# ── 5. review-loop.md Review path 包含 reviewer ──
/usr/bin/grep -qF 'Review path: reviewer | mcp | fallback' "$ROUTES_DIR/review-loop.md" || { echo "FAIL: review-loop.md missing 'reviewer' in Review path" >&2; exit 1; }
echo "PASS: review-loop.md includes 'reviewer' in Review path"

# ── 6. dev-flow-session.sh review_path 验证接受 reviewer ──
/usr/bin/grep -qF '"reviewer", "mcp", "fallback"' "$SESSION_SH" || { echo "FAIL: dev-flow-session.sh review_path validation missing 'reviewer'" >&2; exit 1; }
echo "PASS: dev-flow-session.sh accepts review_path=reviewer"

# ── 7. dev-flow-session.sh 有 post-dispatch fallback 显式守卫 ──
/usr/bin/grep -qF 'Post-dispatch fallback is not allowed' "$SESSION_SH" || { echo "FAIL: dev-flow-session.sh missing explicit post-dispatch fallback guard" >&2; exit 1; }
echo "PASS: dev-flow-session.sh has explicit post-dispatch fallback guard"

echo ""
echo "PASS: post-dispatch fallback prohibition (docs + gate consistency)"
