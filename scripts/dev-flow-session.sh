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
  scripts/dev-flow-session.sh start --type bug|feature|ui_review [--level trivial|standard|heavy] [--task "label"]
  scripts/dev-flow-session.sh configure-gates --required <comma-separated gates>
  scripts/dev-flow-session.sh environment-health --report <path>
  scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime|ui_parity --report <path>
  scripts/dev-flow-session.sh confirm-plan [--task "label"]
  scripts/dev-flow-session.sh approve-commit [--task "label"]
  scripts/dev-flow-session.sh commit --message "msg"
  scripts/dev-flow-session.sh testflight
  scripts/dev-flow-session.sh read-rules
  scripts/dev-flow-session.sh end
  scripts/dev-flow-session.sh status

Rules note (双层规则机制):
  start/read-rules 打印全局(rules/global-rules.md)+项目(.dev-flow/rules.md)规则全文到 stdout；
  所有写 state 的门禁 action 前置校验项目规则 sha256，变更后必须先 read-rules；
  门禁 action 成功后把项目规则回带到 stdout；approve-commit 额外校验全局规则 sha256。

Session selection:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, then CURSOR_CONVERSATION_ID.
  Outside Cursor, falls back to "local". Inside Cursor, a missing conversation id is an error.
Gate note:
  ui_review source repair requires review,runtime,ui_parity before confirm-plan.
  Environment health must run before confirm-plan and cannot be updated after confirmation.
  commit 收口提交动作：approve-commit 已批 + 暂存区非空才会执行 git commit 并记录 hash；
  testflight 委托项目 fastlane：commit 完成且 HEAD 未漂移才执行
  <项目>/.dev-flow/testflight-command 中的命令并登记证据。
Task level (--level, only meaningful for start):
  trivial   - 文案/typo/纯逻辑微调专用轻量通道；环境门只要求 review_mcp；仅 review 门；
              configure-gates 禁止加 runtime/figma_ui/ui_parity。
  standard  - 默认；环境门要求 app_launch + review_mcp。
  heavy     - 新 Figma UI / ui_review；环境门全 4 项（app_launch, debugbridge, review_mcp, figma_rest_api）。
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_common_args() {
  SESSION_TYPE=""
  TASK=""
  SESSION_LEVEL="standard"
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
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$action" "$session_type" "$task" "$required_gates" "$(now_utc)" "$project_root" "$level" <<'PY'
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

all_gates = ("figma_ui", "review", "runtime", "ui_parity")
required_gates = [item for item in required_gates_arg.split(",") if item]
if action == "start" and not required_gates:
    required_gates = ["review"]
if any(item not in all_gates for item in required_gates):
    raise SystemExit("Unknown gate. Use figma_ui, review, runtime, or ui_parity.")
if action in ("start", "configure-gates") and "review" not in required_gates:
    raise SystemExit("The review gate is required for every dev-flow commit session.")
if len(set(required_gates)) != len(required_gates):
    raise SystemExit("Duplicate required gate.")

default_gate_results = {
    "figma_ui": {"status": "not-required", "evidence": None, "recorded_at": None},
    "review": {"status": "pending", "evidence": None, "recorded_at": None},
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
TRIVIAL_FORBIDDEN_GATES = ("runtime", "figma_ui", "ui_parity")
# 空 level 仅出现在非 start 命令（configure-gates/confirm 等），不校验；start 必须传合法 level
if level and level not in VALID_LEVELS:
    raise SystemExit("Invalid level. Use trivial, standard, or heavy.")


def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    import os
    import tempfile

    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

if action == "start":
    data = {
        "session_id": session_id,
        "active": True,
        "type": session_type,
        "task": task,
        "level": level,
        "started_at": timestamp,
        "confirmed_at": None,
        "commit_approved_at": None,
        "ended_at": None,
        "required_gates": required_gates,
        "gate_results": make_gate_results(required_gates),
        "environment_health": {
            "status": "not-run",
            "checked_at": None,
            "checks": {},
        },
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
    if data.get("confirmed_at"):
        raise SystemExit("Required gates cannot change after plan confirmation.")
    # trivial 会话禁止加 runtime/figma_ui/ui_parity，防止绕过轻量通道
    if data.get("level") == "trivial" and any(g in TRIVIAL_FORBIDDEN_GATES for g in required_gates):
        raise SystemExit("trivial sessions may only configure the review gate.")
    # 重型 gate（runtime/figma_ui/ui_parity）要求 heavy 环境门，防止 standard 环境检查不足
    if data.get("level") != "heavy" and any(g in TRIVIAL_FORBIDDEN_GATES for g in required_gates):
        raise SystemExit(
            "runtime/figma_ui/ui_parity gates require a heavy session (restart with start --level heavy)."
        )
    data["required_gates"] = required_gates
    data["gate_results"] = make_gate_results(required_gates)
    data["session_id"] = session_id
elif action == "confirm-plan":
    if not data.get("active"):
        raise SystemExit("No active dev-flow session. Run start first.")
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    if data.get("type") == "ui_review":
        required = set(data.get("required_gates", []))
        missing = {"review", "runtime", "ui_parity"} - required
        if missing:
            raise SystemExit(
                "ui_review source repair requires gates configured before confirm-plan: "
                + ",".join(sorted(missing))
            )
    # 环境健康检查必须有 checked_at 时间戳，禁止空值通过 confirm-plan
    checked_at = data.get("environment_health", {}).get("checked_at")
    if not isinstance(checked_at, str) or not checked_at.strip():
        raise SystemExit("Environment health checked_at is missing; run environment-health-check.sh before confirm-plan.")
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
    if data.get("environment_health", {}).get("status") != "available":
        raise SystemExit("Environment health is not available. Run environment-health-check.sh first.")
    if not data.get("confirmed_at"):
        raise SystemExit("Plan is not confirmed. Run confirm-plan first.")
    required = data.get("required_gates", ["review"])
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

atomic_write(path, data)
print(path)
PY
}

# read-rules：刷新 state 中全局+项目规则的 sha256/read_at（规则变更后的恢复入口）
refresh_rules_state() {
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" <<'PY'
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]

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
atomic_write(state_path, state)
print(state_path)
PY
}

 record_environment() {
   local report_file="$1"
   mkdir -p "$STATE_DIR"
   /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$report_file" "$(now_utc)" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
report_path = Path(sys.argv[3])
checked_at = sys.argv[4]

if not state_path.exists():
    raise SystemExit("No active dev-flow session. Run start first.")
state = json.loads(state_path.read_text())
if not state.get("active"):
    raise SystemExit("No active dev-flow session. Run start first.")
# 轻量防伪：环境健康报告必须位于本会话 state 目录内（environment-health-check.sh 的临时产出）
try:
    report_path.resolve().relative_to(state_path.resolve().parent)
except ValueError:
    raise SystemExit("Environment report must live inside the session state directory.")
# plan 确认后禁止更新环境健康，避免确认后环境状态漂移
if state.get("confirmed_at"):
    raise SystemExit("Environment health cannot be updated after plan confirmation.")
report = json.loads(report_path.read_text())
if report.get("producer") != "environment-health-check" or report.get("schema_version") != 1:
    raise SystemExit("Environment report was not produced by environment-health-check.")
if report.get("session_id") != session_id:
    raise SystemExit("Environment report belongs to another session.")
checks = report.get("checks")
# 按会话 level 裁剪必需检查项：trivial 只要求 review_mcp；standard 要求 app_launch+review_mcp；heavy 全 4 项
LEVEL_CHECKS = {
    "trivial": ("review_mcp",),
    "standard": ("app_launch", "review_mcp"),
    "heavy": ("app_launch", "debugbridge", "review_mcp", "figma_rest_api"),
}
level = state.get("level", "heavy")
required = LEVEL_CHECKS.get(level, LEVEL_CHECKS["heavy"])
all_checks = ("app_launch", "debugbridge", "review_mcp", "figma_rest_api")
if not isinstance(checks, dict) or any(name not in checks for name in all_checks):
    raise SystemExit("Environment report is missing required checks.")
# 必需项必须存在且状态合法；非必需项允许 not-required
if any(checks[name].get("status") not in ("available", "blocked", "not-run") for name in required):
    raise SystemExit("Environment report contains an invalid check status.")
derived_status = "available" if all(checks[name].get("status") == "available" for name in required) else "blocked"
if report.get("status") != derived_status:
    raise SystemExit("Environment report status does not match its checks.")
state["environment_health"] = {
    "status": derived_status,
    "checked_at": checked_at,
    "checks": checks,
}
state["session_id"] = session_id
atomic_write(state_path, state)
print(state_path)
if derived_status != "available":
    raise SystemExit(1)
PY
}

record_gate() {
  local gate_name="$1"
  local report_file="$2"
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$gate_name" "$report_file" "$(now_utc)" "$SOURCE_ROOT" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
gate_name = sys.argv[3]
report_path = Path(sys.argv[4])
recorded_at = sys.argv[5]
devflow_root = Path(sys.argv[6]).resolve()


def sha256_of(path):
    # 计算 artifact 文件内容 sha256，用于与人工批准时记录的 digest 比对
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

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
    }
    extra = set(report.keys()) - REVIEW_ALLOWED_FIELDS
    if extra:
        raise SystemExit("review report contains unknown fields: " + ", ".join(sorted(extra)))
    if report.get("producer") not in ("code-review-workflow", "review-health-probe", "ui-review"):
        raise SystemExit("review report producer must be code-review-workflow, review-health-probe, or ui-review.")
    if report.get("schema_version") != 1:
        raise SystemExit("review report schema_version must be 1.")
    # fallback 绑定：会话环境门处于 gstack-review fallback 时，报告必须出自
    # run-review-fallback.sh —— 校验一次性 fallback_token、packet_digest、报告路径三件套，
    # 不跑 runner 手写 review_path=fallback 会被拒（防伪报路径/宿主审查伪报）
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
    if report.get("review_path") is not None and report.get("review_path") not in ("mcp", "fallback"):
        raise SystemExit('review_path must be "mcp" or "fallback".')

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
    expected = [f"G{i}" for i in range(13)]
    if not isinstance(gates, dict) or any(gates.get(name) != "pass" for name in expected):
        raise SystemExit("figma_ui=pass requires G0 through G12 all to be pass.")
    artifact_workspace = report.get("artifact_workspace")
    if not isinstance(artifact_workspace, str) or not artifact_workspace.strip():
        raise SystemExit("figma_ui=pass requires artifact_workspace.")
    source_root = report.get("source_root")
    if not isinstance(source_root, str) or not source_root.strip():
        raise SystemExit("figma_ui=pass requires source_root.")
    g6_validation = report.get("g6_validation")
    if g6_validation != "pass":
        raise SystemExit("figma_ui=pass requires g6_validation=pass.")
    g6_report = report.get("g6_validation_report")
    if not isinstance(g6_report, str) or not g6_report.strip():
        raise SystemExit("figma_ui=pass requires g6_validation_report path.")
    # g6 报告路径必须位于 artifact workspace 内，防止引用外部伪造报告
    g6_report_path = Path(g6_report).expanduser().resolve()
    try:
        g6_report_path.relative_to(Path(artifact_workspace).expanduser().resolve())
    except ValueError:
        raise SystemExit("g6_validation_report must be inside artifact_workspace.")
    if not g6_report_path.is_file():
        raise SystemExit("figma_ui=pass requires an existing g6_validation_report file.")
    try:
        g6_payload = json.loads(g6_report_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid g6_validation_report JSON: {exc}") from exc
    if g6_payload.get("status") != "pass":
        raise SystemExit("figma_ui=pass requires g6_validation_report status=pass.")

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
state["session_id"] = session_id
atomic_write(state_path, state)
print(state_path)
PY
}

# commit：收口提交动作。approve-commit 已批 → 校验暂存区 → git commit → 记录 hash。
# 提交后重置 testflight 状态（新 commit 使旧构建证据失效）。
record_commit() {
  local message="$1"
  mkdir -p "$STATE_DIR"
  DEV_FLOW_COMMIT_MESSAGE="$message" /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
project_root = Path(sys.argv[4])
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
atomic_write(state_path, state)
print(state_path)
print(f"committed: {commit_hash}")
PY
}

# testflight：门禁 + 委托项目 fastlane。校验 commit 完成且 HEAD 未漂移 →
# 执行 <项目>/.dev-flow/testflight-command（或测试模式 DEV_FLOW_TESTFLIGHT_CMD）→ 登记证据。
record_testflight() {
  mkdir -p "$STATE_DIR"
  /usr/bin/python3 - "$STATE_FILE" "$SESSION_ID" "$(now_utc)" "$ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

def atomic_write(path, data):
    """原子写 session state：临时文件 + os.replace，权限 0600；拒绝 symlink 目标"""
    if path.is_symlink():
        raise SystemExit("refusing to write session state through a symlink")
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

state_path = Path(sys.argv[1])
session_id = sys.argv[2]
timestamp = sys.argv[3]
project_root = Path(sys.argv[4])

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
atomic_write(state_path, state)
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
    # --level 缺值拒绝（空字符串）；ui_review 必须 heavy，防止绕过真机/DebugBridge/Figma 环境门
    if [[ -z "$SESSION_LEVEL" ]]; then
      echo "start --level requires a value (trivial|standard|heavy)" >&2
      exit 2
    fi
    if [[ "$SESSION_TYPE" == "ui_review" && "$SESSION_LEVEL" != "heavy" ]]; then
      echo "ui_review requires --level heavy (full environment checks)" >&2
      exit 2
    fi
    # 双层规则机制第 1 层：start 硬读。全局规则缺失直接失败；项目规则缺失则建空模板
    if [[ ! -f "$DEV_FLOW_GLOBAL_RULES_FILE" ]]; then
      echo "全局规则文件缺失: $DEV_FLOW_GLOBAL_RULES_FILE" >&2
      exit 1
    fi
    dev_flow_rules_ensure_project_file
    rm -f "$STATE_DIR/$SESSION_ID.app-launch.json"
    write_state "start" "$SESSION_TYPE" "$TASK" "review" "" "$SESSION_LEVEL"
    dev_flow_rules_print "GLOBAL RULES" "$DEV_FLOW_GLOBAL_RULES_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  configure-gates)
    parse_gate_config_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    write_state "configure-gates" "" "" "$REQUIRED_GATES" "" ""
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
    record_gate "$GATE_NAME" "$REPORT_FILE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  confirm-plan)
    parse_common_args "$@"
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    # requirements index.json 在业务项目根（$ROOT），不是 devflow 仓库根（$SOURCE_ROOT）
    write_state "confirm-plan" "" "$TASK" "" "$ROOT" ""
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  approve-commit)
    parse_common_args "$@"
    # 双层规则机制第 3 层：commit 闭环，全局+项目规则 hash 都必须仍一致
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    dev_flow_rules_verify_global_fresh "$STATE_FILE"
    write_state "approve-commit" "" "$TASK" "" "" ""
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
    record_commit "$COMMIT_MESSAGE"
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  testflight)
    dev_flow_rules_verify_project_fresh "$STATE_FILE"
    record_testflight
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
    ;;
  end)
    write_state "end" "" "" "" "" ""
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
