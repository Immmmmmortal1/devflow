#!/usr/bin/env bash
set -euo pipefail

# 覆盖 app-launch report v2 schema 的不可伪造契约（Finding 1）：
# 1. v1 报告被拒绝（schema_version 必须为 2）
# 2. v2 wired（build_run_device + wired）被接受
# 3. v2 simulator（build_run_sim + simulator）被接受
# 4. v2 交叉不匹配（build_run_device + simulator）被拒绝
# 5. v2 交叉不匹配（build_run_sim + wired）被拒绝
# 6. v2 缺 build_run_action 被拒绝
# 7. v2 无效 build_run_action 被拒绝
# 8. v2 缺 build_run_result 被拒绝

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

write_report() {
  local file="$1"
  shift
  /usr/bin/python3 - "$file" "$@" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps(json.loads(sys.argv[2])) + "\n")
PY
}

record() {
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=schema-test \
    /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$1" 2>/dev/null
}

record_stdin() {
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=schema-test \
    /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report - 2>/dev/null
}

# ── 场景 1：v1 报告被拒绝 ──
write_report "$TMP_ROOT/v1.json" '{"producer":"XcodeBuildMCP","schema_version":1,"session_id":"schema-test","status":"available","build_run_device":"success","device_transport":"wired","app_launched":true,"build_id":"b1","device_id":"d1"}'
if record "$TMP_ROOT/v1.json" >/dev/null 2>&1; then
  echo "FAIL: v1 report should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 1 — v1 report rejected"

# ── 场景 2：v2 wired 被接受 ──
write_report "$TMP_ROOT/v2-wired.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_device","build_run_result":"success","device_transport":"wired","app_launched":true,"build_id":"b2","device_id":"d2"}'
if ! record "$TMP_ROOT/v2-wired.json" >/dev/null; then
  echo "FAIL: v2 wired report should be accepted" >&2
  exit 1
fi
echo "PASS: scenario 2 — v2 wired report accepted"

# ── 场景 3：v2 simulator 被接受 ──
write_report "$TMP_ROOT/v2-sim.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_sim","build_run_result":"success","device_transport":"simulator","app_launched":true,"build_id":"b3","device_id":"sim3"}'
if ! record "$TMP_ROOT/v2-sim.json" >/dev/null; then
  echo "FAIL: v2 simulator report should be accepted" >&2
  exit 1
fi
echo "PASS: scenario 3 — v2 simulator report accepted"

# ── 场景 4：v2 交叉不匹配（build_run_device + simulator）被拒绝 ──
write_report "$TMP_ROOT/mismatch-dev-sim.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_device","build_run_result":"success","device_transport":"simulator","app_launched":true,"build_id":"b4","device_id":"d4"}'
if record "$TMP_ROOT/mismatch-dev-sim.json" >/dev/null 2>&1; then
  echo "FAIL: build_run_device + simulator mismatch should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 4 — build_run_device + simulator mismatch rejected"

# ── 场景 5：v2 交叉不匹配（build_run_sim + wired）被拒绝 ──
write_report "$TMP_ROOT/mismatch-sim-wired.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_sim","build_run_result":"success","device_transport":"wired","app_launched":true,"build_id":"b5","device_id":"d5"}'
if record "$TMP_ROOT/mismatch-sim-wired.json" >/dev/null 2>&1; then
  echo "FAIL: build_run_sim + wired mismatch should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 5 — build_run_sim + wired mismatch rejected"

# ── 场景 6：v2 缺 build_run_action 被拒绝 ──
write_report "$TMP_ROOT/no-action.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_result":"success","device_transport":"wired","app_launched":true,"build_id":"b6","device_id":"d6"}'
if record "$TMP_ROOT/no-action.json" >/dev/null 2>&1; then
  echo "FAIL: missing build_run_action should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 6 — missing build_run_action rejected"

# ── 场景 7：v2 无效 build_run_action 被拒绝 ──
write_report "$TMP_ROOT/bad-action.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_something","build_run_result":"success","device_transport":"wired","app_launched":true,"build_id":"b7","device_id":"d7"}'
if record "$TMP_ROOT/bad-action.json" >/dev/null 2>&1; then
  echo "FAIL: invalid build_run_action should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 7 — invalid build_run_action rejected"

# ── 场景 8：v2 缺 build_run_result 被拒绝 ──
write_report "$TMP_ROOT/no-result.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_device","device_transport":"wired","app_launched":true,"build_id":"b8","device_id":"d8"}'
if record "$TMP_ROOT/no-result.json" >/dev/null 2>&1; then
  echo "FAIL: missing build_run_result should be rejected" >&2
  exit 1
fi
echo "PASS: scenario 8 — missing build_run_result rejected"

# ── 场景 9：app-launch status 验证 v2 wired 报告 ──
# 先 record 一个合法 v2 wired 报告，再用 status 读取校验
write_report "$TMP_ROOT/v2-ok.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_device","build_run_result":"success","device_transport":"wired","app_launched":true,"build_id":"b9","device_id":"d9"}'
record "$TMP_ROOT/v2-ok.json" >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=schema-test \
  /bin/bash "$ROOT/scripts/dev-flow.sh" app-launch status >/dev/null; then
  echo "FAIL: app-launch status rejected a valid v2 wired report" >&2
  exit 1
fi
echo "PASS: scenario 9 — app-launch status accepts v2 wired report"

# ── 场景 10：app-launch status 验证 v2 simulator 报告 ──
write_report "$TMP_ROOT/v2-sim-ok.json" '{"producer":"XcodeBuildMCP","schema_version":2,"session_id":"schema-test","status":"available","build_run_action":"build_run_sim","build_run_result":"success","device_transport":"simulator","app_launched":true,"build_id":"b10","device_id":"sim10"}'
record "$TMP_ROOT/v2-sim-ok.json" >/dev/null
if ! DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=schema-test \
  /bin/bash "$ROOT/scripts/dev-flow.sh" app-launch status >/dev/null; then
  echo "FAIL: app-launch status rejected a valid v2 simulator report" >&2
  exit 1
fi
echo "PASS: scenario 10 — app-launch status accepts v2 simulator report"

echo "PASS: app-launch report v2 schema (scenarios 1-10) all validated"
