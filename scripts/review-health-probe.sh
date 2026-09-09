#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=lib/reviewer-readiness.sh
source "$(dev_flow_script_path lib/reviewer-readiness.sh)"
# shellcheck source=lib/review-backend-resolver.sh
source "$(dev_flow_script_path lib/review-backend-resolver.sh)"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?

# Review adapter 健康探针：使用 review-backend-resolver 解析配置（三层优先级），
# 探活 primary adapter；primary 不可用且策略允许时按 fallback_order 探活 fallback。
# 输出 JSON（producer=review-health-probe, schema_version=1）：
#   - transport: reviewer | mcp | fallback
#   - fallback: "gstack-review" | null（transport=fallback 时）
#   - skill_path: gstack skill 路径 | null（transport=fallback 时）
#   - selected_adapter: 稳定 adapter ID（agent/openai-reviewer | mcp/orchestrator | skill/gstack）
#   - selection_reason: 选择原因
#   - config_digest: 配置 digest（dispatch 绑定用）

# 解析 + 探活
# 显式传递 --project-root，确保 resolver 子进程能读到项目级配置，
# 不依赖 DEV_FLOW_PROJECT_ROOT 是否被 export（defense in depth）。
selection_json="$(review_resolve_and_probe --project-root "$DEV_FLOW_PROJECT_ROOT")" || {
  # resolver fail closed（无有效配置）→ 探针也 fail closed
  echo "$selection_json" >&2
  /usr/bin/python3 - "$SESSION_ID" <<'PY'
import json
import sys
payload = {
    "producer": "review-health-probe",
    "schema_version": 1,
    "session_id": sys.argv[1],
    "status": "blocked",
    "transport": "none",
    "fallback": None,
    "evidence": "review_backend_resolver_blocked",
}
print(json.dumps(payload, ensure_ascii=False))
PY
  exit 1
}

# 从 selection_json 提取字段
selected_adapter="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["selected_adapter"])' <<< "$selection_json")"
probe_status="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("probe_status","unavailable"))' <<< "$selection_json")"
probe_evidence="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("probe_evidence",""))' <<< "$selection_json")"
selection_reason="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("selection_reason",""))' <<< "$selection_json")"
config_digest="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("config_digest",""))' <<< "$selection_json")"
selection_source="$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("source",""))' <<< "$selection_json")"

# 生产模式（非测试）下 source=default 必须 blocked——没有显式配置不得 available。
# 不得先 available 再让 review 必然失败；在环境门就明确要求首次配置向导。
# 测试模式（DEV_FLOW_TEST_MODE=1）允许 default 策略通过（测试环境覆盖探针）。
if [[ "$selection_source" == "default" && "${DEV_FLOW_TEST_MODE:-}" != "1" ]]; then
  /usr/bin/python3 - "$SESSION_ID" <<'PY'
import json
import sys
payload = {
    "producer": "review-health-probe",
    "schema_version": 1,
    "session_id": sys.argv[1],
    "status": "blocked",
    "transport": "none",
    "fallback": None,
    "evidence": "review_backend_default_policy_not_configured;run install-review-backend.sh to configure a review adapter",
    "selected_adapter": None,
    "selection_reason": "default_policy_blocked",
    "config_digest": "",
    "source": "default",
}
print(json.dumps(payload, ensure_ascii=False))
PY
  exit 1
fi

# 映射 adapter → transport + evidence
transport="none"
fallback=""
skill_path=""
evidence="review_backend_unavailable"

if [[ "$probe_status" != "available" ]]; then
  # 所有 adapter 不可用
  transport="none"
  status="blocked"
  evidence="review_backend_unavailable;reason=${probe_evidence}"
else
  status="available"
  case "$selected_adapter" in
    agent/openai-reviewer)
      transport="reviewer"
      evidence="reviewer_health_ok"
      ;;
    mcp/orchestrator)
      transport="mcp"
      evidence="orchestrator_mcp_health_ok"
      ;;
    skill/gstack)
      # gstack 无论是 primary 还是 fallback，都走机械 fallback 通道
      transport="fallback"
      fallback="gstack-review"
      # 从 probe_evidence 提取 skill 路径（格式：gstack_skill_present;<path>）
      skill_path="${probe_evidence#gstack_skill_present;}"
      if [[ "$skill_path" == "$probe_evidence" ]]; then
        skill_path=""
      fi
      if [[ -n "$skill_path" ]]; then
        evidence="fallback=gstack-review;skill=${skill_path};run=scripts/run-review-fallback.sh"
      else
        evidence="fallback=gstack-review;run=scripts/run-review-fallback.sh"
      fi
      # 如果是 fallback（primary 不可用），在 evidence 前加原因
      if [[ "$selection_reason" == primary_unavailable* ]]; then
        evidence="primary_unavailable;${evidence}"
      fi
      ;;
  esac
fi

/usr/bin/python3 - "$SESSION_ID" "$status" "$transport" "$fallback" "$skill_path" "$evidence" "$selected_adapter" "$selection_reason" "$config_digest" "$selection_source" <<'PY'
import json
import sys

session_id, status, transport, fallback, skill_path, evidence, selected_adapter, selection_reason, config_digest, selection_source = sys.argv[1:12]
payload = {
    "producer": "review-health-probe",
    "schema_version": 1,
    "session_id": session_id,
    "status": status,
    "transport": transport,
    "fallback": fallback or None,
    "evidence": evidence,
    "selected_adapter": selected_adapter,
    "selection_reason": selection_reason,
    "config_digest": config_digest,
    "source": selection_source,
}
if skill_path:
    payload["skill_path"] = skill_path
print(json.dumps(payload, ensure_ascii=False))
PY

if [[ "$status" == "available" ]]; then
  exit 0
fi
exit 1
