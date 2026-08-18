#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

# record-app-launch-report.sh 需要 session_id，先 start 一个 session
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=record-test \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "record test" >/dev/null

run_record() {
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=record-test \
    /bin/bash "$ROOT/scripts/record-app-launch-report.sh" "$@"
}

write_payload() {
  # $1=path $2=build_id $3=device_id（device_id 缺省时省略字段）
  local path="$1"
  local build_id="$2"
  local device_id="${3:-}"
  /usr/bin/python3 - "$path" "$build_id" "$device_id" <<'PY'
import json, sys
from pathlib import Path
path, build_id, device_id = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "producer": "XcodeBuildMCP", "schema_version": 1, "session_id": "record-test",
    "status": "available", "build_run_device": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": build_id,
}
if device_id:
    payload["device_id"] = device_id
Path(path).write_text(json.dumps(payload) + "\n")
PY
}

# 1. 无 --report → exit 非零
if run_record record >/dev/null 2>&1; then
  echo "FAIL: record without --report should fail" >&2
  exit 1
fi

# 2. 缺 build_id → exit 非零
/usr/bin/python3 - "$TMP_ROOT/missing-build-id.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 1, "session_id": "record-test",
    "status": "available", "build_run_device": "success",
    "device_transport": "wired", "app_launched": True,
    "device_id": "00008110-001A1B2C3D4E5",
}) + "\n")
PY
if run_record record --report "$TMP_ROOT/missing-build-id.json" >/dev/null 2>&1; then
  echo "FAIL: record with missing build_id should fail" >&2
  exit 1
fi

# 3. build_id 占位值（unknown / "N/A " / "-"）→ exit 非零（注意 strip 后判断）
for placeholder in unknown "N/A " "-"; do
  write_payload "$TMP_ROOT/placeholder.json" "$placeholder" "00008110-001A1B2C3D4E5"
  if run_record record --report "$TMP_ROOT/placeholder.json" >/dev/null 2>&1; then
    echo "FAIL: record with placeholder build_id='$placeholder' should fail" >&2
    exit 1
  fi
done

# 4. device_id 占位值同样被拒
write_payload "$TMP_ROOT/placeholder-device.json" "build-2026-08-18-abc" "unknown"
if run_record record --report "$TMP_ROOT/placeholder-device.json" >/dev/null 2>&1; then
  echo "FAIL: record with placeholder device_id should fail" >&2
  exit 1
fi

# 5. 合法 payload（含真实 build_id/device_id）→ exit 0
write_payload "$TMP_ROOT/valid.json" "build-2026-08-18-abc123" "00008110-001A1B2C3D4E5"
run_record record --report "$TMP_ROOT/valid.json" >/dev/null

# 6. session_id 不匹配 → exit 非零
/usr/bin/python3 - "$TMP_ROOT/wrong-session.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "producer": "XcodeBuildMCP", "schema_version": 1, "session_id": "other-session",
    "status": "available", "build_run_device": "success",
    "device_transport": "wired", "app_launched": True,
    "build_id": "build-1", "device_id": "device-1",
}) + "\n")
PY
if run_record record --report "$TMP_ROOT/wrong-session.json" >/dev/null 2>&1; then
  echo "FAIL: record with mismatched session_id should fail" >&2
  exit 1
fi

echo "PASS: record-app-launch-report.sh enforces --report and build_id/device_id non-placeholder"
