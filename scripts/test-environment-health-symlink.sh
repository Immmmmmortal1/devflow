#!/usr/bin/env bash
# environment-health-check.sh sessions symlink 安全测试
# 验证：STATE_DIR/sessions symlink → fail closed；系统临时目录接收报告；无外部临时文件
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# ok-probe：输出 available + selection binding
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-sym-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

run_for() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

run_env_health() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    DEV_FLOW_TEST_MODE=1 \
    DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_APP_LAUNCH_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    DEV_FLOW_FIGMA_REST_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run "$@"
}

# ============================================================
# 1. 正常端到端：系统临时目录接收报告，state 通过 safe_atomic_write_json 落盘
# ============================================================
echo "=== test 1: normal end-to-end with system temp REPORT_FILE ==="
run_for sym-test start --type feature --task "symlink test" >/dev/null
run_for sym-test confirm-plan >/dev/null
run_env_health sym-test >/dev/null

state_file="$TMP_ROOT/.dev-flow/sessions/sym-test.json"
[[ -f "$state_file" ]] || { echo "FAIL: state file not created" >&2; exit 1; }
/usr/bin/grep -q '"environment_health"' "$state_file" || {
  echo "FAIL: environment_health not in state" >&2; exit 1
}
echo "OK: normal end-to-end succeeds with system temp REPORT_FILE"

# ============================================================
# 2. sessions 目录是 symlink → fail closed
# ============================================================
echo "=== test 2: sessions dir is symlink → fail closed ==="
TMP_ROOT2="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT2/.dev-flow/real-sessions"
ln -s real-sessions "$TMP_ROOT2/.dev-flow/sessions"

# 先正常 start + confirm（在 real-sessions 中创建 session）
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT2" DEV_FLOW_SESSION_ID=sym2 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym2" >/dev/null 2>&1 || true
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT2" DEV_FLOW_SESSION_ID=sym2 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null 2>&1 || true

# 运行 environment-health-check → 应 fail closed（sessions 是 symlink）
if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT2" DEV_FLOW_SESSION_ID=sym2 \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run 2>/dev/null; then
  echo "FAIL: symlinked sessions dir should fail closed" >&2
  exit 1
fi
echo "OK: symlinked sessions dir → fail closed"

/bin/rm -rf -- "$TMP_ROOT2"

# ============================================================
# 3. sessions 目录 symlink 指向外部目录 → fail closed，外部无临时文件
# ============================================================
echo "=== test 3: sessions symlink to external dir → fail closed, no external temp ==="
TMP_ROOT3="$(/usr/bin/mktemp -d)"
EXTERNAL_DIR="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT3/.dev-flow"
ln -s "$EXTERNAL_DIR" "$TMP_ROOT3/.dev-flow/sessions"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT3" DEV_FLOW_SESSION_ID=sym3 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym3" >/dev/null 2>&1 || true
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT3" DEV_FLOW_SESSION_ID=sym3 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null 2>&1 || true

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT3" DEV_FLOW_SESSION_ID=sym3 \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run 2>/dev/null; then
  echo "FAIL: sessions symlink to external should fail closed" >&2
  exit 1
fi

# 验证外部目录无临时文件（environment report 不应泄漏到外部）
external_files="$(/bin/ls -A "$EXTERNAL_DIR" 2>/dev/null || true)"
if [[ -n "$external_files" ]]; then
  echo "FAIL: external dir has temp files: $external_files" >&2
  exit 1
fi
echo "OK: sessions symlink to external → fail closed (no external temp files)"

/bin/rm -rf -- "$TMP_ROOT3" "$EXTERNAL_DIR"

# ============================================================
# 4. .dev-flow 目录是 symlink → safe_atomic_write_json fail closed
# ============================================================
echo "=== test 4: .dev-flow dir is symlink → fail closed ==="
TMP_ROOT4="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$TMP_ROOT4/real-dev-flow/sessions"
ln -s real-dev-flow "$TMP_ROOT4/.dev-flow"

DEV_FLOW_PROJECT_ROOT="$TMP_ROOT4" DEV_FLOW_SESSION_ID=sym4 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" start --type feature --task "sym4" >/dev/null 2>&1 || true
DEV_FLOW_PROJECT_ROOT="$TMP_ROOT4" DEV_FLOW_SESSION_ID=sym4 \
  /bin/bash "$ROOT/scripts/dev-flow-session.sh" confirm-plan >/dev/null 2>&1 || true

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT4" DEV_FLOW_SESSION_ID=sym4 \
  DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run 2>/dev/null; then
  echo "FAIL: symlinked .dev-flow should fail closed" >&2
  exit 1
fi
echo "OK: symlinked .dev-flow → fail closed"

/bin/rm -rf -- "$TMP_ROOT4"

echo ""
echo "PASS: environment-health-check.sh symlink security (sessions/dir symlink + external + no temp leak)"
