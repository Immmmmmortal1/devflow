#!/usr/bin/env bash
# record-app-launch-report.sh symlink 安全测试
# 验证：sessions 目录 symlink、target 文件 symlink、路径越界 → fail closed
# 正常端到端写入 → 成功
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

# start 一个 session
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=symlink-test \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "symlink test" >/dev/null

run_record() {
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=symlink-test \
    /bin/bash "$ROOT/scripts/record-app-launch-report.sh" "$@"
}

write_payload() {
  local path="$1"
  /usr/bin/python3 -c "
import json, sys
from pathlib import Path
payload = {
    'producer': 'XcodeBuildMCP', 'schema_version': 2, 'session_id': 'symlink-test',
    'status': 'available', 'build_run_action': 'build_run_device',
    'build_run_result': 'success',
    'device_transport': 'wired', 'app_launched': True,
    'build_id': 'build-symlink-1', 'device_id': 'device-symlink-1',
}
Path(sys.argv[1]).write_text(json.dumps(payload) + '\n')
" "$path"
}

# ============================================================
# 1. 正常端到端写入 → 成功
# ============================================================
echo "=== test 1: normal end-to-end write ==="
write_payload "$TMP_ROOT/valid.json"
run_record record --report "$TMP_ROOT/valid.json" >/dev/null

report_file="$TMP_ROOT/.dev-flow/sessions/symlink-test.app-launch.json"
[[ -f "$report_file" ]] || { echo "FAIL: report file not created" >&2; exit 1; }
/usr/bin/grep -q "build-symlink-1" "$report_file" || {
  echo "FAIL: report content missing build_id" >&2; exit 1
}
echo "OK: normal end-to-end write succeeds"

# ============================================================
# 2. sessions 目录是 symlink → fail closed
# ============================================================
echo "=== test 2: sessions dir is symlink → fail closed ==="
TMP_ROOT2="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT2/.dev-flow/real-sessions"
# 创建 symlink: sessions → real-sessions
ln -s real-sessions "$TMP_ROOT2/.dev-flow/sessions"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT2" DEV_FLOW_SESSION_ID=sym2 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym2" >/dev/null 2>&1 || true

write_payload "$TMP_ROOT2/valid2.json"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT2" DEV_FLOW_SESSION_ID=sym2 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT2/valid2.json" 2>/dev/null; then
  echo "FAIL: symlinked sessions dir should fail closed" >&2
  exit 1
fi
echo "OK: symlinked sessions dir → fail closed"

/bin/rm -rf -- "$TMP_ROOT2"

# ============================================================
# 3. target 文件是 symlink → fail closed
# ============================================================
echo "=== test 3: target file is symlink → fail closed ==="
TMP_ROOT3="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT3/.dev-flow/sessions"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT3" DEV_FLOW_SESSION_ID=sym3 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym3" >/dev/null

# 创建 symlink target: symlink-test.app-launch.json → /tmp/evil.json
EVIL_FILE="$(/usr/bin/mktemp)"
printf 'evil\n' > "$EVIL_FILE"
ln -s "$EVIL_FILE" "$TMP_ROOT3/.dev-flow/sessions/sym3.app-launch.json"

write_payload "$TMP_ROOT3/valid3.json"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT3" DEV_FLOW_SESSION_ID=sym3 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT3/valid3.json" 2>/dev/null; then
  echo "FAIL: symlinked target file should fail closed" >&2
  exit 1
fi

# 验证 evil 文件未被写入
content="$(/bin/cat "$EVIL_FILE")"
[[ "$content" == "evil" ]] || {
  echo "FAIL: evil symlink target was overwritten" >&2
  exit 1
}
echo "OK: symlinked target file → fail closed (evil target not written)"

/bin/rm -rf -- "$TMP_ROOT3" "$EVIL_FILE"

# ============================================================
# 4. .dev-flow 目录是 symlink → fail closed
# ============================================================
echo "=== test 4: .dev-flow dir is symlink → fail closed ==="
TMP_ROOT4="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT4/real-dev-flow/sessions"
ln -s real-dev-flow "$TMP_ROOT4/.dev-flow"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT4" DEV_FLOW_SESSION_ID=sym4 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym4" >/dev/null 2>&1 || true

write_payload "$TMP_ROOT4/valid4.json"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT4" DEV_FLOW_SESSION_ID=sym4 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT4/valid4.json" 2>/dev/null; then
  echo "FAIL: symlinked .dev-flow dir should fail closed" >&2
  exit 1
fi
echo "OK: symlinked .dev-flow dir → fail closed"

/bin/rm -rf -- "$TMP_ROOT4"

# ============================================================
# 5. 路径越界（report 路径在 .dev-flow 之外）→ fail closed
# ============================================================
echo "=== test 5: path outside .dev-flow → fail closed ==="
# safe_atomic_write_json 的 trusted_root 是 project/.dev-flow
# 但 report_path = $STATE_DIR/$SESSION_ID.app-launch.json = project/.dev-flow/sessions/...
# 所以正常路径不会越界。这里测试 sessions symlink 指向外部的情况
TMP_ROOT5="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT5/.dev-flow"
EXTERNAL_DIR="$(/usr/bin/mktemp -d)"
ln -s "$EXTERNAL_DIR" "$TMP_ROOT5/.dev-flow/sessions"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT5" DEV_FLOW_SESSION_ID=sym5 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym5" >/dev/null 2>&1 || true

write_payload "$TMP_ROOT5/valid5.json"
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT5" DEV_FLOW_SESSION_ID=sym5 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record --report "$TMP_ROOT5/valid5.json" 2>/dev/null; then
  echo "FAIL: sessions symlink to external dir should fail closed" >&2
  exit 1
fi

# 验证外部目录未被写入
[[ ! -f "$EXTERNAL_DIR/sym5.app-launch.json" ]] || {
  echo "FAIL: external dir was written through symlink" >&2
  exit 1
}
echo "OK: sessions symlink to external dir → fail closed (external not written)"

/bin/rm -rf -- "$TMP_ROOT5" "$EXTERNAL_DIR"

# ============================================================
# 6. stdin 写入正常 → 成功（验证 safe_atomic_write_json 不破坏 stdin 支持）
# ============================================================
echo "=== test 6: stdin write with safe_atomic_write_json ==="
write_payload "$TMP_ROOT/stdin-payload.json"
run_record record --report - < "$TMP_ROOT/stdin-payload.json" >/dev/null

/usr/bin/grep -q "build-symlink-1" "$TMP_ROOT/.dev-flow/sessions/symlink-test.app-launch.json" || {
  echo "FAIL: stdin write did not produce correct report" >&2
  exit 1
}
echo "OK: stdin write succeeds with safe_atomic_write_json"

echo ""
echo "PASS: record-app-launch-report.sh symlink security (sessions/target/dir symlink + external + stdin)"
