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
FIGMA_SKILL_ROOT="${FIGMA_REST_API_SKILL_ROOT:-$HOME/.codex/skills/figma-rest-api}"
FIGMA_REST_TOKEN="${FIGMA_REST_TOKEN:-${FIGMA_ACCESS_TOKEN:-}}"
if [[ -n "$FIGMA_REST_TOKEN" ]]; then
  export FIGMA_REST_TOKEN
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/environment-health-check.sh run

Records a schema_version=2 environment health report in the current dev-flow session. The
required capabilities are derived from the session's required_gates:

  review      => review_mcp
  runtime     => app_launch, debugbridge
  figma_ui    => app_launch, debugbridge, figma_rest_api
  ui_parity   => app_launch, debugbridge, figma_rest_api

Only required capabilities are probed; non-required capabilities are recorded as
{status:not-required,evidence:not_required_for_session} and do not participate in the overall
status. Review and Figma probes are independent; the App launch probe is independent; DebugBridge
depends on App launch (when both are required, an App launch failure marks DebugBridge as
not-run instead of probing). An App launch failure never short-circuits the review or Figma
probes.

The App launch probe defaults to scripts/app-launch-preflight.sh status, which reads and
validates .dev-flow/sessions/<session-id>.app-launch.json. Override with
DEV_FLOW_APP_LAUNCH_HEALTH_CMD when a custom adapter is required. The stored or adapter JSON
must include producer=XcodeBuildMCP, schema_version=2, the current session_id,
status=available, build_run_action=build_run_device|build_run_sim, build_run_result=success,
device_transport=wired|simulator (must cross-match the action: device↔wired, sim↔simulator),
and app_launched=true. DebugBridge uses DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD. Review adapter health
defaults to scripts/review-health-probe.sh, which uses the review-backend resolver to select
an adapter (agent/openai-reviewer, mcp/orchestrator, or skill/gstack) and falls back to
gstack-review when the primary is unavailable and the policy allows. Figma REST defaults to a
token-safe curl probe against /v1/me using FIGMA_REST_TOKEN (FIGMA_ACCESS_TOKEN is accepted as
an alias); override with DEV_FLOW_FIGMA_REST_HEALTH_CMD only when a custom adapter is required.

Session selection matches scripts/resolve-dev-flow-session-id.sh:
  DEV_FLOW_SESSION_ID, then CODEX_THREAD_ID, then CURSOR_CONVERSATION_ID.
EOF
}

if [[ "${1:-}" != "run" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

# sessions 目录 symlink 检查：fail closed before any operation。
# safe_atomic_write_json（dev-flow-session.sh 写 state 时）也会拒绝 symlink，
# 但这里提前拦截避免 probe 阶段读取/写入被重定向到外部目录。
if [[ -L "$STATE_DIR" ]]; then
  echo "error: sessions directory is a symlink, refusing to proceed: $STATE_DIR" >&2
  exit 1
fi
# REPORT_FILE 使用系统临时目录（不在 STATE_DIR 内），
# 防止 sessions symlink 泄漏临时文件到外部目录。
# 最终环境报告由 dev-flow-session.sh environment-health 通过 safe_atomic_write_json 落盘到 STATE_FILE。
REPORT_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE"' EXIT

run_probe() {
  local command_text="$1"
  local label="$2"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"

  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    /usr/bin/python3 - "$label" <<'PY'
import json
import sys
print(json.dumps({"status": "blocked", "evidence": "probe_not_configured"}, ensure_ascii=False))
PY
    return
  fi

  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e

  # 传递 selection binding 字段：如果 probe stdout 是有效 JSON 且含
  # selected_adapter/config_digest/selection_reason，合并到结果中。
  # 这样测试环境的 probe 可以输出 selection binding 字段，生产环境用 review-health-probe.sh。
  /usr/bin/python3 - "$exit_code" "$output_file" <<'PY'
import json
import sys

exit_code = int(sys.argv[1])
stdout_path = sys.argv[2]

# 基础结果（exit-code 探活）
if exit_code == 0:
    result = {"status": "available", "evidence": "probe_exit_0"}
else:
    result = {"status": "blocked", "evidence": f"probe_exit_{exit_code}"}

# 尝试解析 probe stdout 为 JSON，传递 selection binding 字段
try:
    with open(stdout_path) as f:
        stdout_text = f.read().strip()
    if stdout_text:
        parsed = json.loads(stdout_text)
        if isinstance(parsed, dict):
            # 如果 probe 输出了 status，用它覆盖 exit-code 推断的 status
            if "status" in parsed:
                result["status"] = parsed["status"]
            if "evidence" in parsed:
                result["evidence"] = parsed["evidence"]
            # 传递 selection binding 字段（review-health-probe.sh 产出）
            for field in ("selected_adapter", "selection_reason", "config_digest",
                          "transport", "fallback", "source", "skill_path"):
                if field in parsed:
                    result[field] = parsed[field]
except (json.JSONDecodeError, OSError, ValueError):
    pass

print(json.dumps(result, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

run_app_launch_probe() {
  local command_text="$1"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    printf '%s\n' '{"status":"blocked","evidence":"app_launch_probe_not_configured"}'
    return
  fi
  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  /usr/bin/python3 - "$output_file" "$exit_code" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
session_id = sys.argv[3]
try:
    payload = json.loads(output_path.read_text())
except (json.JSONDecodeError, OSError):
    payload = {}
def _non_placeholder(value):
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value.strip().lower() not in ("unknown", "n/a", "-", "")
    )

# schema_version 2：build_run_action 明确区分 build_run_device（wired 真机）
# 与 build_run_sim（显式模拟器），device_transport 必须与 action 交叉一致。
action = payload.get("build_run_action")
expected_transport = "wired" if action == "build_run_device" else (
    "simulator" if action == "build_run_sim" else None
)
valid = (
    exit_code == 0
    and payload.get("producer") == "XcodeBuildMCP"
    and payload.get("schema_version") == 2
    and payload.get("session_id") == session_id
    and payload.get("status") == "available"
    and action in ("build_run_device", "build_run_sim")
    and payload.get("build_run_result") == "success"
    and payload.get("device_transport") == expected_transport
    and payload.get("app_launched") is True
    and _non_placeholder(payload.get("build_id"))
    and _non_placeholder(payload.get("device_id"))
)
if valid:
    result = {
        "status": "available",
        "evidence": "xcodebuildmcp_{action}_success;{transport};app_launched;build_id={build_id};device_id={device_id}".format(
            action=action,
            transport=payload.get("device_transport"),
            build_id=payload.get("build_id"),
            device_id=payload.get("device_id"),
        ),
    }
else:
    if payload.get("status") == "blocked" and isinstance(payload.get("evidence"), str) and payload.get("evidence"):
        print(json.dumps({
            "status": "blocked",
            "evidence": payload.get("evidence"),
        }, ensure_ascii=False))
        raise SystemExit(0)
    result = {
        "status": "blocked",
        "evidence": "invalid_or_failed_xcodebuildmcp_app_launch_report",
    }
print(json.dumps(result, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

run_bridge_session_probe() {
  local command_text="$1"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    printf '%s\n' '{"status":"blocked","evidence":"bridge_session_probe_not_configured"}'
    return
  fi
  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  /usr/bin/python3 - "$output_file" "$exit_code" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
session_id = sys.argv[3]
try:
    payload = json.loads(output_path.read_text())
except (json.JSONDecodeError, OSError):
    payload = {}

bridge_session = payload.get("bridge_session_id")
status = payload.get("status")
evidence = payload.get("evidence") or "bridge_session_probe_invalid"

valid = (
    exit_code == 0
    and status == "available"
    and isinstance(bridge_session, str)
    and bridge_session
    and (
        (session_id == "local" and bridge_session == "local")
        or (
            session_id != "local"
            and bridge_session == session_id
            and bridge_session != "local"
        )
    )
)

if valid:
    result = {
        "status": "available",
        "evidence": evidence,
        "bridge_session_id": bridge_session,
    }
else:
    if status == "blocked" and evidence:
        blocked_evidence = evidence
    elif exit_code != 0:
        blocked_evidence = f"bridge_session_probe_exit_{exit_code}"
    else:
        blocked_evidence = "invalid_or_failed_bridge_session_probe"
    result = {
        "status": "blocked",
        "evidence": blocked_evidence,
    }
    if isinstance(bridge_session, str) and bridge_session:
        result["bridge_session_id"] = bridge_session
print(json.dumps(result, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

run_review_probe() {
  local command_text="$1"
  local output_file error_file exit_code
  output_file="$(mktemp)"
  error_file="$(mktemp)"
  if [[ -z "$command_text" ]]; then
    rm -f "$output_file" "$error_file"
    printf '%s\n' '{"status":"blocked","evidence":"review_probe_not_configured"}'
    return
  fi
  set +e
  /bin/bash -c "$command_text" >"$output_file" 2>"$error_file"
  exit_code=$?
  set -e
  /usr/bin/python3 - "$output_file" "$exit_code" "$SESSION_ID" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
session_id = sys.argv[3]
try:
    payload = json.loads(output_path.read_text())
except (json.JSONDecodeError, OSError):
    payload = {}
valid = (
    exit_code == 0
    and payload.get("producer") == "review-health-probe"
    and payload.get("schema_version") == 1
    and payload.get("session_id") == session_id
    and payload.get("status") == "available"
    and payload.get("transport") in ("reviewer", "mcp", "fallback")
    and payload.get("evidence")
)
if not valid:
    print(json.dumps({"status": "blocked", "evidence": "invalid_or_failed_review_health_report"}, ensure_ascii=False))
    sys.exit(0)
# 严格契约校验：按 transport 校验 fallback / skill_path 组合。
transport = payload.get("transport")
fallback = payload.get("fallback")
skill_path = payload.get("skill_path")
if transport == "fallback":
    # fallback 通道：必须 fallback=="gstack-review" 且 skill_path 为非空字符串。
    if fallback != "gstack-review" or not isinstance(skill_path, str) or not skill_path:
        print(json.dumps({"status": "blocked", "evidence": "invalid_fallback_contract"}, ensure_ascii=False))
        sys.exit(0)
elif transport == "reviewer":
    # reviewer 通道：fallback 应为空/null。
    if fallback not in (None, ""):
        print(json.dumps({"status": "blocked", "evidence": "invalid_reviewer_contract"}, ensure_ascii=False))
        sys.exit(0)
elif transport == "mcp":
    # mcp 通道：fallback 应为空/null。
    if fallback not in (None, ""):
        print(json.dumps({"status": "blocked", "evidence": "invalid_mcp_contract"}, ensure_ascii=False))
        sys.exit(0)
# 直接使用探针 evidence（已含 selection 信息）；附加 selection binding 字段
result = {"status": "available", "evidence": payload.get("evidence")}
# 传递 selection binding 字段（record_environment 会写入 state.review_selection）
for field in ("selected_adapter", "selection_reason", "config_digest", "source", "skill_path"):
    val = payload.get(field)
    if val:
        result[field] = val
print(json.dumps(result, ensure_ascii=False))
PY
  rm -f "$output_file" "$error_file"
}

# 生产模式（未设置 DEV_FLOW_TEST_MODE=1）下忽略所有自定义健康探针覆盖，防止伪造
if [[ "${DEV_FLOW_TEST_MODE:-}" != "1" ]]; then
  if [[ -n "${DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD:-}" || -n "${DEV_FLOW_APP_LAUNCH_HEALTH_CMD:-}" || -n "${DEV_FLOW_REVIEW_MCP_HEALTH_CMD:-}" || -n "${DEV_FLOW_FIGMA_REST_HEALTH_CMD:-}" ]]; then
    echo "warning: ignoring DEV_FLOW_*_HEALTH_CMD overrides (set DEV_FLOW_TEST_MODE=1 to use them)" >&2
  fi
  unset DEV_FLOW_APP_LAUNCH_HEALTH_CMD DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD DEV_FLOW_REVIEW_MCP_HEALTH_CMD DEV_FLOW_FIGMA_REST_HEALTH_CMD
fi

# 从当前 session state 读取 required_gates，派生 required capabilities。
# 只有 required capability 才运行探针；非 required 标记 not-required，不参与总状态。
# 一致性交叉校验：合法 trivial 才允许空 gates；非 trivial 显式空 gates / 缺 review /
# 字段自相矛盾 → fail closed（不产出 available）。lib 路径由 dev_flow_load_paths 解析。
caps_info="$(/usr/bin/python3 - "$STATE_FILE" "$DEV_FLOW_SCRIPTS_DIR/lib" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
sys.path.insert(0, sys.argv[2])
from trivial_session import resolve_required_gates

if not state_path.exists():
    print("ERROR:no_active_dev_flow_session")
    raise SystemExit(0)
try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("ERROR:state_invalid_json")
    raise SystemExit(0)
if not state.get("active"):
    print("ERROR:no_active_dev_flow_session")
    raise SystemExit(0)
# 一致性交叉校验：合法 trivial 才允许空 gates；非 trivial 显式空 gates /
# 缺 review / trivial 字段自相矛盾 → fail closed（不产出 available）。
# 旧 session 缺 required_gates → resolve 回退 ["review"]。
try:
    gates, _is_trivial = resolve_required_gates(state)
except SystemExit as exc:
    msg = str(exc) or "session gate consistency error"
    print("ERROR:session_gate_inconsistent:" + msg.splitlines()[0][:200])
    raise SystemExit(0)
mapping = {
    "review": ("review_mcp",),
    "runtime": ("app_launch", "debugbridge"),
    "figma_ui": ("app_launch", "debugbridge", "figma_rest_api"),
    "ui_parity": ("app_launch", "debugbridge", "figma_rest_api"),
}
caps = set()
for gate in gates:
    for cap in mapping.get(gate, ()):
        caps.add(cap)
order = ("app_launch", "debugbridge", "review_mcp", "figma_rest_api")
required_caps = [cap for cap in order if cap in caps]
print("\t".join([",".join(gates), ",".join(required_caps)]))
PY
)"

if [[ "$caps_info" == ERROR:* ]]; then
  echo "$caps_info" >&2
  echo "Session gate state is inconsistent; re-open as standard/heavy or fix the session state." >&2
  echo "Run scripts/dev-flow-session.sh start --type bug|feature|ui_review before environment-health." >&2
  exit 1
fi

required_gates_str="${caps_info%%$'\t'*}"
required_caps_str="${caps_info#*$'\t'}"

needs_review=0
needs_app_launch=0
needs_debugbridge=0
needs_figma=0
# trivial fast-path 时 required_caps_str 为空，_caps_arr 为空数组；
# set -u 下空数组的 "${arr[@]}" 会报 unbound，故仅非空时循环
if [[ -n "$required_caps_str" ]]; then
  IFS=',' read -r -a _caps_arr <<< "$required_caps_str"
  for _cap in "${_caps_arr[@]}"; do
    case "$_cap" in
      review_mcp) needs_review=1 ;;
      app_launch) needs_app_launch=1 ;;
      debugbridge) needs_debugbridge=1 ;;
      figma_rest_api) needs_figma=1 ;;
    esac
  done
fi

debug_command="${DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD:-}"
if [[ -z "$debug_command" ]]; then
  debug_command="'$(dev_flow_script_path validate-bridge-session.sh)' run"
fi

app_launch_command="${DEV_FLOW_APP_LAUNCH_HEALTH_CMD:-}"
if [[ -z "$app_launch_command" ]]; then
  app_launch_command="'$(dev_flow_script_path app-launch-preflight.sh)' status"
fi

not_required_result='{"status":"not-required","evidence":"not_required_for_session"}'

# Review 探针独立运行；review_mcp required 时才探测。
# 默认用 run_review_probe（解析 review-health-probe JSON + 传递 selection binding 字段）；
# DEV_FLOW_REVIEW_MCP_HEALTH_CMD 覆盖时用 run_probe（exit-code 探活 + stdout JSON 传递）。
# selection binding 字段（selected_adapter/config_digest）在两条路径下都传递：
# - 默认路径：review-health-probe.sh 输出完整 JSON
# - 覆盖路径：probe stdout 如为有效 JSON 则传递 selection binding 字段（测试环境可用）
if [[ "$needs_review" -eq 1 ]]; then
  review_command="${DEV_FLOW_REVIEW_MCP_HEALTH_CMD:-}"
  if [[ -n "$review_command" ]]; then
    review_result="$(run_probe "$review_command" review_mcp)"
  else
    review_result="$(run_review_probe "'$(dev_flow_script_path review-health-probe.sh)'")"
  fi
else
  review_result="$not_required_result"
fi

# App launch 独立运行；runtime/figma_ui/ui_parity required 时才探测。
if [[ "$needs_app_launch" -eq 1 ]]; then
  app_launch_result="$(run_app_launch_probe "$app_launch_command")"
  app_launch_status="$(/usr/bin/python3 - "$app_launch_result" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["status"])
PY
)"
else
  app_launch_result="$not_required_result"
  app_launch_status="not-required"
fi

# Figma REST 独立运行；figma_ui/ui_parity required 时才探测。
if [[ "$needs_figma" -eq 1 ]]; then
  figma_skill_status="available"
  figma_skill_evidence="skill_and_script_present"
  if [[ ! -f "$FIGMA_SKILL_ROOT/SKILL.md" ]]; then
    figma_skill_status="blocked"
    figma_skill_evidence="skill_file_missing"
  elif [[ ! -f "$FIGMA_SKILL_ROOT/scripts/figma_rest.py" ]]; then
    figma_skill_status="blocked"
    figma_skill_evidence="figma_rest_script_missing"
  elif [[ -z "${FIGMA_REST_TOKEN:-}" && -z "${DEV_FLOW_FIGMA_REST_HEALTH_CMD:-}" ]]; then
    figma_skill_status="blocked"
    figma_skill_evidence="FIGMA_REST_TOKEN_missing"
  fi

  if [[ "$figma_skill_status" == "available" ]]; then
    if [[ -n "${DEV_FLOW_FIGMA_REST_HEALTH_CMD:-}" ]]; then
      figma_result="$(run_probe "$DEV_FLOW_FIGMA_REST_HEALTH_CMD" figma_rest)"
    else
      figma_result="$(run_probe "/usr/bin/curl -fsS --connect-timeout 5 --max-time 15 -H \"X-Figma-Token: \$FIGMA_REST_TOKEN\" https://api.figma.com/v1/me --output /dev/null" figma_rest)"
    fi
    figma_result="$(/usr/bin/python3 - "$figma_skill_evidence" "$figma_result" <<'PY'
import json
import sys

skill_evidence = sys.argv[1]
result = json.loads(sys.argv[2])
if result["status"] == "available":
    result["evidence"] = skill_evidence + ";" + result["evidence"]
print(json.dumps(result, ensure_ascii=False))
PY
)"
  else
    figma_result="$(/usr/bin/python3 - "$figma_skill_status" "$figma_skill_evidence" <<'PY'
import json
import sys
print(json.dumps({"status": sys.argv[1], "evidence": sys.argv[2]}, ensure_ascii=False))
PY
)"
  fi
else
  figma_result="$not_required_result"
fi

# DebugBridge 依赖 app_launch：required 且 app_launch 成功时才探测；
# app_launch 失败时 DebugBridge 标记 not-run（依赖失败），不短路审查角色/Figma。
if [[ "$needs_debugbridge" -eq 1 ]]; then
  if [[ "$needs_app_launch" -eq 1 && "$app_launch_status" != "available" ]]; then
    debug_result='{"status":"not-run","evidence":"app_launch_preflight_failed"}'
  else
    if [[ -n "${DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD:-}" ]]; then
      debug_result="$(run_probe "$debug_command" debugbridge)"
    else
      debug_result="$(run_bridge_session_probe "$debug_command")"
    fi
  fi
else
  debug_result="$not_required_result"
fi

/usr/bin/python3 - "$REPORT_FILE" "$SESSION_ID" "$app_launch_result" "$debug_result" "$review_result" "$figma_result" "$required_gates_str" "$required_caps_str" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

report_path = Path(sys.argv[1])
session_id = sys.argv[2]
checks = {
    # 历史键名 review_mcp 语义 = Review adapter（agent/orchestrator/gstack），非特指 MCP；保留以兼容已有 session state。
    "app_launch": json.loads(sys.argv[3]),
    "debugbridge": json.loads(sys.argv[4]),
    "review_mcp": json.loads(sys.argv[5]),
    "figma_rest_api": json.loads(sys.argv[6]),
}
required_gates = [g for g in sys.argv[7].split(",") if g] if sys.argv[7] else []
required_capabilities = [c for c in sys.argv[8].split(",") if c] if sys.argv[8] else []
required_set = set(required_capabilities)
# 总状态：required capability 全 available 才 available；非 required 不参与（应为 not-required）。
if required_set:
    status = "available" if all(checks[c]["status"] == "available" for c in required_set) else "blocked"
else:
    # trivial fast-path（required_gates=[]）：四项能力均非必需且应为 not-required，
    # 无需要 available 的能力，overall 状态为 available（与 record_environment 派生一致）。
    status = "available"
report = {
    "producer": "environment-health-check",
    "schema_version": 2,
    "session_id": session_id,
    "status": status,
    "required_gates": required_gates,
    "required_capabilities": required_capabilities,
    "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "checks": checks,
}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(report_path)
PY

if "$(dev_flow_script_path dev-flow-session.sh)" environment-health --report "$REPORT_FILE" >/dev/null; then
  cat "$STATE_FILE"
  # 双层规则机制：项目规则回带到 stdout（hash 校验已由 dev-flow-session.sh environment-health 完成）
  if [[ -f "$DEV_FLOW_PROJECT_RULES_FILE" ]]; then
    dev_flow_rules_print "PROJECT RULES" "$DEV_FLOW_PROJECT_RULES_FILE"
  fi
  exit 0
fi

cat "$STATE_FILE" >&2
exit 1
