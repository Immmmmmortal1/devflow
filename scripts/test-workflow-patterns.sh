#!/usr/bin/env bash
# 工作流模式合同测试（增强版）：
# 1. bug-workflow investigate → red loop → gstack-review → confirm → implement → post-fix rerun 顺序
# 2. confirm-gate Facts/Decisions/frontier
# 3. code-review-workflow Spec/Standards dual-axis + route 必须章节 + review-loop 推导规则
# 4. feature-workflow Task Graph（触发条件、frontier-only claim、no auto git、commit-gate 唯一入口）
# 5. context pointer convention
# + 禁止自动 git 行为
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUG_SKILL="$ROOT/skills/bug-workflow/SKILL.md"
BUG_REF="$ROOT/skills/bug-workflow/references/bug-repro-template.md"
CONFIRM_SKILL="$ROOT/skills/confirm-gate/SKILL.md"
CONFIRM_REF="$ROOT/skills/confirm-gate/references/facts-decisions-frontier.md"
COMMIT_SKILL="$ROOT/skills/commit-gate/SKILL.md"
CRW_SKILL="$ROOT/skills/code-review-workflow/SKILL.md"
ROUTES_DIR="$ROOT/skills/code-review-workflow/routes"
PACKET_REF="$ROOT/skills/code-review-workflow/references/review-packet-template.md"
FEAT_SKILL="$ROOT/skills/feature-workflow/SKILL.md"
FEAT_REF="$ROOT/skills/feature-workflow/references/task-graph-template.md"
TOP_SKILL="$ROOT/SKILL.md"
LINK_SH="$ROOT/scripts/link-skills-common.sh"

require_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "FAIL: missing file $file" >&2; exit 1; }
}

require_grep() {
  local pattern="$1"
  local file="$2"
  local msg="$3"
  /usr/bin/grep -qF "$pattern" "$file" || { echo "FAIL: $msg" >&2; exit 1; }
}

require_grep_e() {
  local pattern="$1"
  local file="$2"
  local msg="$3"
  /usr/bin/grep -qE "$pattern" "$file" || { echo "FAIL: $msg" >&2; exit 1; }
}

reject_grep() {
  local pattern="$1"
  local file="$2"
  local msg="$3"
  if /usr/bin/grep -qF "$pattern" "$file"; then
    echo "FAIL: $msg" >&2
    exit 1
  fi
}

# 查找 pattern 在文件中第一次出现的行号（0 = 未找到）
line_num() {
  local pattern="$1"
  local file="$2"
  local matches
  matches="$(/usr/bin/grep -nF "$pattern" "$file" 2>/dev/null || true)"
  if [[ -z "$matches" ]]; then
    echo 0
    return
  fi
  local first
  first="$(printf '%s\n' "$matches" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
  echo "${first:-0}"
}

# 在指定文件的指定 section（## 标题）内，验证多个 pattern 按行号严格递增出现
# 这样避免 frontmatter 或其他章节中的同名词干扰顺序检查
verify_ascending_in_section() {
  local file="$1"
  local section_header="$2"
  shift 2
  # 用 awk 提取 section_header 行到下一个 ## 标题之间的内容
  local section
  section="$(/usr/bin/awk -v hdr="$section_header" '
    index($0, hdr) > 0 { capturing=1; next }
    capturing && /^## / { exit }
    capturing { print }
  ' "$file")"
  if [[ -z "$section" ]]; then
    echo "FAIL: section '$section_header' not found in $(basename "$file")" >&2
    exit 1
  fi
  local prev=0
  local label pattern matches first
  while [[ $# -gt 0 ]]; do
    label="$1"
    pattern="$2"
    shift 2
    matches="$(printf '%s\n' "$section" | /usr/bin/grep -nF "$pattern" 2>/dev/null || true)"
    if [[ -z "$matches" ]]; then
      echo "FAIL: '$label' not found in section '$section_header' of $(basename "$file") (pattern: $pattern)" >&2
      exit 1
    fi
    first="$(printf '%s\n' "$matches" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    first="${first:-0}"
    if [[ "$first" -eq 0 ]]; then
      echo "FAIL: '$label' line number parse error in section '$section_header' of $(basename "$file")" >&2
      exit 1
    fi
    if [[ "$first" -le "$prev" ]]; then
      echo "FAIL: order violation in section '$section_header' of $(basename "$file"): '$label' (line $first) at or before previous step (line $prev)" >&2
      exit 1
    fi
    prev="$first"
  done
}

# ============================================================
# 1. bug-workflow investigate → red loop → review → confirm → implement → rerun → commit
# ============================================================

require_file "$BUG_REF"

# 基础检查（保留）
require_grep "Red-capable feedback loop" "$BUG_SKILL" "bug-workflow missing Red-capable feedback loop step"
require_grep "references/bug-repro-template.md" "$BUG_SKILL" "bug-workflow missing pointer to bug-repro-template.md"
require_grep "blocked" "$BUG_SKILL" "bug-workflow missing blocked for red-capable loop"
require_grep "minimal repro" "$BUG_SKILL" "bug-workflow missing minimal repro re-run"
require_grep "full scenario" "$BUG_SKILL" "bug-workflow missing full scenario re-run"
require_grep "unit-test" "$BUG_REF" "bug-repro-template missing unit-test evidence type"
require_grep "debugbridge" "$BUG_REF" "bug-repro-template missing debugbridge evidence type"
require_grep "cannot establish red-capable" "$BUG_REF" "bug-repro-template missing blocked reason"

require_grep "Red-capable feedback loop" "$CONFIRM_SKILL" "confirm-gate missing bug red-capable feedback loop contract"
require_grep "Bug repro re-run" "$COMMIT_SKILL" "commit-gate missing Bug repro re-run contract"
require_grep "minimal repro" "$COMMIT_SKILL" "commit-gate missing minimal repro in re-run"
require_grep "full scenario" "$COMMIT_SKILL" "commit-gate missing full scenario in re-run"

# 增强：验证 bug-workflow Order 步骤顺序（investigate → red → review → confirm → implement → rerun → commit）
# 只在 ## Order section 内查找，避免 frontmatter description 中的同名词干扰
verify_ascending_in_section "$BUG_SKILL" "## Order" \
  "gstack-investigate" "gstack-investigate" \
  "Red-capable feedback loop" "Red-capable feedback loop" \
  "gstack-review" "gstack-review" \
  "confirm-gate" "confirm-gate" \
  "implement confirmed scope" "implement confirmed scope" \
  "re-run" "re-run" \
  "commit-gate" "commit-gate"

# 增强：confirm-gate 和 commit-gate 的 hard-stop 语言
require_grep_e "hard.?stop|Hard stop" "$CONFIRM_SKILL" "confirm-gate missing hard-stop language for skipped steps"
require_grep_e "hard.?stop|Hard stop" "$COMMIT_SKILL" "commit-gate missing hard-stop language for missing rerun"

echo "PASS: 1. bug-workflow red-capable feedback loop + order contract"

# ============================================================
# 2. confirm-gate Facts/Decisions/frontier
# ============================================================

require_file "$CONFIRM_REF"

# 基础检查（保留）
require_grep "Facts:" "$CONFIRM_SKILL" "confirm-gate missing Facts section in template"
require_grep "Decisions:" "$CONFIRM_SKILL" "confirm-gate missing Decisions section in template"
require_grep "Decision frontier" "$CONFIRM_SKILL" "confirm-gate missing Decision frontier"
require_grep "closed" "$CONFIRM_SKILL" "confirm-gate missing frontier closure requirement"
require_grep "references/facts-decisions-frontier.md" "$CONFIRM_SKILL" "confirm-gate missing pointer to facts-decisions-frontier.md"
require_grep "Agent-investigated" "$CONFIRM_REF" "facts-decisions-frontier missing Facts definition"
require_grep "Human trade-offs" "$CONFIRM_REF" "facts-decisions-frontier missing Decisions definition"
require_grep "decision frontier" "$CONFIRM_REF" "facts-decisions-frontier missing frontier definition"
require_grep "Frontier not closed" "$CONFIRM_REF" "facts-decisions-frontier missing frontier closure hard stop"
require_grep "requirements-closure" "$CONFIRM_REF" "facts-decisions-frontier missing requirements-closure pointer"
require_grep "partially-open" "$CONFIRM_SKILL" "confirm-gate missing partially-open hard stop"

echo "PASS: 2. confirm-gate Facts/Decisions/frontier contract"

# ============================================================
# 3. code-review-workflow Spec/Standards dual-axis + route 必须章节 + review-loop 推导规则
# ============================================================

# 基础检查（保留）
require_grep "Spec" "$CRW_SKILL" "code-review-workflow missing Spec axis"
require_grep "Standards" "$CRW_SKILL" "code-review-workflow missing Standards axis"
require_grep "blocked > revise > pass" "$CRW_SKILL" "code-review-workflow missing weakest-axis derivation rule"
require_grep "Spec verdict" "$CRW_SKILL" "code-review-workflow missing Spec verdict in handoff"
require_grep "Standards verdict" "$CRW_SKILL" "code-review-workflow missing Standards verdict in handoff"
require_grep "Single-axis masking" "$CRW_SKILL" "code-review-workflow missing single-axis masking prohibition"

require_grep "Spec / Standards dual-axis" "$ROUTES_DIR/index.md" "routes/index.md missing dual-axis in handoff contract"

require_grep "Spec verdict" "$ROUTES_DIR/review-loop.md" "review-loop.md missing Spec verdict"
require_grep "Standards verdict" "$ROUTES_DIR/review-loop.md" "review-loop.md missing Standards verdict"
require_grep "axis: spec | standards" "$ROUTES_DIR/review-loop.md" "review-loop.md missing axis classification for findings"
require_grep "both" "$ROUTES_DIR/review-loop.md" "review-loop.md missing both-axes check in stop gate"

# 基础：所有 4 route 检查 dual-axis
for route in code-quality-review.md requirements-chain-review.md api-contract-review.md ui-parity-review.md; do
  require_grep "Spec / Standards dual-axis" "$ROUTES_DIR/$route" "$route missing dual-axis"
  require_grep "Overall = weakest axis" "$ROUTES_DIR/$route" "$route missing weakest-axis rule"
done

require_grep "Dual-axis report" "$PACKET_REF" "review-packet-template missing dual-axis report section"
require_grep "Spec verdict" "$PACKET_REF" "review-packet-template missing Spec verdict"
require_grep "Standards verdict" "$PACKET_REF" "review-packet-template missing Standards verdict"

require_grep "pass | revise | blocked" "$CRW_SKILL" "code-review-workflow changed unified status vocabulary"
require_grep "pass | revise | blocked" "$ROUTES_DIR/index.md" "routes/index.md changed unified status vocabulary"

# 增强：每个 route 必须有 index 规定的完整章节
REQUIRED_ROUTE_SECTIONS=(
  "## Activation"
  "## Required evidence"
  "## Reviewer question"
  "## Route-specific packet fields"
  "## Blocking conditions"
  "## Pass conditions"
  "## Output status"
)
for route in code-quality-review.md requirements-chain-review.md api-contract-review.md ui-parity-review.md; do
  for section in "${REQUIRED_ROUTE_SECTIONS[@]}"; do
    require_grep "$section" "$ROUTES_DIR/$route" "$route missing required section: $section"
  done
  # 增强：每个 route 必须同时包含 Spec、Standards、overall weakest-axis 三部分
  require_grep "**Spec**" "$ROUTES_DIR/$route" "$route missing Spec axis bullet (**Spec**)"
  require_grep "**Standards**" "$ROUTES_DIR/$route" "$route missing Standards axis bullet (**Standards**)"
  require_grep "Overall = weakest axis" "$ROUTES_DIR/$route" "$route missing overall weakest-axis derivation"
done

# 增强：review-loop 推导规则语义完整
# finding decision 三选项：fix | accept risk | not applicable
require_grep "fix | accept risk | not applicable" "$ROUTES_DIR/review-loop.md" "review-loop missing finding decision triple (fix | accept risk | not applicable)"
# 三轮 stop gate 触发条件
require_grep "three consecutive rounds" "$ROUTES_DIR/review-loop.md" "review-loop missing three-round stop gate trigger"
require_grep "do not enter" "$ROUTES_DIR/review-loop.md" "review-loop missing commit-gate prohibition in stop gate"
# pass 推导：both axes 必须满足
require_grep "both axes" "$ROUTES_DIR/review-loop.md" "review-loop missing both-axes pass derivation"
# timeout/missing 不能当 risk acceptance
require_grep "cannot be classified as risk acceptance" "$ROUTES_DIR/review-loop.md" "review-loop missing timeout/missing anti-washing rule"

echo "PASS: 3. code-review-workflow dual-axis + route sections + review-loop derivation contract"

# ============================================================
# 4. feature-workflow Task Graph（触发条件、frontier-only claim、no auto git、commit-gate 唯一入口）
# ============================================================

require_file "$FEAT_REF"

# 基础检查（保留）
require_grep "Task Graph" "$FEAT_SKILL" "feature-workflow missing Task Graph"
require_grep "independently verifiable" "$FEAT_SKILL" "feature-workflow missing trigger condition (independently verifiable)"
require_grep "deps" "$FEAT_SKILL" "feature-workflow missing trigger condition (deps/fog)"
require_grep "references/task-graph-template.md" "$FEAT_SKILL" "feature-workflow missing pointer to task-graph-template.md"
require_grep "slice" "$FEAT_REF" "task-graph-template missing slice definition"
require_grep "frontier" "$FEAT_REF" "task-graph-template missing frontier definition"
require_grep "fog" "$FEAT_REF" "task-graph-template missing fog definition"
require_grep "claim" "$FEAT_REF" "task-graph-template missing claim definition"
require_grep "No auto-execution" "$FEAT_REF" "task-graph-template missing no-auto-execution rule"
require_grep "Task Graph" "$CONFIRM_SKILL" "confirm-gate missing Task Graph requirement"
require_grep "frontier closure" "$CONFIRM_SKILL" "confirm-gate missing frontier closure for Task Graph"

# 增强：触发条件在正确章节（task-graph-template.md 的 ## Trigger conditions）
require_grep "## Trigger conditions" "$FEAT_REF" "task-graph-template missing Trigger conditions section header"
require_grep "two or more" "$FEAT_REF" "task-graph-template missing >=2 slices trigger condition"
require_grep "real dependency" "$FEAT_REF" "task-graph-template missing real dependency trigger condition"

# 增强：仅 frontier 可 claim 在正确章节（## Rules）
require_grep "## Rules" "$FEAT_REF" "task-graph-template missing Rules section header"
require_grep "Only frontier slices" "$FEAT_REF" "task-graph-template missing frontier-only claim rule in Rules"

# 增强：no auto PR/merge/commit 在正确位置
require_grep "does not auto-create PRs" "$FEAT_REF" "task-graph-template missing no-auto-PR prohibition"
require_grep "does not merge" "$FEAT_REF" "task-graph-template missing no-auto-merge prohibition"
require_grep "does not commit" "$FEAT_REF" "task-graph-template missing no-auto-commit prohibition"

# 增强：commit-gate 唯一入口在正确文件/章节
require_grep "## Relationship to commit-gate" "$FEAT_REF" "task-graph-template missing Relationship to commit-gate section header"
require_grep_e 'commit.gate.+only commit entry' "$FEAT_REF" "task-graph-template missing commit-gate sole entry declaration"
require_grep "commit-gate" "$FEAT_SKILL" "feature-workflow missing commit-gate as only commit entry"

echo "PASS: 4. feature-workflow Task Graph contract"

# ============================================================
# 5. context pointer convention
# ============================================================

require_grep "Context pointer convention" "$TOP_SKILL" "top-level SKILL.md missing Context pointer convention"
require_grep "what the reference is" "$TOP_SKILL" "context pointer convention missing 'what the reference is'"
require_grep "when to read it" "$TOP_SKILL" "context pointer convention missing 'when to read it'"
require_grep "link-skills-common.sh" "$TOP_SKILL" "context pointer convention missing link-skills-common.sh reference"

echo "PASS: 5. context pointer convention"

# ============================================================
# 6. 禁止自动 git 行为
# ============================================================

# 基础检查（保留）
require_grep "does not auto-create PRs" "$FEAT_REF" "task-graph-template missing no-auto-PR prohibition"
require_grep "does not merge" "$FEAT_REF" "task-graph-template missing no-auto-merge prohibition"
require_grep "does not commit" "$FEAT_REF" "task-graph-template missing no-auto-commit prohibition"
require_grep "commit-gate" "$FEAT_SKILL" "feature-workflow missing commit-gate as only commit entry"
require_grep "commit-gate" "$BUG_REF" "bug-repro-template missing commit-gate reference for submission"

# 增强：bug-workflow 也必须声明 commit-gate 为唯一提交入口
require_grep "commit-gate" "$BUG_SKILL" "bug-workflow missing commit-gate in Order steps"
# 增强：feature-workflow Hard rules 中有 no auto git 禁令
require_grep_e "does not (auto-create|merge|commit)" "$FEAT_SKILL" "feature-workflow Hard rules missing no-auto-git prohibition"

echo "PASS: 6. no auto git behavior in new patterns"

echo ""
echo "PASS: workflow patterns (five Matt Pocock modes) contract"
