#!/usr/bin/env bash
# 双层规则文件机制共享函数库。Source only；调用前必须先 dev_flow_load_paths。
#
# 设计：不依赖 AI 记忆，靠门禁脚本强制规则进入上下文——
#   第 1 层：session start / read-rules 时把全局+项目规则全文打到 stdout；
#   第 2 层：每个写 state 的门禁 action 前置校验项目规则 sha256（变更即失败），
#            成功后把项目规则全文回带到 stdout（>4096 字节截断并警告）；
#   第 3 层：approve-commit 额外校验全局规则 sha256，实现闭环。

# 在 dev_flow_load_paths 之后调用，初始化规则文件路径常量
dev_flow_rules_init() {
  # 生产模式强制使用中央仓库的全局规则；DEV_FLOW_TEST_MODE=1 时允许测试覆盖路径
  if [[ "${DEV_FLOW_TEST_MODE:-}" == "1" && -n "${DEV_FLOW_GLOBAL_RULES_FILE:-}" ]]; then
    :
  else
    DEV_FLOW_GLOBAL_RULES_FILE="$DEV_FLOW_SOURCE_ROOT/rules/global-rules.md"
  fi
  DEV_FLOW_PROJECT_RULES_FILE="$DEV_FLOW_PROJECT_ROOT/.dev-flow/rules.md"
  DEV_FLOW_RULES_MAX_BYTES=4096
  # write_state 内嵌 Python 通过环境变量读取路径，避免改动 positional 参数表
  export DEV_FLOW_GLOBAL_RULES_FILE DEV_FLOW_PROJECT_RULES_FILE
}

# .dev-flow 目录或项目规则文件为 symlink 时拒绝（防路径逃逸/内容外控）
dev_flow_rules_reject_symlinks() {
  if [[ -L "$DEV_FLOW_PROJECT_ROOT/.dev-flow" ]]; then
    echo "refusing to use symlinked .dev-flow directory: $DEV_FLOW_PROJECT_ROOT/.dev-flow" >&2
    exit 1
  fi
  if [[ -L "$DEV_FLOW_PROJECT_RULES_FILE" ]]; then
    echo "refusing to use symlinked project rules file: $DEV_FLOW_PROJECT_RULES_FILE" >&2
    exit 1
  fi
}

# 项目规则文件不存在则创建带注释空模板；拒绝 symlink 路径
dev_flow_rules_ensure_project_file() {
  dev_flow_rules_reject_symlinks
  if [[ ! -f "$DEV_FLOW_PROJECT_RULES_FILE" ]]; then
    mkdir -p "$(dirname "$DEV_FLOW_PROJECT_RULES_FILE")"
    cat > "$DEV_FLOW_PROJECT_RULES_FILE" <<'EOF'
# 项目规则（.dev-flow/rules.md）
#
# 在此沉淀本项目独有的规则与记忆。dev-flow 在每个门禁命令执行时会把本文件
# 内容回带到 stdout，确保流程每一轮都带着项目规则，不依赖 AI 记忆。
# 修改本文件后必须先运行 `dev-flow-session.sh read-rules` 刷新记录，
# 否则门禁命令会因 hash 不符而失败。全局规则在 devflow 仓库 rules/global-rules.md。
EOF
  fi
}

# 打印规则文件全文到 stdout（tool result 注入上下文）；>4096 字节截断并醒目警告
# 用法: dev_flow_rules_print "GLOBAL RULES" "$file"
dev_flow_rules_print() {
  local title="$1" file="$2"
  local size
  size="$(/usr/bin/wc -c < "$file" | /usr/bin/tr -d '[:space:]')"
  echo ""
  echo "===== $title ($file) ====="
  if [[ "$size" -gt "$DEV_FLOW_RULES_MAX_BYTES" ]]; then
    /usr/bin/head -c "$DEV_FLOW_RULES_MAX_BYTES" "$file"
    echo ""
    echo "WARNING: rules file truncated (${size} bytes > ${DEV_FLOW_RULES_MAX_BYTES}); 规则文件应保持精简" >&2
  else
    cat "$file"
  fi
  echo "===== END $title ====="
}

# 门禁 action 前置校验：state 必须有 rules.project 记录、记录路径与当前项目绑定一致、
# 且 hash 与当前文件一致。无 state 文件或会话非 active 时放行（主流程报标准会话错误）。
dev_flow_rules_verify_project_fresh() {
  local state_file="$1"
  # symlink 检查先于 state 存在性判断，无 state 的异常路径也不触碰 symlink 目标
  dev_flow_rules_reject_symlinks
  [[ -f "$state_file" ]] || return 0
  /usr/bin/python3 - "$state_file" "$DEV_FLOW_PROJECT_RULES_FILE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

state_path, rules_path = sys.argv[1], Path(sys.argv[2])
try:
    state = json.loads(Path(state_path).read_text())
except (OSError, json.JSONDecodeError):
    sys.exit(0)  # state 不可读时交给主流程报标准会话错误
if not state.get("active"):
    sys.exit(0)
recorded = (state.get("rules") or {}).get("project") or {}
recorded_hash = recorded.get("sha256")
if not recorded_hash:
    raise SystemExit(
        "项目规则未记录（旧会话）。先运行: dev-flow-session.sh read-rules"
    )
# 会话与项目绑定：state 记录的路径必须等于当前项目规则路径，
# 防止同一 session id 跨项目根复用（rules.project.path 是约束字段而非展示字段）
if recorded.get("path") != str(rules_path):
    raise SystemExit(
        f"会话绑定的项目规则路径 ({recorded.get('path')}) 与当前项目 ({rules_path}) 不一致；"
        "请确认 DEV_FLOW_PROJECT_ROOT 或在正确项目中重新 start"
    )
if not rules_path.is_file():
    raise SystemExit(f"项目规则文件缺失: {rules_path}")
current = hashlib.sha256(rules_path.read_bytes()).hexdigest()
if current != recorded_hash:
    raise SystemExit(
        "项目规则已变更，运行 `dev-flow-session.sh read-rules` 重读后再继续"
    )
PY
}

# approve-commit 额外校验：state 必须有 rules.global 记录且 hash 与当前全局文件一致
dev_flow_rules_verify_global_fresh() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  /usr/bin/python3 - "$state_file" "$DEV_FLOW_GLOBAL_RULES_FILE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

state_path, rules_path = sys.argv[1], Path(sys.argv[2])
try:
    state = json.loads(Path(state_path).read_text())
except (OSError, json.JSONDecodeError):
    sys.exit(0)
if not state.get("active"):
    sys.exit(0)
recorded = (state.get("rules") or {}).get("global") or {}
recorded_hash = recorded.get("sha256")
if not recorded_hash:
    raise SystemExit(
        "全局规则未记录（旧会话）。先运行: dev-flow-session.sh read-rules"
    )
if not rules_path.is_file():
    raise SystemExit(f"全局规则文件缺失: {rules_path}")
current = hashlib.sha256(rules_path.read_bytes()).hexdigest()
if current != recorded_hash:
    raise SystemExit(
        "全局规则已变更，运行 `dev-flow-session.sh read-rules` 重读后再继续"
    )
PY
}
