#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
# shellcheck source=lib/dev-flow-rules.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-rules.sh"
dev_flow_rules_init

usage() {
  cat <<'EOF'
Usage:
  scripts/dev-flow-session.sh start --type bug|feature|ui_review --level trivial|standard|heavy [--task "label"] [--trivial-kind docs|pod-patch] [--dependency NAME] [--from-version x.y.z] [--to-version x.y.z]
  scripts/dev-flow-session.sh configure-gates --required <comma-separated gates>
  scripts/dev-flow-session.sh environment-health --report <path>
  scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime|ui_parity --report <path>
  scripts/dev-flow-session.sh confirm-plan [--task "label"]
  scripts/dev-flow-session.sh validate-trivial
  scripts/dev-flow-session.sh approve-commit [--task "label"]
  scripts/dev-flow-session.sh commit --message "msg"
  scripts/dev-flow-session.sh testflight
  scripts/dev-flow-session.sh read-rules
  scripts/dev-flow-session.sh end
  scripts/dev-flow-session.sh status

Trivial fast-path (--level trivial):
  --level trivial 必须带 --trivial-kind docs|pod-patch。
  pod-patch 还必须带 --dependency NAME --from-version x.y.z --to-version x.y.z
  （from 绑定 HEAD 版本，to 绑定 index 版本；仅同 major/minor、patch 递增）。
  trivial 会话写 required_gates=[]（schema v2, fast_path=true），禁止 configure-gates，
  不需要独立 review/ticket/review-health/App/DebugBridge/Figma；环境门四项 not-required
  且 overall available。仍需 confirm-plan → environment-health → stage 后 validate-trivial →
  approve-commit → commit。validate-trivial 记录 HEAD/index-tree/path-mode-type-content digest；
  approve 与 commit 前重算，漂移拒绝。超界（非纯文档/非纯 pod-patch）标记 requires-standard
  或 requires-heavy 并冻结，不能 approve/commit。

Rules note (双层规则机制):
  start/read-rules 打印全局(rules/global-rules.md)+项目(.dev-flow/rules.md)规则全文到 stdout；
  所有写 state 的门禁 action 前置校验项目规则 sha256，变更后必须先 read-rules；
  门禁 action 成功后把项目规则回带到 stdout；approve-commit 额外校验全局规则 sha256。

Session selection:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, then CURSOR_CONVERSATION_ID.
  Outside Cursor, falls back to "local". Inside Cursor, a missing conversation id is an error.
Gate note:
  ui_review source repair requires review,runtime,ui_parity before confirm-plan.
  Environment health runs after confirm-plan; record-gate/approve-commit/commit/testflight require it available.
  commit 收口提交动作：approve-commit 已批 + 暂存区非空才会执行 git commit 并记录 hash；
  testflight 委托项目 fastlane：commit 完成且 HEAD 未漂移才执行
  <项目>/.dev-flow/testflight-command 中的命令并登记证据。
Task level (--level, only meaningful for start):
  trivial   - 文档/typo 或 pod 依赖 patch 修补专用 fast-path；required_gates=[]，环境门四项
              not-required；禁止 configure-gates；必须带 --trivial-kind 并经 validate-trivial 校验。
  standard  - 默认；普通 feature/bug；required_gates=[review]。
  heavy     - 新 Figma UI / ui_review；需手动 configure-gates 加 runtime/figma_ui/ui_parity。
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_common_args() {
  SESSION_TYPE=""
  TASK=""
  SESSION_LEVEL="standard"
  TRIVIAL_KIND=""
  POD_DEPENDENCY=""
  FROM_VERSION=""
  TO_VERSION=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        SESSION_TYPE="${2:-}"
        shift 2
        ;;
      --task)
        TASK="${2:-}"
        shift 2
        ;;
      --level)
        SESSION_LEVEL="${2:-}"
        shift 2
        ;;
      --trivial-kind)
        TRIVIAL_KIND="${2:-}"
        shift 2
        ;;
      --dependency)
        POD_DEPENDENCY="${2:-}"
        shift 2
        ;;
      --from-version)
        FROM_VERSION="${2:-}"
        shift 2
        ;;
      --to-version)
        TO_VERSION="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

write_state() {
  local action="$1"
  local session_type="${2:-}"
  local task="${3:-}"
  local required_gates="${4:-}"
  local project_root="${5:-}"
  local level="${6:-}"
  local trivial_kind="${7:-}"
  local params_json="${8:-}"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$action" "$session_type" "$task" "$required_gates" "$(now_utc)" "$project_root" "$level" "$trivial_kind" "$params_json" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
session_id = sys.argv[2]
action = sys.argv[3]
session_type = sys.argv[4]
task = sys.argv[5]
required_gates_arg = sys.argv[6]
timestamp = sys.argv[7]
project_root = sys.argv[8]
level = sys.argv[9]
trivial_kind = sys.argv[10]
params_json = sys.argv[11]
trusted_root = sys.argv[12]
source_root = sys.argv[13]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json
from trivial_session import resolve_required_gates

all_gates = ("figma_ui", "review", "runtime", "ui_parity")
required_gates = [item for item in required_gates_arg.split(",") if item]

# trivial fast-path 参数解析
try:
    trivial_params = json.loads(params_json) if params_json else {}
except json.JSONDecodeError:
    trivial_params = {}

# trivial 必须显式 required_gates=[]；standard/heavy 默认 [review]。
# 旧/缺 schema 或非 trivial 空 gates 不能自动放行：start 时若 level 非 trivial 却得到空
# required_gates，fail closed（要求显式 configure 或重开 standard/heavy）。
if action == "start":
    if level == "trivial":
        required_gates = []  # trivial 显式空 gates
    else:
        if not required_gates:
            required_gates = ["review"]
else:
    # 非 start 命令：空 required_gates 不补默认（configure-gates 自带校验）
    if not required_gates and action != "configure-gates":
        # 读取现有 state 时由调用方控制；此处仅对显式传入做校验
        pass

if any(item not in all_gates for item in required_gates):
    raise SystemExit("Unknown gate. Use figma_ui, review, runtime, or ui_parity.")
# trivial fast-path：review 不再恒必需；仅 standard/heavy 要求 review 在 required_gates
is_trivial = (action == "start" and level == "trivial")
if not is_trivial:
    if action in ("start", "configure-gates") and "review" not in required_gates:
        raise SystemExit("The review gate is required for every non-trivial dev-flow commit session.")
if len(set(required_gates)) != len(required_gates):
    raise SystemExit("Duplicate required gate.")

default_gate_results = {
    "figma_ui": {"status": "not-required", "evidence": None, "recorded_at": None},
    "review": {"status": "not-required", "evidence": None, "recorded_at": None},
    "runtime": {"status": "not-required", "evidence": None, "recorded_at": None},
    "ui_parity": {"status": "not-required", "evidence": None, "recorded_at": None},
}

def make_gate_results(required):
    results = json.loads(json.dumps(default_gate_results))
    for gate in required:
        results[gate]["status"] = "pending"
    return results

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        data = {}

VALID_LEVELS = ("trivial", "standard", "heavy")
# 空 level 仅出现在非 start 命令（configure-gates/confirm 等），不校验；start 必须传合法 level
if level and level not in VALID_LEVELS:
    raise SystemExit("Invalid level. Use trivial, standard, or heavy.")


if action == "start":
    # trivial fast-path 参数约束
    if level == "trivial":
        if trivial_kind not in ("docs", "pod-patch"):
            raise SystemExit(
                "start --level trivial requires --trivial-kind docs|pod-patch"
            )
        if trivial_kind == "pod-patch":
            dep = trivial_params.get("dependency", "")
            fv = trivial_params.get("from_version", "")
            tv = trivial_params.get("to_version", "")
            if not dep or not fv or not tv:
                raise SystemExit(
                    "start --level trivial --trivial-kind pod-patch requires "
                    "--dependency NAME --from-version x.y.z --to-version x.y.z"
                )
    else:
        # 非 trivial 不允许带 trivial-kind（避免误用）
        if trivial_kind:
            raise SystemExit(
                f"--trivial-kind is only valid with --level trivial (got level={level})"
            )
    data = {
        "session_id": session_id,
        "schema_version": 2,
        "active": True,
        "type": session_type,
        "task": task,
        "level": level,
        "fast_path": (level == "trivial"),
        "started_at": timestamp,
        "confirmed_at": None,
        "commit_approved_at": None,
        "approved_scope": None,
        "ended_at": None,
        "required_gates": required_gates,
        "gate_results": make_gate_results(required_gates),
        "environment_health": {
            "status": "not-run",
            "checked_at": None,
            "checks": {},
        },
        "trivial_validation": None,
    }
    if level == "trivial":
        data["trivial"] = {
            "kind": trivial_kind,
            "params": trivial_params,
        }
    # 双层规则机制：start 必须记录全局+项目规则的 path/sha256/read_at。
    # 路径经环境变量传入（shell 侧已校验全局文件存在、项目模板已创建）。
    rules_block = {}
    for scope, env_name in (("global", "DEV_FLOW_GLOBAL_RULES_FILE"),
                            ("project", "DEV_FLOW_PROJECT_RULES_FILE")):
        rules_path = os.environ.get(env_name, "")
        if not rules_path or not Path(rules_path).is_file():
            raise SystemExit(f"rules file missing for start: {env_name}={rules_path or '<unset>'}")
        rules_block[scope] = {
            "path": rules_path,
            "sha256": hashlib.sha256(Path(rules_path).read_bytes()).hexdigest(),
            "read_at": timestamp,
        }
    data["rules"] = rules_block
elif action == "configure-gates":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("fast_path") or data.get("level") == "trivial":
        raise SystemExit("configure-gates is forbidden for trivial fast-path sessions; re-open as standard/heavy.")
    if data.get("confirmed_at"):
        raise SystemExit("Required gates cannot change after plan confirmation.")
    # 能力模型：required_gates 决定必需环境能力，不再按 --level 限制 gate 配置
    data["required_gates"] = required_gates
    data["gate_results"] = make_gate_results(required_gates)
    data["session_id"] = session_id
elif action == "confirm-plan":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("type") == "ui_review":
        required = set(data.get("required_gates", []))
        missing = {"review", "runtime", "ui_parity"} - required
        if missing:
            raise SystemExit(
                "ui_review source repair requires gates configured before confirm-plan: "
                + ",".join(sorted(missing))
            )
    # 环境门禁后移：confirm-plan 不再要求 environment_health；改由 confirm 后的
    # 敏感动作（record-gate/approve-commit/commit/testflight）统一校验
    # requirements 门禁：存在 pending-human-approval 条目时禁止 confirm-plan
    if project_root:
        req_index = Path(project_root) / ".dev-flow" / "requirements" / "index.json"
        if req_index.is_file():
            try:
                req_payload = json.loads(req_index.read_text())
            except json.JSONDecodeError as exc:
                raise SystemExit(f"requirements index.json is invalid: {exc}") from exc
            # 宽松校验：扫描 requirements/items/logic_ids 任一字段中的 pending-human-approval
            items = req_payload.get("requirements") or req_payload.get("items") or req_payload.get("logic_ids") or []
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, dict) and item.get("status") == "pending-human-approval":
                        raise SystemExit("requirements contain pending-human-approval items; approve or close them before confirm-plan.")
            elif isinstance(items, dict):
                for entry in items.values():
                    if isinstance(entry, dict) and entry.get("status") == "pending-human-approval":
                        raise SystemExit("requirements contain pending-human-approval items; approve or close them before confirm-plan.")
    data["confirmed_at"] = timestamp
    data["session_id"] = session_id
    if task:
        data["task"] = task
elif action == "approve-commit":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if not data.get("confirmed_at"):
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
    # 环境门禁后移：approve-commit 仍要求 environment_health available 且 checked_at 非空
    # （shell 层 dev_flow_verify_environment_health 已先行校验，此为深度防御）
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    checked_at = data.get("environment_health", {}).get("checked_at")
    if not isinstance(checked_at, str) or not checked_at.strip():
        raise SystemExit("Environment health checked_at is missing; run environment-health-check.sh first.")
    # 冻结态（trivial 超界被标记 requires-standard/heavy）禁止 approve
    frozen_status = (data.get("trivial_validation") or {}).get("escalation")
    if frozen_status in ("requires-standard", "requires-heavy"):
        raise SystemExit(
            f"session is frozen ({frozen_status}); re-open as standard/heavy. "
            "Evidence is not inherited."
        )
    # 一致性交叉校验：只有合法 trivial（schema2+level+fast_path+kind+空 gates 配套）
    # 才允许空 gates 走 trivial 分支；非 trivial 显式空 gates / 缺 review / 字段自相矛盾
    # → resolve_required_gates fail closed（不可 approve）。避免仅靠可篡改的单一字段。
    required, is_trivial = resolve_required_gates(data)
    if is_trivial:
        # trivial fast-path：不要求 review gate，但要求 validate-trivial 已通过且 digest 未漂移
        tv = data.get("trivial_validation")
        if not tv or tv.get("result") != "pass":
            raise SystemExit("Trivial fast-path requires validate-trivial to pass before approve-commit.")
        # 重算 digest，比对漂移；同时校验工作树仍干净（validate 后变 dirty/untracked 也拒绝）
        from trivial_scope_validator import compute_digest_only, check_clean_worktree
        if project_root:
            clean_ok, clean_reason = check_clean_worktree(project_root)
            if not clean_ok:
                raise SystemExit(
                    "Worktree not clean since validate-trivial: " + clean_reason
                )
            current = compute_digest_only(project_root)
            if current.get("scope_digest") != tv.get("scope_digest"):
                raise SystemExit(
                    "Trivial scope digest drifted since validate-trivial; re-run validate-trivial."
                )
            if current.get("head") != tv.get("head") or current.get("index_tree") != tv.get("index_tree"):
                raise SystemExit(
                    "Trivial staged state drifted since validate-trivial; re-run validate-trivial."
                )
        # 批准时绑定 approved scope digest/head/index-tree（issue #3）：
        # commit 时必须同时比对 current == trivial_validation == approved_scope 三者一致，
        # 防止 revalidate 后用旧 approval 提交不同 scope。
        data["commit_approved_at"] = timestamp
        data["approved_scope"] = {
            "scope_digest": current.get("scope_digest"),
            "head": current.get("head"),
            "index_tree": current.get("index_tree"),
            "approved_at": timestamp,
        }
        data["session_id"] = session_id
        if task:
            data["task"] = task
    else:
        # standard/heavy：gate 校验。required 已由 resolve_required_gates 交叉校验
        #（非 trivial 必含 review，显式空 gates 已在 resolve 阶段被拒）。
        results = data.get("gate_results", {})
        expected = {
            "figma_ui": "pass",
            "review": "pass",
            "runtime": "runtime-verified",
            "ui_parity": "accepted",
        }
        blocked = []
        for gate in required:
            actual = results.get(gate, {}).get("status")
            if actual != expected[gate]:
                blocked.append(f"{gate}={actual or 'missing'} (requires {expected[gate]})")
        if blocked:
            raise SystemExit("Required gate(s) unresolved: " + ", ".join(blocked))
        data["commit_approved_at"] = timestamp
        data["session_id"] = session_id
        if task:
            data["task"] = task
elif action == "end":
    if not data:
        data = {"session_id": session_id, "active": False}
    data["session_id"] = session_id
    data["active"] = False
    data["ended_at"] = timestamp
else:
    raise SystemExit(f"Unsupported action: {action}")

safe_atomic_write_json(trusted_root, path, data)
print(path)
PY
}

# read-rules：刷新 state 中全局+项目规则的 sha256/read_at（规则变更后的恢复入口）
refresh_rules_state() {
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
trusted_root = sys.argv[4]
source_root = sys.argv[5]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")

# read-rules 不允许跨项目重绑：已记录的项目规则路径必须与当前项目一致，
# 防止同一 session id 被切换到其他项目根后继续走门禁（应在新项目重新 start）
existing_project = ((state.get("rules") or {}).get("project") or {}).get("path")
current_project = os.environ.get("DEV_FLOW_PROJECT_RULES_FILE", "")
if existing_project and existing_project != current_project:
    raise SystemExit(
        f"会话绑定的项目规则路径 ({existing_project}) 与当前项目 ({current_project}) 不一致；"
        "read-rules 不能跨项目重绑，请在正确项目中操作或重新 start"
    )

rules_block = {}
for scope, env_name in (("global", "DEV_FLOW_GLOBAL_RULES_FILE"),
                        ("project", "DEV_FLOW_PROJECT_RULES_FILE")):
    rules_path = os.environ.get(env_name, "")
    if not rules_path or not Path(rules_path).is_file():
        raise SystemExit(f"rules file missing for read-rules: {env_name}={rules_path or '<unset>'}")
    rules_block[scope] = {
        "path": rules_path,
        "sha256": hashlib.sha256(Path(rules_path).read_bytes()).hexdigest(),
        "read_at": timestamp,
    }
state["rules"] = rules_block
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
PY
}

# 环境门禁统一校验：confirm 后、敏感动作（record-gate/approve-commit/commit/testflight）前
# 要求 environment_health.status == available 且 checked_at 非空。
# 未 confirm 的会话不校验环境（read-only ui_review review 等场景）。
dev_flow_verify_environment_health() {
  local state_file="$1"
  /usr/bin/python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
# 只在 confirm 后校验环境门禁；未 confirm 的 read-only 等场景不要求
confirmed_at = state.get("confirmed_at")
if not confirmed_at:
    raise SystemExit(0)
env = state.get("environment_health") or {}
if env.get("status") != "available":
    raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
checked_at = env.get("checked_at")
if not isinstance(checked_at, str) or not checked_at.strip():
    raise SystemExit("Environment health checked_at is missing; run environment-health-check.sh first.")
# 深度防御：confirm 前跑过的 env 不能复用；必须 confirm 后重新跑
# （record_environment 已拒绝 confirm 前写入，此处防止绕过/旧 state）
if checked_at < confirmed_at:
    raise SystemExit("Environment health was recorded before confirm-plan. Re-run environment-health-check.sh after confirm-plan.")
PY
}

 record_environment() {
   local report_file="$1"
   mkdir -p "$STATE_DIR"
   /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$report_file" "$(now_utc)" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
report_path = Path(sys.argv[3])
checked_at = sys.argv[4]
trusted_root = sys.argv[5]
source_root = sys.argv[6]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json
from trivial_session import resolve_required_gates

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
# 环境门禁后移：environment-health 只能在 confirm-plan 之后写入有效证据；
# confirm 前误跑会被拒绝，防止 confirm 前的 env 被 confirm 后复用
if not state.get("confirmed_at"):
    raise SystemExit("Environment health can only run after confirm-plan. Run confirm-plan first.")
# 一致性交叉校验：合法 trivial 才允许空 gates（四项 not-required）；非 trivial 显式空
# gates / 缺 review / 字段自相矛盾 → resolve fail closed（不可获得 available）。
# 旧 session 缺 required_gates → 回退 ["review"]（与原行为一致）。
gates, _is_trivial = resolve_required_gates(state)
# REPORT_FILE 现在使用系统临时目录（不在 STATE_DIR 内），
# 路径位置不再作为防伪依据；改为依赖 producer/schema_version/session_id 内容校验。
report = json.loads(report_path.read_text())
if report.get("producer") != "environment-health-check":
    raise SystemExit("Environment report was not produced by environment-health-check.")
# schema_version 2：capability-based 模型（required/not-required 区分）。
# 旧 schema_version 1（四项全 available）报告被明确拒绝：语义已变，需重跑 environment-health-check.sh。
if report.get("schema_version") != 2:
    raise SystemExit(
        "Environment report schema_version must be 2. Stale v1 reports are rejected; "
        "re-run scripts/environment-health-check.sh run after confirm-plan."
    )
if report.get("session_id") != session_id:
    raise SystemExit("Environment report belongs to another session.")
checks = report.get("checks")
all_check_keys = ("app_launch", "debugbridge", "review_mcp", "figma_rest_api")
if not isinstance(checks, dict) or any(name not in checks for name in all_check_keys):
    raise SystemExit("Environment report is missing required checks.")
# not-required 是 schema v2 新增的合法状态值（非 required capability）。
valid_statuses = ("available", "blocked", "not-run", "not-required")
if any(checks[name].get("status") not in valid_statuses for name in all_check_keys):
    raise SystemExit("Environment report contains an invalid check status.")

# 从 resolve_required_gates 派生 required capabilities（与环境探针同一映射）。
# 已交叉校验：非 trivial 必含 review，显式空 gates 已被拒，自相矛盾已被拒。
gate_to_caps = {
    "review": {"review_mcp"},
    "runtime": {"app_launch", "debugbridge"},
    "figma_ui": {"app_launch", "debugbridge", "figma_rest_api"},
    "ui_parity": {"app_launch", "debugbridge", "figma_rest_api"},
}
required_caps = set()
for gate in gates:
    required_caps |= gate_to_caps.get(gate, set())

# 严格契约：required capability 必须 available 才总 available；
# 非 required capability 必须 not-required（不允许用伪 available 混过去）。
for cap in all_check_keys:
    status = checks[cap].get("status")
    if cap in required_caps:
        if status != "available":
            pass  # required 但非 available → derived blocked
    else:
        if status != "not-required":
            raise SystemExit(
                f"Non-required capability {cap} must be not-required, got {status}. "
                "Re-run scripts/environment-health-check.sh run to regenerate the report."
            )

derived_status = "available" if all(
    checks[cap].get("status") == "available" for cap in required_caps
) else "blocked"
if report.get("status") != derived_status:
    raise SystemExit("Environment report status does not match its checks.")
state["environment_health"] = {
    "status": derived_status,
    "checked_at": checked_at,
    "checks": checks,
    "required_gates": report.get("required_gates", []),
    "required_capabilities": report.get("required_capabilities", []),
}
# review_selection 绑定：从 review_mcp check 提取 selected_adapter/config_digest，
# 写入 state.review_selection 供 record-gate 校验（no-result-washing）。
# 已锁定（review 已记录）时不覆盖，防止 dispatch 后切换 adapter。
# source=default 时不写 review_selection——默认策略不算"已配置"，
# record-gate 会因无 review_selection 拒绝，迫使显式 install-review-backend.sh。
review_mcp_check = checks.get("review_mcp") or {}
existing_selection = state.get("review_selection") or {}
if not existing_selection.get("locked"):
    selected_adapter = review_mcp_check.get("selected_adapter")
    config_digest = review_mcp_check.get("config_digest")
    selection_source = review_mcp_check.get("source") or ""
    skill_path = review_mcp_check.get("skill_path") or ""
    if selected_adapter and config_digest and selection_source != "default":
        state["review_selection"] = {
            "selected_adapter": selected_adapter,
            "selection_reason": review_mcp_check.get("selection_reason", ""),
            "config_digest": config_digest,
            "source": selection_source,
            "skill_path": skill_path,
            "resolved_at": checked_at,
            "locked": False,
        }
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
if derived_status != "available":
    raise SystemExit(1)
PY
}

record_gate() {
  local gate_name="$1"
  local report_file="$2"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$gate_name" "$report_file" "$(now_utc)" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


state_path = Path(sys.argv[1])
session_id = sys.argv[2]
gate_name = sys.argv[3]
report_path = Path(sys.argv[4])
recorded_at = sys.argv[5]
trusted_root = sys.argv[6]
source_root = sys.argv[7]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json, safe_read_bytes
devflow_root = Path(source_root).resolve()


def sha256_of(path):
    # 计算 artifact 文件内容 sha256，用于与人工批准时记录的 digest 比对
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _validate_digest(value, field_name):
    """统一 digest 格式校验：sha256: 前缀 + 严格 64 位小写十六进制。
    拒绝：非字符串、空、无前缀、前缀后非 64 hex、大小写不符、多余字符。
    """
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{field_name} must be a non-empty sha256-prefixed digest.")
    if not value.startswith("sha256:"):
        raise SystemExit(f"{field_name} must start with 'sha256:' prefix.")
    hex_part = value[len("sha256:"):]
    if len(hex_part) != 64:
        raise SystemExit(f"{field_name} must have exactly 64 hex chars after 'sha256:' (got {len(hex_part)}).")
    if not all(c in "0123456789abcdef" for c in hex_part):
        raise SystemExit(f"{field_name} must contain only lowercase hex chars after 'sha256:'.")

if gate_name not in ("figma_ui", "review", "runtime", "ui_parity"):
    raise SystemExit("Unknown gate. Use figma_ui, review, runtime, or ui_parity.")
if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
if not state.get("confirmed_at"):
    read_only_review = (
        state.get("type") == "ui_review"
        and gate_name == "review"
    )
    if not read_only_review:
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
if gate_name not in state.get("required_gates", []):
    raise SystemExit(f"Gate is not required for this session: {gate_name}")
if not report_path.is_file():
    raise SystemExit("Gate report does not exist.")

report = json.loads(report_path.read_text())
if report.get("session_id") != session_id:
    raise SystemExit("Gate report belongs to another session.")
if report.get("gate") != gate_name:
    raise SystemExit("Gate report name does not match --name.")

# review gate: 顶层字段白名单 + producer/schema_version 校验
if gate_name == "review":
    REVIEW_ALLOWED_FIELDS = {
        "session_id", "gate", "status", "evidence", "producer", "schema_version",
        "route", "reviewer_result", "run_id", "diff_evidence", "source_edits",
        "artifact_workspace", "artifact_validation_report", "baseline_report",
        "parity_confirmed_report", "repair_accepted_report", "verified_ids",
        "debugbridge_evidence", "review_path", "fallback_token", "packet_digest",
        "selected_adapter", "config_digest", "ticket_token", "ticket_digest",
        "result_artifact", "result_artifact_digest", "findings",
        "adapter_result_ref", "adapter_result_digest",
    }
    extra = set(report.keys()) - REVIEW_ALLOWED_FIELDS
    if extra:
        raise SystemExit("review report contains unknown fields: " + ", ".join(sorted(extra)))
    if report.get("producer") not in ("code-review-workflow", "review-health-probe", "ui-review"):
        raise SystemExit("review report producer must be code-review-workflow, review-health-probe, or ui-review.")
    if report.get("schema_version") != 1:
        raise SystemExit("review report schema_version must be 1.")
    # selection binding（no-result-washing）：review_selection 必须存在且非空——
    # 没有 environment-health-check 产生的 selection binding，review gate 必须拒绝。
    # 旧会话（无 review_selection）必须重跑 environment-health-check。
    # 例外：read-only ui_review（producer=ui-review，无 confirmed_at）不需要 review_selection，
    # 因为 read-only 路径不做代码改动，无需 dispatch 审查。
    # 一旦 dispatch 开始（review 报告已记录），不得切换 adapter——只有同一 adapter 的明确 pass 才过。
    is_readonly_ui_review = (
        report.get("producer") == "ui-review"
        and not state.get("confirmed_at")
    )
    review_selection = state.get("review_selection") or {}
    if not is_readonly_ui_review:
        if not review_selection.get("selected_adapter"):
            raise SystemExit(
                "review gate requires an environment-generated review_selection. "
                "Run scripts/environment-health-check.sh run before recording review results. "
                "Old sessions without review_selection must re-run environment-health-check."
            )
        bound_adapter = review_selection.get("selected_adapter")
        bound_digest = review_selection.get("config_digest")
        bound_source = review_selection.get("source") or ""
        report_adapter = report.get("selected_adapter")
        report_digest = report.get("config_digest")
        if not report_adapter:
            raise SystemExit(
                "review report must include selected_adapter "
                "matching the session's review_selection (bound adapter: "
                + str(bound_adapter) + ")."
            )
        # 统一 digest 格式校验：config_digest 必须 sha256: + 64 hex
        _validate_digest(report_digest, "config_digest")
        _validate_digest(bound_digest, "review_selection.config_digest")
        if report_adapter != bound_adapter:
            raise SystemExit(
                "review report selected_adapter mismatch: report="
                + str(report_adapter)
                + " but session bound=" + str(bound_adapter)
                + ". Post-dispatch adapter switching is not allowed."
            )
        if report_digest != bound_digest:
            raise SystemExit(
                "review report config_digest mismatch: the review config changed "
                "after selection binding. Re-run environment-health-check.sh and "
                "the review dispatch to rebind."
            )
        # 非 fallback 路径的 pass 报告要求 run_id + diff_evidence 非空（降低无 dispatch 证据误填风险）
        review_path = report.get("review_path")
        if report.get("status") == "pass" and review_path != "fallback":
            if not report.get("run_id"):
                raise SystemExit(
                    "non-fallback review pass report must include a non-empty run_id "
                    "(evidence of actual dispatch)."
                )
            if not report.get("diff_evidence"):
                raise SystemExit(
                    "non-fallback review pass report must include non-empty diff_evidence "
                    "(evidence of reviewed diff)."
                )
            # 统一 digest 格式校验：diff_evidence（worktree digest）必须 sha256: + 64 hex
            _validate_digest(report.get("diff_evidence"), "diff_evidence")
        # post-dispatch fallback 禁止：review_selection 已锁定后，review_path="fallback"
        # 的报告只在 locked adapter 本身是 skill/gstack 时才被接受。
        # 这是独立于 adapter mismatch 的显式守卫：即使 adapter 字段匹配，
        # 也不允许 dispatch 后切换到 fallback 路径。
        if review_selection.get("locked") and report.get("review_path") == "fallback":
            if bound_adapter != "skill/gstack":
                raise SystemExit(
                    "Post-dispatch fallback is not allowed: the session's adapter "
                    "was locked to " + str(bound_adapter) + " at dispatch time. "
                    "Timeout, missing result, error, blocked, or revise must fail "
                    "as-is; do not switch to gstack-review fallback after dispatch "
                    "has begun."
                )
    # fallback 绑定：会话环境门处于 gstack-review fallback 时，报告必须出自
    # run-review-fallback.sh —— 校验一次性 fallback_token、packet_digest、报告路径三件套，
    # 降低伪报路径/宿主审查伪报风险（不是对拥有写权限者的密码学证明）
    env = state.get("environment_health") or {}
    review_mcp_check = (env.get("checks") or {}).get("review_mcp") or {}
    env_evidence = str(review_mcp_check.get("evidence") or "")
    env_segments = [seg.strip() for seg in env_evidence.split(";")]
    # 结构一致性：环境门与 review_mcp 检查本身必须 available，且 evidence 分段精确匹配
    fallback_session = (
        env.get("status") == "available"
        and review_mcp_check.get("status") == "available"
        and "fallback=gstack-review" in env_segments
    )
    if fallback_session:
        fb = state.get("review_fallback") or {}
        if not fb.get("token") or report.get("fallback_token") != fb.get("token"):
            raise SystemExit(
                "fallback review requires a valid fallback_token issued by "
                "scripts/run-review-fallback.sh (run it and review the injected packet)."
            )
        # 重新计算 packet 文件 digest：文件==state==报告三方一致，
        # 防止签发后 packet 被篡改而报告仍填旧 digest
        packet_path = Path(fb.get("packet_path") or "")
        if not fb.get("packet_path") or packet_path.is_symlink() or not packet_path.is_file():
            raise SystemExit(
                "fallback review packet is missing or not a regular file: "
                + str(fb.get("packet_path"))
            )
        actual_digest = sha256_of(packet_path)
        if actual_digest != fb.get("packet_digest"):
            raise SystemExit(
                "review packet file changed after issue; re-run scripts/run-review-fallback.sh."
            )
        if report.get("packet_digest") != actual_digest:
            raise SystemExit(
                "packet_digest mismatch: review must cover the exact packet issued by "
                "run-review-fallback.sh (re-run it after code changes)."
            )
        # 报告路径 symlink 绕过防护：预建 symlink 指向外部文件时 resolve() 双向跟随会放行，
        # 改为拒 is_symlink + abspath（不跟随 symlink）比较固定签发路径
        if report_path.is_symlink():
            raise SystemExit(
                "refusing to read fallback review report through a symlink: " + str(report_path)
            )
        issued_path = str(Path(fb.get("report_path") or ""))
        if not issued_path or os.path.abspath(str(report_path)) != os.path.abspath(issued_path):
            raise SystemExit(
                "fallback review report must live at the runner-issued path: " + issued_path
            )
        if report.get("review_path") != "fallback":
            raise SystemExit(
                "Session is in gstack-review fallback mode; review report must set review_path=fallback."
            )
        # route 三方绑定：报告 route 必须等于 runner 签发 route（审查契约一致性）
        if report.get("route") != fb.get("route"):
            raise SystemExit(
                "route mismatch: report route must equal the runner-issued route ("
                + str(fb.get("route")) + ")."
            )
        # 注入文档绑定：gstack SKILL.md / route 契约签发后被修改则拒收。
        # 文档为只读输入，允许 symlink（拒 symlink 只适用于 packet 这类写入目标）
        for label, path_key, digest_key in (
            ("gstack skill", "gstack_skill_path", "gstack_skill_digest"),
            ("route contract", "route_path", "route_digest"),
        ):
            doc_raw = fb.get(path_key) or ""
            doc_path = Path(doc_raw)
            if not doc_raw or not doc_path.is_file():
                raise SystemExit(f"fallback {label} is missing: {doc_raw}")
            if sha256_of(doc_path) != fb.get(digest_key):
                raise SystemExit(
                    f"fallback {label} changed after issue; re-run scripts/run-review-fallback.sh."
                )
    if report.get("review_path") is not None and report.get("review_path") not in ("reviewer", "mcp", "fallback"):
        raise SystemExit('review_path must be "reviewer", "mcp", or "fallback".')

    # ── 统一 review dispatch ticket 验证 ──
    # 所有 review 报告（agent/mcp/fallback）必须携带有效 ticket_token + ticket_digest。
    # ticket 由 issue-review-ticket.sh 在 dispatch 前签发，record-gate 验证归属、
    # adapter/config/route/worktree_digest、token/digest、未消费状态；pass 后原子标记 consumed。
    # 诚实声明：本地完整性门用于防误操作/漂移/重放，降低误填风险；
    # 不是对拥有本机写权限攻击者的密码学证明。
    # 例外：read-only ui_review（无 confirmed_at）不需要 ticket（不做代码改动）。
    if not is_readonly_ui_review:
        report_ticket_token = report.get("ticket_token")
        report_ticket_digest = report.get("ticket_digest")
        if not report_ticket_token:
            raise SystemExit(
                "review report must include ticket_token. "
                "Run scripts/issue-review-ticket.sh before dispatching the review."
            )
        # 统一 digest 格式校验：ticket_digest 必须 sha256: + 64 hex
        _validate_digest(report_ticket_digest, "ticket_digest")
        rt = state.get("review_ticket")
        if not rt or not rt.get("token"):
            raise SystemExit(
                "no review_ticket in session state. "
                "Run scripts/issue-review-ticket.sh before dispatching the review."
            )
        if rt.get("consumed"):
            raise SystemExit(
                "review ticket has already been consumed. "
                "Run scripts/issue-review-ticket.sh again to issue a new ticket."
            )
        if rt.get("cancelled"):
            raise SystemExit(
                "review ticket has been cancelled. "
                "Run scripts/issue-review-ticket.sh to issue a new ticket."
            )
        if report_ticket_token != rt.get("token"):
            raise SystemExit(
                "ticket_token mismatch: report token does not match the session's review_ticket."
            )
        # 重算 ticket artifact digest，防篡改
        ticket_path = Path(rt.get("ticket_path") or "")
        if not rt.get("ticket_path") or ticket_path.is_symlink() or not ticket_path.is_file():
            raise SystemExit(
                "review ticket artifact is missing or not a regular file: "
                + str(rt.get("ticket_path"))
            )
        ticket_artifact = json.loads(ticket_path.read_text())
        # 重算 ticket_digest（canonical JSON）
        ticket_canonical = json.dumps(
            {k: ticket_artifact[k] for k in sorted(ticket_artifact) if k != "ticket_digest"},
            sort_keys=True, ensure_ascii=False, separators=(",", ":"),
        )
        actual_ticket_digest = "sha256:" + hashlib.sha256(ticket_canonical.encode("utf-8")).hexdigest()
        if actual_ticket_digest != rt.get("ticket_digest"):
            raise SystemExit(
                "review ticket artifact changed after issue; re-run scripts/issue-review-ticket.sh."
            )
        if report_ticket_digest != rt.get("ticket_digest"):
            raise SystemExit(
                "ticket_digest mismatch: report digest does not match the session's review_ticket."
            )
        # adapter 一致性
        if rt.get("selected_adapter") != bound_adapter:
            raise SystemExit(
                "ticket adapter mismatch: ticket was issued for "
                + str(rt.get("selected_adapter"))
                + " but session is bound to " + str(bound_adapter) + "."
            )
        # config_digest 一致性
        if rt.get("config_digest") != bound_digest:
            raise SystemExit(
                "ticket config_digest mismatch: ticket was issued with a different config_digest."
            )
        # route 一致性（如果报告携带 route）
        if report.get("route") and rt.get("route") and report.get("route") != rt.get("route"):
            raise SystemExit(
                "ticket route mismatch: report route="
                + str(report.get("route"))
                + " but ticket route=" + str(rt.get("route")) + "."
            )

        # ── worktree digest 重算：签发后 tracked/untracked 变化则拒绝 ──
        # fail closed：recompute 失败（非 git / 无 base ref）必须拒绝，不跳过
        # 用 ticket 中固化的 merge_base SHA 重算（防止 branch 移动导致漂移）
        ticket_wt_digest = rt.get("worktree_digest")
        ticket_merge_base = rt.get("merge_base", "")
        if ticket_wt_digest:
            # 统一 digest 格式校验：worktree_digest 必须 sha256: + 64 hex
            _validate_digest(ticket_wt_digest, "review_ticket.worktree_digest")
            project_root = Path(os.environ.get("DEV_FLOW_PROJECT_ROOT", state_path.parent.parent))
            wt_args = [
                "/usr/bin/python3", str(devflow_root / "scripts" / "lib" / "worktree_digest.py"),
                str(project_root),
            ]
            # 传入 merge_base override 防止 branch 漂移
            if ticket_merge_base:
                wt_args.append("")  # base_ref override 为空
                wt_args.append(ticket_merge_base)  # merge_base override
            wt_result = subprocess.run(wt_args, capture_output=True, text=True)
            if wt_result.returncode != 0:
                raise SystemExit(
                    "failed to recompute worktree digest: "
                    + wt_result.stderr.strip()
                    + ". The project must be a git repository with a resolvable base ref "
                    "(main/master/origin/main or DEV_FLOW_REVIEW_BASE). "
                    "Re-run scripts/issue-review-ticket.sh after ensuring git is initialized."
                )
            current_wt = json.loads(wt_result.stdout)
            if current_wt["worktree_digest"] != ticket_wt_digest:
                raise SystemExit(
                    "worktree changed after ticket issue: tracked or untracked files "
                    "were modified since the review ticket was issued. "
                    "Re-run scripts/issue-review-ticket.sh (or run-review-fallback.sh) "
                    "to issue a new ticket with the current worktree state, then re-review."
                )

        # ── result artifact 验证 ──
        # record-gate 只接受受控 result artifact，降低误填风险。
        # 诚实声明：本地完整性门用于防误操作/漂移/重放，降低误填风险；
        # 不是对拥有本机写权限攻击者的密码学证明——攻击者拥有写权限可绕过一切本地校验。
        result_artifact_path = report.get("result_artifact")
        result_artifact_digest = report.get("result_artifact_digest")
        if not result_artifact_path:
            raise SystemExit(
                "review report must include result_artifact. "
                "Use scripts/record-review-result.sh to generate a controlled result artifact."
            )
        # 统一 digest 格式校验：result_artifact_digest 必须 sha256: + 64 hex
        _validate_digest(result_artifact_digest, "result_artifact_digest")
        ra_path = Path(result_artifact_path)
        # 使用统一 safe_read_bytes：沿原始路径逐级 lstat，拒绝任何 symlink；
        # 不可先 resolve 丢失原始组件、不可 ValueError pass。
        # trusted_root = sessions 目录（未 resolve 的 normpath）
        sessions_dir_unresolved = Path(os.path.normpath(str(state_path.parent)))
        ra_data = safe_read_bytes(sessions_dir_unresolved, ra_path)
        # 重算 digest（sha256 重算，防篡改）
        actual_ra_digest = "sha256:" + hashlib.sha256(ra_data).hexdigest()
        if actual_ra_digest != result_artifact_digest:
            raise SystemExit(
                "result_artifact_digest mismatch: file changed or digest is incorrect."
            )
        # 验证 artifact 字段与 report/ticket/selection 逐字段同源
        ra_json = json.loads(ra_data)
        ra_required = ["producer", "session_id", "adapter", "config_digest",
                       "ticket_digest", "route", "worktree_digest", "run_id",
                       "adapter_result_ref", "adapter_result_digest", "status",
                       "reviewer_result"]
        for field in ra_required:
            if field not in ra_json:
                raise SystemExit(f"result_artifact missing required field: {field}")
        # producer 白名单：只接受受控 record-review-result.sh 产出的 producer
        _CONTROLLED_PRODUCERS = {"code-review-workflow"}
        if ra_json["producer"] not in _CONTROLLED_PRODUCERS:
            raise SystemExit(
                "result_artifact producer must be a controlled producer (code-review-workflow); "
                "unknown producer rejected: " + str(ra_json["producer"])
            )
        # producer 严格绑定：artifact.producer 必须与 report.producer 一致
        # code-review-workflow review reports 只接受受控 producer，producer mismatch 拒绝
        if ra_json["producer"] != report.get("producer"):
            raise SystemExit(
                "result_artifact producer does not match report producer: "
                "artifact=" + str(ra_json["producer"])
                + " report=" + str(report.get("producer"))
                + ". Producer mismatch rejected."
            )
        # session_id 绑定
        if ra_json["session_id"] != session_id:
            raise SystemExit("result_artifact session_id does not match current session.")
        # adapter 绑定（== state ticket/selection 的 selected_adapter）
        if ra_json["adapter"] != bound_adapter:
            raise SystemExit("result_artifact adapter does not match session's bound adapter.")
        # config_digest 绑定（== state ticket/selection）
        if ra_json["config_digest"] != bound_digest:
            raise SystemExit("result_artifact config_digest does not match session's config_digest.")
        # ticket_digest 绑定（== state ticket）
        if ra_json["ticket_digest"] != rt.get("ticket_digest"):
            raise SystemExit("result_artifact ticket_digest does not match session's review_ticket.")
        # route 绑定（== state ticket）
        if ra_json["route"] != rt.get("route"):
            raise SystemExit("result_artifact route does not match ticket's route.")
        # worktree_digest 绑定（== state ticket 的 worktree_digest）
        if ra_json["worktree_digest"] != rt.get("worktree_digest"):
            raise SystemExit(
                "result_artifact worktree_digest does not match ticket's worktree_digest."
            )
        # run_id 绑定（artifact.run_id == report.run_id）
        if ra_json["run_id"] != report.get("run_id"):
            raise SystemExit(
                "result_artifact run_id does not match report run_id."
            )
        # status 绑定（artifact.status == report.status）
        if ra_json["status"] != report.get("status"):
            raise SystemExit("result_artifact status does not match report status.")
        # reviewer_result 绑定（artifact.reviewer_result == report.reviewer_result）
        if ra_json["reviewer_result"] != report.get("reviewer_result"):
            raise SystemExit(
                "result_artifact reviewer_result does not match report reviewer_result."
            )
        # adapter_result_ref 绑定（artifact == report，同源校验）
        if ra_json.get("adapter_result_ref") != report.get("adapter_result_ref"):
            raise SystemExit(
                "result_artifact adapter_result_ref does not match report adapter_result_ref."
            )
        # adapter_result_digest 绑定（artifact == report，同源校验）
        if ra_json.get("adapter_result_digest") != report.get("adapter_result_digest"):
            raise SystemExit(
                "result_artifact adapter_result_digest does not match report adapter_result_digest."
            )
        # 统一 digest 格式校验：adapter_result_digest 必须 sha256: + 64 hex
        # 同时覆盖 artifact 和 report 两个来源
        _validate_digest(ra_json.get("adapter_result_digest"), "result_artifact.adapter_result_digest")
        _validate_digest(report.get("adapter_result_digest"), "report.adapter_result_digest")
        # adapter_result_ref 非空校验（降低误填风险）
        if not report.get("adapter_result_ref"):
            raise SystemExit(
                "review report must include adapter_result_ref "
                "(host task id / orchestrator run id / gstack packet-run ref)."
            )
        # findings 一致性（如果 artifact 有 findings，report 必须有相同 findings）
        ra_findings = ra_json.get("findings")
        report_findings = report.get("findings")
        if ra_findings is not None:
            if ra_findings != report_findings:
                raise SystemExit(
                    "result_artifact findings do not match report findings."
                )

status = report.get("status")
allowed = {
    "figma_ui": {"pass", "failed", "blocked"},
    "review": {"pass", "revise", "blocked"},
    "runtime": {"runtime-verified", "runtime-failed", "runtime-blocked"},
    "ui_parity": {"accepted", "findings-open", "blocked"},
}
if status not in allowed[gate_name]:
    raise SystemExit(f"Invalid {gate_name} status: {status}")

# review gate: status 与 reviewer_result 必须一致
if gate_name == "review":
    reviewer_result = report.get("reviewer_result")
    expected_result = {"pass": "pass", "revise": "revise", "blocked": "blocked"}.get(status)
    if reviewer_result != expected_result:
        raise SystemExit(f"review status={status} requires reviewer_result={expected_result} (got {reviewer_result!r})")

def run_ui_review_validator(artifact_workspace, stage):
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit(f"ui_review {gate_name} report requires artifact_workspace.")
    workspace = Path(artifact_workspace).expanduser().resolve()
    validator = devflow_root / "scripts" / "validate-ui-review-artifacts.py"
    if not workspace.is_dir() or not validator.is_file():
        raise SystemExit("ui_review artifact workspace or validator is missing.")
    completed = subprocess.run(
        [
            "/usr/bin/python3",
            str(validator),
            "--workspace",
            str(workspace),
            "--stage",
            stage,
            "--session-id",
            session_id,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ui_review validator returned invalid output: {exc}") from exc
    if completed.returncode != 0 or payload.get("status") != "pass":
        errors = payload.get("errors") or ["validator execution failed"]
        raise SystemExit("ui_review artifact validation failed: " + "; ".join(errors))
    return workspace, payload

if not state.get("confirmed_at"):
    if not (
        report.get("producer") == "ui-review"
        and report.get("schema_version") == 1
        and report.get("route") == "ui-review-read-only"
        and report.get("source_edits") is False
        and status == "pass"
    ):
        raise SystemExit(
            "Unconfirmed ui_review may record only a ui-review-read-only pass with source_edits=false."
        )
    workspace_path, _ = run_ui_review_validator(report.get("artifact_workspace"), "parity")
    validation_report = report.get("artifact_validation_report")
    if not isinstance(validation_report, str) or not validation_report.strip():
        raise SystemExit("Read-only ui_review requires artifact_validation_report.")
    validation_path = Path(validation_report).expanduser().resolve()
    try:
        validation_path.relative_to(workspace_path)
    except ValueError:
        raise SystemExit("Read-only artifact_validation_report must be inside artifact_workspace.")
    if not validation_path.is_file():
        raise SystemExit("Read-only artifact_validation_report does not exist.")

if (
    gate_name == "review"
    and status == "pass"
    and state.get("type") == "ui_review"
    and state.get("confirmed_at")
):
    if not (
        report.get("producer") == "code-review-workflow"
        and report.get("schema_version") == 1
        and report.get("route") == "ui-parity-review"
        and report.get("source_edits") is True
        and report.get("reviewer_result") == "pass"
        and isinstance(report.get("run_id"), str)
        and report.get("run_id").strip()
        and isinstance(report.get("diff_evidence"), str)
        and report.get("diff_evidence").strip()
    ):
        raise SystemExit(
            "Repaired ui_review review=pass requires a passing ui-parity-review result with run id and diff evidence."
        )
    review_workspace, _ = run_ui_review_validator(report.get("artifact_workspace"), "repair")
    expected_review_paths = {
        "baseline_report": review_workspace / "parity-result.baseline.json",
        "parity_confirmed_report": review_workspace / "parity-confirmed.json",
        "repair_accepted_report": review_workspace / "repair-accepted.json",
    }
    for field, expected_path in expected_review_paths.items():
        raw = report.get(field)
        if not isinstance(raw, str) or not raw.strip():
            raise SystemExit(f"ui-parity-review report requires {field}.")
        candidate = Path(raw).expanduser().resolve()
        try:
            candidate.relative_to(review_workspace)
        except ValueError:
            raise SystemExit(f"{field} must be inside artifact_workspace.")
        if not candidate.is_file():
            raise SystemExit(f"{field} does not exist.")
        if candidate != expected_path:
            raise SystemExit(f"{field} does not point to the canonical ui-review artifact.")

if gate_name == "runtime" and status == "runtime-verified" and state.get("type") == "ui_review":
    if report.get("producer") != "runtime-debug-workflow" or report.get("schema_version") != 1:
        raise SystemExit(
            "ui_review runtime-verified requires producer=runtime-debug-workflow and schema_version=1."
        )
    runtime_workspace_raw = report.get("artifact_workspace")
    if not isinstance(runtime_workspace_raw, str) or not runtime_workspace_raw.strip():
        raise SystemExit("ui_review runtime-verified requires artifact_workspace.")
    runtime_workspace = Path(runtime_workspace_raw).expanduser().resolve()
    confirmed_report = report.get("parity_confirmed_report")
    if not isinstance(confirmed_report, str) or not confirmed_report.strip():
        raise SystemExit("ui_review runtime-verified requires parity_confirmed_report.")
    confirmed_path = Path(confirmed_report).expanduser().resolve()
    if not confirmed_path.is_file() or confirmed_path != runtime_workspace / "parity-confirmed.json":
        raise SystemExit("ui_review runtime parity_confirmed_report does not exist.")
    confirmed_payload = json.loads(confirmed_path.read_text())
    if confirmed_payload.get("session_id") != session_id:
        raise SystemExit("ui_review runtime parity_confirmed_report belongs to another session.")
    if confirmed_payload.get("artifact_workspace") != str(runtime_workspace):
        raise SystemExit("ui_review runtime artifact workspace mismatch.")

    def runtime_ids(value, field):
        if not isinstance(value, list):
            raise SystemExit(f"{field} must be an array.")
        result = set()
        for item in value:
            current = item if isinstance(item, str) else item.get("figma_id") if isinstance(item, dict) else None
            if not isinstance(current, str) or not current.strip() or current in result:
                raise SystemExit(f"{field} contains an invalid or duplicate id.")
            result.add(current)
        return result

    authorized_ids = runtime_ids(confirmed_payload.get("units_to_fix", []), "units_to_fix")
    authorized_ids |= runtime_ids(
        confirmed_payload.get("runtime_extras_to_remove", []), "runtime_extras_to_remove"
    )
    verified_ids = runtime_ids(report.get("verified_ids", []), "verified_ids")
    if not authorized_ids or verified_ids != authorized_ids:
        raise SystemExit("ui_review runtime verified_ids must equal the authorized repair set.")
    evidence_paths = report.get("debugbridge_evidence")
    if not isinstance(evidence_paths, list) or not evidence_paths or any(
        not isinstance(item, str) or not item.strip() for item in evidence_paths
    ):
        raise SystemExit("ui_review runtime-verified requires bounded DebugBridge evidence paths.")

if gate_name == "ui_parity" and status == "accepted":
    if report.get("producer") != "ui-review" or report.get("schema_version") != 1:
        raise SystemExit("ui_parity=accepted requires producer=ui-review and schema_version=1.")
    artifact_workspace = report.get("artifact_workspace")
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit("ui_parity=accepted requires artifact_workspace.")
    workspace_path = Path(artifact_workspace).expanduser().resolve()
    if not workspace_path.is_dir():
        raise SystemExit("ui_parity artifact_workspace must exist.")
    _, fresh_validation = run_ui_review_validator(artifact_workspace, "all")

    def bounded_report_path(raw, field):
        if not isinstance(raw, str) or not raw.strip():
            raise SystemExit(f"ui_parity=accepted requires {field} path.")
        candidate = Path(raw).expanduser().resolve()
        try:
            candidate.relative_to(workspace_path)
        except ValueError:
            raise SystemExit(f"{field} must be inside artifact_workspace.")
        if not candidate.is_file():
            raise SystemExit(f"{field} file does not exist.")
        return candidate

    confirmed_path = bounded_report_path(
        report.get("parity_confirmed_report"), "parity_confirmed_report"
    )
    validation_path = bounded_report_path(
        report.get("artifact_validation_report"), "artifact_validation_report"
    )
    accepted_report = report.get("repair_accepted_report")
    accepted_path = bounded_report_path(accepted_report, "repair_accepted_report")
    if confirmed_path != workspace_path / "parity-confirmed.json":
        raise SystemExit("parity_confirmed_report must point to canonical parity-confirmed.json.")
    if accepted_path != workspace_path / "repair-accepted.json":
        raise SystemExit("repair_accepted_report must point to canonical repair-accepted.json.")
    try:
        validation_payload = json.loads(validation_path.read_text())
        confirmed_payload = json.loads(confirmed_path.read_text())
        accepted_payload = json.loads(accepted_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid ui_parity evidence JSON: {exc}") from exc
    if confirmed_payload.get("session_id") != session_id:
        raise SystemExit("parity_confirmed_report belongs to another session.")
    if not (
        validation_payload.get("producer") == "validate-ui-review-artifacts"
        and validation_payload.get("schema_version") == 1
        and validation_payload.get("session_id") == session_id
        and validation_payload.get("artifact_workspace") == artifact_workspace
        and validation_payload.get("stage") == "all"
        and validation_payload.get("status") == "pass"
        and validation_payload.get("errors") == []
        and validation_payload.get("minimum_unit_count")
        == fresh_validation.get("minimum_unit_count")
    ):
        raise SystemExit("ui_parity requires a passing current-session all-stage artifact validation.")
    if accepted_payload.get("session_id") != session_id:
        raise SystemExit("repair_accepted_report belongs to another session.")
    if confirmed_payload.get("artifact_workspace") != artifact_workspace:
        raise SystemExit("parity_confirmed_report artifact_workspace mismatch.")
    if accepted_payload.get("artifact_workspace") != artifact_workspace:
        raise SystemExit("repair_accepted_report artifact_workspace mismatch.")
    if confirmed_payload.get("may_proceed_to_fix") is not True:
        raise SystemExit("parity_confirmed_report must set may_proceed_to_fix=true.")
    # 人工批准 token 外部化：confirm 阶段必须由 human-approve.sh 生成匹配 token
    tokens = state.get("human_approval_tokens") or {}
    confirm_token = tokens.get("confirm")
    if not confirm_token or confirmed_payload.get("approval_token") != confirm_token:
        raise SystemExit("parity_confirmed_report requires a matching human approval token (run scripts/human-approve.sh approve --stage confirm)")
    # digest 绑定：批准时 artifact 的 sha256 必须与当前 parity_confirmed_report 一致，
    # 防止 agent 在人工批准后篡改 artifact 内容再回填 token
    digests = state.get("human_approval_digests") or {}
    confirm_digest = digests.get("confirm")
    if not confirm_digest or sha256_of(confirmed_path) != confirm_digest:
        raise SystemExit("parity_confirmed_report digest does not match the approved artifact (content changed after human approval)")
    if accepted_payload.get("confirmed_by") != "human":
        raise SystemExit("repair_accepted_report requires confirmed_by=human.")
    if accepted_payload.get("all_authorized_repairs_resolved") is not True:
        raise SystemExit(
            "ui_parity=accepted requires all_authorized_repairs_resolved=true in repair_accepted_report."
        )
    # accept 阶段同样需要匹配的人工批准 token
    accept_token = tokens.get("accept")
    if not accept_token or accepted_payload.get("approval_token") != accept_token:
        raise SystemExit("repair_accepted_report requires a matching human approval token (run scripts/human-approve.sh approve --stage accept)")
    # accept 阶段同样校验 digest：repair_accepted_report 内容必须与批准时一致
    accept_digest = digests.get("accept")
    if not accept_digest or sha256_of(accepted_path) != accept_digest:
        raise SystemExit("repair_accepted_report digest does not match the approved artifact (content changed after human approval)")

    def id_set(value, field):
        if not isinstance(value, list):
            raise SystemExit(f"{field} must be an array.")
        result = set()
        for item in value:
            current = item if isinstance(item, str) else item.get("figma_id") if isinstance(item, dict) else None
            if not isinstance(current, str) or not current.strip() or current in result:
                raise SystemExit(f"{field} contains an invalid or duplicate id.")
            result.add(current)
        return result

    authorized = id_set(confirmed_payload.get("units_to_fix", []), "units_to_fix")
    authorized |= id_set(
        confirmed_payload.get("runtime_extras_to_remove", []), "runtime_extras_to_remove"
    )
    accepted = id_set(accepted_payload.get("units_accepted", []), "units_accepted")
    reverted = id_set(accepted_payload.get("units_reverted", []), "units_reverted")
    rework = id_set(accepted_payload.get("units_rework", []), "units_rework")
    if not authorized:
        raise SystemExit("ui_parity=accepted requires a non-empty authorized repair set.")
    if accepted & reverted or rework:
        raise SystemExit("ui_parity=accepted requires disjoint accepted/reverted ids and no rework.")
    if accepted | reverted != authorized:
        raise SystemExit("Accepted plus reverted ids must exactly equal the authorized repair set.")

    def validate_verification_map(field, ids, expected_result):
        mapping = accepted_payload.get(field)
        if not isinstance(mapping, dict) or set(mapping) != ids:
            raise SystemExit(f"{field} keys must exactly match their disposition ids.")
        for item_id, raw_path in mapping.items():
            verify_path = bounded_report_path(raw_path, f"{field}[{item_id}]")
            try:
                payload = json.loads(verify_path.read_text())
            except json.JSONDecodeError as exc:
                raise SystemExit(f"Invalid verification JSON for {item_id}: {exc}") from exc
            if payload.get("session_id") != session_id or payload.get("figma_id") != item_id:
                raise SystemExit(f"Verification report identity mismatch for {item_id}.")
            if payload.get("result") != expected_result:
                raise SystemExit(f"Verification report result mismatch for {item_id}.")
            if expected_result == "ok" and payload.get("mark_after") != "ok":
                raise SystemExit(f"Accepted repair must have mark_after=ok for {item_id}.")
            if not payload.get("debugbridge_evidence"):
                raise SystemExit(f"Verification report lacks DebugBridge evidence for {item_id}.")

    validate_verification_map("verification_reports", accepted, "ok")
    validate_verification_map("revert_verification_reports", reverted, "reverted")

if gate_name == "figma_ui" and status == "pass":
    gates = report.get("gates")
    expected = ["preflight", "G0", "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G6V", "G7A", "G7B", "G9", "G10", "G11", "G12"]
    if not isinstance(gates, dict) or any(gates.get(name) != "pass" for name in expected):
        raise SystemExit("figma_ui=pass requires the full figma-ui-gates sequence to pass, including preflight and G6V.")
    artifact_workspace = report.get("artifact_workspace")
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit("figma_ui=pass requires artifact_workspace.")
    source_root = report.get("source_root")
    if not isinstance(source_root, str) or not source_root.strip():
        raise SystemExit("figma_ui=pass requires source_root.")
    g6v_validation = report.get("g6v_validation")
    if g6v_validation != "pass":
        raise SystemExit("figma_ui=pass requires g6v_validation=pass.")
    g6v_report = report.get("g6v_validation_report")
    if not isinstance(g6v_report, str) or not g6v_report.strip():
        raise SystemExit("figma_ui=pass requires g6v_validation_report path.")
    g6v_report_path = Path(g6v_report).expanduser().resolve()
    try:
        g6v_report_path.relative_to(Path(artifact_workspace).expanduser().resolve())
    except ValueError:
        raise SystemExit("g6v_validation_report must be inside artifact_workspace.")
    if not g6v_report_path.is_file():
        raise SystemExit("figma_ui=pass requires an existing g6v_validation_report file.")
    try:
        g6v_payload = json.loads(g6v_report_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid g6v_validation_report JSON: {exc}") from exc
    if g6v_payload.get("status") != "pass":
        raise SystemExit("figma_ui=pass requires g6v_validation_report status=pass.")

evidence = report.get("evidence")
if not isinstance(evidence, str) or not evidence.strip():
    raise SystemExit("Gate report requires bounded evidence text.")
state.setdefault("gate_results", {})[gate_name] = {
    "status": status,
    "evidence": evidence[:1000],
    "recorded_at": recorded_at,
    "report": str(report_path),
}
# fallback 会话 review pass 后销毁一次性 token（revise/blocked 保留，允许同 packet 重录）
if gate_name == "review" and status == "pass" and state.get("review_fallback"):
    state["review_fallback"] = None
# 统一 ticket：review pass 后原子标记 consumed，禁止复用
# （revise/blocked 不消费 ticket，允许同 ticket 重录或换新 ticket）
if gate_name == "review" and status == "pass" and state.get("review_ticket"):
    state["review_ticket"]["consumed"] = True
# review selection 锁定：一旦 review 报告被记录（任何 status），锁定 review_selection，
# 防止后续 re-run env-health 改变 selection 后用不同 adapter 的结果"洗"过门禁。
if gate_name == "review" and state.get("review_selection"):
    state["review_selection"]["locked"] = True
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
PY
}

# validate-trivial：对暂存区做严格范围校验，记录 HEAD/index-tree/path-mode-type/content
# digest 与校验结果到 state.trivial_validation。超界标记 requires-standard/heavy 并冻结，
# 不原地转换、不继承证据；approve/commit 前重算 digest，漂移拒绝。
validate_trivial() {
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
project_root = Path(sys.argv[4])
trusted_root = Path(sys.argv[5])
source_root = sys.argv[6]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json
from trivial_session import resolve_required_gates
from trivial_scope_validator import validate

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
# 一致性交叉校验：只有合法 trivial（schema2+level+fast_path+kind+空 gates 配套）才允许
# validate-trivial；自相矛盾（如 level=trivial 但 required_gates!=[]、fast_path=True 但
# level=standard）→ resolve fail closed，不原地转 standard/heavy，不继承证据。
_, is_trivial = resolve_required_gates(state)
if not is_trivial:
    raise SystemExit("validate-trivial is only for legitimately trivial fast-path sessions; re-open as standard/heavy.")
if not state.get("confirmed_at"):
    raise SystemExit("Plan is not confirmed. Run confirm-plan first.")

# 冻结态拒绝重新 validate（不原地转换、不继承证据）
existing = state.get("trivial_validation") or {}
if existing.get("escalation") in ("requires-standard", "requires-heavy"):
    raise SystemExit(
        f"session is frozen ({existing['escalation']}); re-open as standard/heavy. "
        "Evidence is not inherited."
    )

trivial = state.get("trivial") or {}
kind = trivial.get("kind")
params = trivial.get("params") or {}

result = validate(str(project_root), kind, params)
result["validated_at"] = timestamp
state["trivial_validation"] = result
# 每次 validate-trivial（无论成功/失败/重跑）都清除旧 commit approval（issue #3）：
# 防止「validate A → approve → stage B → revalidate B → commit」用旧 approval 提交 B。
# 语义：每次 validate 后必须重新 approve。失败 validation 同样清除，不保留旧 approval。
state["commit_approved_at"] = None
state["approved_scope"] = None
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
if result["result"] != "pass":
    esc = result.get("escalation") or ""
    print(
        f"validate-trivial: {result['result']} ({esc}): {result['reason']}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

# commit：收口提交动作。approve-commit 已批 → 校验暂存区 → git commit → 记录 hash。
# 提交后重置 testflight 状态（新 commit 使旧构建证据失效）。
record_commit() {
  local message="$1"
  mkdir -p "$STATE_DIR"
  DEV_FLOW_COMMIT_MESSAGE="$message" /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
project_root = Path(sys.argv[4])
trusted_root = sys.argv[5]
source_root = sys.argv[6]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json
from trivial_session import resolve_required_gates
# message 原样传给 git commit（不 strip），仅做非空与长度校验（≤200，与 state 规格一致），
# 保证 state 记录值与实际提交完全一致
message = os.environ.get("DEV_FLOW_COMMIT_MESSAGE", "")
if not message.strip():
    raise SystemExit("commit requires a non-empty --message")
if len(message) > 200:
    raise SystemExit(f"commit message too long ({len(message)} chars > 200)")

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
if not state.get("commit_approved_at"):
    raise SystemExit("Commit is not approved. Run approve-commit first.")

# 一致性交叉校验：合法 trivial 才走 fast-path 绑定校验；非 trivial 显式空 gates /
# 字段自相矛盾 → resolve fail closed（深度防御，approve 已先行校验）。
_, is_trivial = resolve_required_gates(state)

if is_trivial:
    # trivial fast-path commit 绑定：HEAD + index tree + 文件元数据/content digest
    tv = state.get("trivial_validation") or {}
    # 冻结态禁止 commit
    if tv.get("escalation") in ("requires-standard", "requires-heavy"):
        raise SystemExit(f"session is frozen ({tv['escalation']}); re-open as standard/heavy.")
    # commit-blocked 禁止重复 commit（不自动 reset/revert）
    if state.get("commit_blocked"):
        raise SystemExit(
            "session is in commit-blocked state; resolve the blocked commit manually "
            "(see state.commit_blocked) before re-running commit"
        )
    if tv.get("result") != "pass":
        raise SystemExit("Trivial fast-path requires validate-trivial to pass before commit.")
    # commit 前重算 digest，漂移拒绝；同时校验工作树仍干净
    from trivial_scope_validator import compute_digest_only, check_clean_worktree
    clean_ok, clean_reason = check_clean_worktree(str(project_root))
    if not clean_ok:
        raise SystemExit("Worktree not clean before commit: " + clean_reason)
    current = compute_digest_only(str(project_root))
    # 三方比对（issue #3）：current == trivial_validation == approved_scope 必须一致。
    # 防止「validate A → approve → stage B → revalidate B → commit」用旧 approval 提交 B。
    if current.get("scope_digest") != tv.get("scope_digest"):
        raise SystemExit(
            "Trivial scope digest drifted since validate-trivial; re-run validate-trivial then approve-commit."
        )
    if current.get("head") != tv.get("head") or current.get("index_tree") != tv.get("index_tree"):
        raise SystemExit(
            "Trivial staged state drifted since validate-trivial; re-run validate-trivial then approve-commit."
        )
    approved_scope = state.get("approved_scope")
    if not approved_scope:
        raise SystemExit(
            "Trivial fast-path has no approved_scope binding; re-run validate-trivial then approve-commit."
        )
    if approved_scope.get("scope_digest") != tv.get("scope_digest"):
        raise SystemExit(
            "Approved scope digest does not match trivial_validation; re-run validate-trivial then approve-commit."
        )
    if approved_scope.get("head") != tv.get("head") or approved_scope.get("index_tree") != tv.get("index_tree"):
        raise SystemExit(
            "Approved scope head/index_tree does not match trivial_validation; re-run validate-trivial then approve-commit."
        )
    # 记录期望值：commit 前的 HEAD 作为新 commit 的 expected parent，index tree 作为 expected tree
    expected_parent = current["head"]
    expected_tree = current["index_tree"]

def run_git(args):
    # 小输出命令（rev-parse/diff --quiet）才用 capture_output
    try:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(project_root)] + args,
            capture_output=True, text=True, check=False, timeout=120,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit("git command timed out (120s)")

def run_git_streamed(args):
    # git commit 可能被 hook 输出大量日志：流式写临时文件，只读尾部，避免内存耗尽
    out = tempfile.TemporaryFile()
    try:
        try:
            completed = subprocess.run(
                ["/usr/bin/git", "-C", str(project_root)] + args,
                stdout=out, stderr=subprocess.STDOUT, check=False, timeout=120,
            )
        except subprocess.TimeoutExpired:
            raise SystemExit("git commit timed out (120s)")
        out.seek(0, 2)
        size = out.tell()
        out.seek(max(0, size - 4096))
        tail = out.read().decode("utf-8", errors="replace").strip()[-1000:]
        return completed.returncode, tail
    finally:
        out.close()

if run_git(["rev-parse", "--is-inside-work-tree"]).returncode != 0:
    raise SystemExit(f"project root is not a git repository: {project_root}")
# 必须有暂存改动：commit 收口的是"已审批的实现"，空暂存区说明 AI 未完成 git add
staged = run_git(["diff", "--cached", "--quiet"])
if staged.returncode == 0:
    raise SystemExit("No staged changes. Run git add first (commit gate does not auto-stage).")
if staged.returncode != 1:
    raise SystemExit("git staged-check failed: " + (staged.stderr or "").strip()[-500:])

commit_rc, commit_tail = run_git_streamed(["commit", "-m", message])
if commit_rc != 0:
    raise SystemExit("git commit failed: " + commit_tail)
head = run_git(["rev-parse", "HEAD"])
commit_hash = head.stdout.strip()
if not commit_hash:
    raise SystemExit("git commit succeeded but HEAD is unreadable")

# trivial fast-path：commit hook 可能改写 tree 或插入意外 parent。
# 校验新 commit 的 parent == commit 前的 HEAD、新 commit 的 tree == commit 前 index tree。
# 不符则记录 commit-blocked（实际 hash/parent/tree 和期望值），不自动 reset/revert，禁止重复 commit。
if is_trivial:
    actual_parent = run_git(["rev-parse", "HEAD^"]).stdout.strip()
    actual_tree = run_git(["rev-parse", "HEAD^{tree}"]).stdout.strip()
    if actual_parent != expected_parent or actual_tree != expected_tree:
        state["commit_blocked"] = {
            "commit_hash": commit_hash,
            "expected_parent": expected_parent,
            "actual_parent": actual_parent,
            "expected_tree": expected_tree,
            "actual_tree": actual_tree,
            "blocked_at": timestamp,
            "reason": "post-commit parent/tree mismatch (hook may have rewritten the commit)",
        }
        state["session_id"] = session_id
        safe_atomic_write_json(trusted_root, state_path, state)
        raise SystemExit(
            f"commit-blocked: actual parent/tree does not match expected "
            f"(parent {actual_parent[:12]} vs {expected_parent[:12]}, "
            f"tree {actual_tree[:12]} vs {expected_tree[:12]}); "
            "resolve manually, do not re-run commit"
        )

# git 会规范化提交信息（去首尾空白/空行等），state 必须记录实际提交内容而非入口输入
msg_result = run_git(["log", "-1", "--pretty=%B"])
if msg_result.returncode != 0:
    raise SystemExit("git commit succeeded but its message is unreadable")
actual_msg = msg_result.stdout.strip()
if len(actual_msg) > 200:
    # commit hook 改写后超 200：拒绝静默截断。恢复：git reset --soft HEAD~1 后缩短 message 重跑 commit
    raise SystemExit(
        f"commit message after git normalization exceeds 200 chars ({len(actual_msg)}); "
        "reset --soft HEAD~1 and re-run commit with a shorter message"
    )

state["committed_at"] = timestamp
state["commit_hash"] = commit_hash
state["commit_message"] = actual_msg
# 新 commit 使旧 TestFlight 构建证据失效，重置为未上传
state["testflight"] = {"status": "not-run", "uploaded_at": None, "evidence": None, "command_source": None}
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
print(f"committed: {commit_hash}")
PY
}

# testflight：门禁 + 委托项目 fastlane。校验 commit 完成且 HEAD 未漂移 →
# 执行 <项目>/.dev-flow/testflight-command（或测试模式 DEV_FLOW_TESTFLIGHT_CMD）→ 登记证据。
record_testflight() {
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT" "$ROOT/.dev-flow" "$SOURCE_ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
project_root = Path(sys.argv[4])
trusted_root = sys.argv[5]
source_root = sys.argv[6]
sys.path.insert(0, os.path.join(source_root, 'scripts', 'lib'))
from atomic_json_write import safe_atomic_write_json

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
commit_hash = state.get("commit_hash")
if not state.get("committed_at") or not commit_hash:
    raise SystemExit("No commit recorded. Run dev-flow-session.sh commit first.")

try:
    head = subprocess.run(
        ["/usr/bin/git", "-C", str(project_root), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=False, timeout=30,
    )
except subprocess.TimeoutExpired:
    raise SystemExit("git rev-parse HEAD timed out")
if head.returncode != 0 or head.stdout.strip() != commit_hash:
    raise SystemExit(
        f"HEAD has drifted from the approved commit ({commit_hash}). "
        "Re-run dev-flow-session.sh commit before testflight."
    )

# 命令来源：生产仅认 <项目>/.dev-flow/testflight-command；
# DEV_FLOW_TESTFLIGHT_CMD 覆盖仅 DEV_FLOW_TEST_MODE=1 生效（对齐探针覆盖防伪造模式）
test_mode = os.environ.get("DEV_FLOW_TEST_MODE") == "1"
env_cmd = os.environ.get("DEV_FLOW_TESTFLIGHT_CMD", "").strip()
command = ""
source = ""
if env_cmd and test_mode:
    command, source = env_cmd, "env"
else:
    if env_cmd and not test_mode:
        print("warning: ignoring DEV_FLOW_TESTFLIGHT_CMD (set DEV_FLOW_TEST_MODE=1 to use it)", file=sys.stderr)
    cmd_file = project_root / ".dev-flow" / "testflight-command"
    if cmd_file.is_symlink():
        raise SystemExit(f"refusing to read symlinked testflight command file: {cmd_file}")
    if cmd_file.is_file():
        command = cmd_file.read_text().strip()
        source = "file"
if not command:
    raise SystemExit(
        "testflight command not configured. Write the project fastlane command into "
        f"{project_root / '.dev-flow' / 'testflight-command'} "
        "(e.g. 'bundle exec fastlane beta'), then re-run."
    )

# timeout 显式校验：正整数且不超过 86400s，非法值给规范化错误而非 traceback
raw_timeout = os.environ.get("DEV_FLOW_TESTFLIGHT_TIMEOUT", "3600").strip()
try:
    timeout = int(raw_timeout)
except ValueError:
    raise SystemExit(f"DEV_FLOW_TESTFLIGHT_TIMEOUT must be a positive integer (got {raw_timeout!r})")
if timeout < 1 or timeout > 86400:
    raise SystemExit(f"DEV_FLOW_TESTFLIGHT_TIMEOUT out of range 1..86400 (got {timeout})")

# 项目命令可产生任意大输出：流式写临时文件只读尾部，避免 capture_output 内存耗尽。
# 独立进程组启动 + 进程组排水：bash 退出不代表结束——`sleep 5 &` 这类后台脱离命令
# 会让 bash 立即退 0 但子进程残留，必须等整组清空；超时 killpg 终止整个进程组。
import signal
import time

def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

timed_out = False
proc_rc = None
out = tempfile.TemporaryFile()
try:
    proc = subprocess.Popen(
        ["/bin/bash", "-c", command],
        cwd=str(project_root), stdout=out, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    deadline = time.monotonic() + timeout
    while True:
        proc_rc = proc.poll()
        if proc_rc is not None and not _group_alive(proc.pid):
            break  # bash 与整个进程组都已退出，命令才算真正结束
        if time.monotonic() >= deadline:
            timed_out = True
            break
        time.sleep(0.05)
    if timed_out:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait()
    ok = (proc_rc == 0 and not timed_out)
    out.seek(0, 2)
    size = out.tell()
    out.seek(max(0, size - 4096))
    output_tail = out.read().decode("utf-8", errors="replace").strip()[-1000:]
finally:
    out.close()
if timed_out:
    output_tail = (f"testflight command timed out after {timeout}s; tail: " + output_tail)[-1000:]

state["testflight"] = {
    "status": "uploaded" if ok else "failed",
    "uploaded_at": timestamp if ok else None,
    "evidence": output_tail,
    "command_source": source,
}
state["session_id"] = session_id
safe_atomic_write_json(trusted_root, state_path, state)
print(state_path)
if not ok:
    raise SystemExit("testflight command failed: " + output_tail[-500:])
print("testflight: uploaded")
PY
}

parse_environment_args() {
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report)
        REPORT_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "environment-health requires an existing --report path" >&2
    exit 2
  fi
}

parse_gate_config_args() {
  REQUIRED_GATES=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --required)
        REQUIRED_GATES="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$REQUIRED_GATES" ]]; then
    echo "configure-gates requires --required" >&2
    exit 2
  fi
}

parse_commit_args() {
  COMMIT_MESSAGE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message|-m)
        COMMIT_MESSAGE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$COMMIT_MESSAGE" ]]; then
    echo "commit requires --message" >&2
    exit 2
  fi
}

parse_gate_record_args() {
  GATE_NAME=""
  REPORT_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        GATE_NAME="${2:-}"
        shift 2
        ;;
      --report)
        REPORT_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$GATE_NAME" || -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
    echo "record-gate requires --name and an existing --report path" >&2
    exit 2
  fi
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  start)
    parse_common_args "$@"
    if [[ "$SESSION_TYPE" != "bug" && "$SESSION_TYPE" != "feature" && "$SESSION_TYPE" != "ui_review" ]]; then
      echo "start requires --type bug|feature|ui_review" >&2
      exit 2
    fi
    # --level 缺值拒绝（空字符串）；--level 用于描述任务复杂度并决定是否走 trivial fast-path
    if [[ -z "$SESSION_LEVEL" ]]; then
      echo "start --level requires a value (trivial|standard|heavy)" >&2
      exit 2
    fi
    # trivial fast-path 参数约束（shell 侧显式校验，Python 侧深度防御）
    PARAMS_JSON=""
    if [[ "$SESSION_LEVEL" == "trivial" ]]; then
      if [[ -z "$TRIVIAL_KIND" ]]; then
        echo "start --level trivial requires --trivial-kind docs|pod-patch" >&2
        exit 2
      fi
      if [[ "$TRIVIAL_KIND" != "docs" && "$TRIVIAL_KIND" != "pod-patch" ]]; then
        echo "start --trivial-kind requires docs|pod-patch" >&2
        exit 2
      fi
      if [[ "$TRIVIAL_KIND" == "pod-patch" ]]; then
        if [[ -z "$POD_DEPENDENCY" || -z "$FROM_VERSION" || -z "$TO_VERSION" ]]; then
          echo "start --trivial-kind pod-patch requires --dependency NAME --from-version x.y.z --to-version x.y.z" >&2
          exit 2
        fi
        PARAMS_JSON="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"dependency":sys.argv[1],"from_version":sys.argv[2],"to_version":sys.argv[3]}))' "$POD_DEPENDENCY" "$FROM_VERSION" "$TO_VERSION")"
      fi
    else
      if [[ -n "$TRIVIAL_KIND" ]]; then
        echo "--trivial-kind is only valid with --level trivial" >&2
        exit 2
      fi
    fi
    # 双层规则机制第 1 层：start 硬读。全局规则缺失直接失败；项目规则缺失则建空模板
    if [[ ! -f "$DEV_FLOW_GLOBAL_RULES_FILE" ]]; then
      echo "全局规则文件缺失: $DEV_FLOW_GLOBAL_RULES_FILE" >&2
      exit 1
    fi
    dev_flow_rules_ensure_project_file
    rm -f "$STATE_DIR/$SESSION_ID.app-launch.json"
    write_state "start" "$SESSION_TYPE" "$TASK" "review" "" "$SESSION_LEVEL" "$TRIVIAL_KIND" "$PARAMS_JSON"
    dev_flow_rules_print "GLOBAL RULES" "$DEV_FLOW_GLOBAL_RULES_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  configure-gates)
    parse_gate_config_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    write_state "configure-gates" "" "" "$REQUIRED_GATES" "" "" "" ""
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  environment-health)
    parse_environment_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    record_environment "$REPORT_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  record-gate)
    parse_gate_record_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_verify_environment_health "$STATE_FILE"
    record_gate "$GATE_NAME" "$REPORT_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  confirm-plan)
    parse_common_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    # requirements index.json 在业务项目根（$ROOT），不是 devflow 仓库根（$SOURCE_ROOT）
    write_state "confirm-plan" "" "$TASK" "" "$ROOT" "" "" ""
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  validate-trivial)
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_verify_environment_health "$STATE_FILE"
    validate_trivial
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  approve-commit)
    parse_common_args "$@"
    # 双层规则机制第 3 层：commit 闭环，全局+项目规则 hash 都必须仍一致
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_rules_verify_global_fresh "$STATE_FILE"
    dev_flow_verify_environment_health "$STATE_FILE"
    write_state "approve-commit" "" "$TASK" "" "$ROOT" "" "" ""
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  read-rules)
    # 双层规则机制：规则变更后的重读入口；刷新 hash 记录并打印全文
    if [[ ! -f "$DEV_FLOW_GLOBAL_RULES_FILE" ]]; then
      echo "全局规则文件缺失: $DEV_FLOW_GLOBAL_RULES_FILE" >&2
      exit 1
    fi
    dev_flow_rules_ensure_project_file
    refresh_rules_state
    dev_flow_rules_print "GLOBAL RULES" "$DEV_FLOW_GLOBAL_RULES_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  commit)
    parse_commit_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_verify_environment_health "$STATE_FILE"
    record_commit "$COMMIT_MESSAGE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  testflight)
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_verify_environment_health "$STATE_FILE"
    record_testflight
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  end)
    write_state "end" "" "" "" "" "" "" ""
    ;;
  status)
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "No dev-flow session."
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
