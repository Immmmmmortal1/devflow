#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions"

# 断言 exit code == 0（available 场景）
assert_exit_ok() {
  local rc="$1"
  [[ "$rc" -eq 0 ]] || { echo "FAIL: expected exit 0, got $rc" >&2; exit 1; }
}

# 断言 exit code != 0（blocked 场景）
assert_exit_blocked() {
  local rc="$1"
  [[ "$rc" -ne 0 ]] || { echo "FAIL: expected non-zero exit, got 0" >&2; exit 1; }
}

run_validate() {
  local session_id="$1"
  shift
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID="$session_id" \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run "$@"
}

assert_blocked() {
  local session_id="$1"
  local identity_json="$2"
  local expected_evidence="$3"
  local output exit_code=0
  output="$(DEV_FLOW_BRIDGE_IDENTITY_JSON="$identity_json" run_validate "$session_id")" || exit_code=$?
  /usr/bin/python3 - "$output" "$expected_evidence" "$exit_code" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
exit_code = int(sys.argv[3])
assert exit_code != 0, exit_code
assert payload["status"] == "blocked", payload
assert expected in payload["evidence"], payload
PY
}

assert_available() {
  local session_id="$1"
  local identity_json="$2"
  local output exit_code=0
  output="$(DEV_FLOW_BRIDGE_IDENTITY_JSON="$identity_json" run_validate "$session_id")" || exit_code=$?
  /usr/bin/python3 - "$output" "$session_id" "$exit_code" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
session_id = sys.argv[2]
exit_code = int(sys.argv[3])
assert exit_code == 0, exit_code
assert payload["status"] == "available", payload
assert payload["bridge_session_id"] == session_id, payload
PY
}

assert_blocked adapter-session '{"ok":true,"sessionID":"local"}' bridge_session_local
assert_blocked adapter-session '{"ok":true,"sessionID":"other-session"}' bridge_session_mismatch
assert_available adapter-session '{"ok":true,"sessionID":"adapter-session"}'

# 验证 URL 回退链：未设 DEV_FLOW_DEBUGBRIDGE_URL / BRIDGE_BASE_URL 时，从
# last-bridge.json 的 bridgeBaseURL 读取并 curl /debug/identity 成功。
# 1) 起一个本地 HTTP 假桥，仅响应 /debug/identity
FAKE_BRIDGE_DIR="$(/usr/bin/mktemp -d)"
FAKE_PORT_FILE="$FAKE_BRIDGE_DIR/port"
/usr/bin/python3 - "$FAKE_PORT_FILE" <<'PY' &
import http.server
import json
import socket
import sys
from pathlib import Path

port_file = Path(sys.argv[1])
# 让系统自动分配一个空闲端口，避免与 37777 等已用端口冲突
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
port_file.write_text(str(port))

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/debug/identity":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "sessionID": "last-bridge-session"}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
FAKE_BRIDGE_PID=$!

# 等待假桥端口文件就绪（最长 ~5s）
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$FAKE_PORT_FILE" ]] && break
  sleep 0.5
done
FAKE_PORT="$(/bin/cat "$FAKE_PORT_FILE")"
FAKE_URL="http://127.0.0.1:${FAKE_PORT}"

# 2) 在 mcp_root 下写 .tmp/lookdebug-mcp/last-bridge.json，bridgeBaseURL 指向假桥
MCP_ROOT_TMP="$(/usr/bin/mktemp -d)"
/bin/mkdir -p "$MCP_ROOT_TMP/.tmp/lookdebug-mcp"
/usr/bin/python3 - "$MCP_ROOT_TMP/.tmp/lookdebug-mcp/last-bridge.json" "$FAKE_URL" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "remotePort": 37777,
    "bundleID": "com.example.app",
    "sessionID": "last-bridge-session",
    "deviceUDID": "device-1",
    "bridgeBaseURL": sys.argv[2],
    "updatedAt": "2026-08-21T00:00:00Z",
}) + "\n")
PY

# 3) 不设 DEV_FLOW_DEBUGBRIDGE_URL / BRIDGE_BASE_URL，让 validate 走 last-bridge.json
exit_code=0
output="$(unset DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=last-bridge-session \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_TMP" \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
/usr/bin/python3 - "$output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
assert payload["status"] == "available", payload
assert payload["bridge_session_id"] == "last-bridge-session", payload
assert "matches_dev_flow" in payload["evidence"], payload
# 反向断言：evidence 不可泄漏 legacy 42671 端口号
assert "42671" not in payload["evidence"], payload
PY

# 4) 也覆盖 manifest 解析路径：不设 MCP_ROOT，从 .dev-flow/debugbridge-install.json 读 mcp_root
/bin/mkdir -p "$TMP_ROOT/.dev-flow"
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/debugbridge-install.json" "$MCP_ROOT_TMP" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "mcp_root": sys.argv[2],
    "pod_status": "present",
}) + "\n")
PY
exit_code=0
output="$(unset DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=last-bridge-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
/usr/bin/python3 - "$output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
assert payload["status"] == "available", payload
assert payload["bridge_session_id"] == "last-bridge-session", payload
PY

# 清理假桥与临时目录
kill "$FAKE_BRIDGE_PID" >/dev/null 2>&1 || true
wait "$FAKE_BRIDGE_PID" 2>/dev/null || true
/bin/rm -rf -- "$FAKE_BRIDGE_DIR" "$MCP_ROOT_TMP" "$TMP_ROOT/.dev-flow/debugbridge-install.json"

# ============================================================================
# 补充覆盖：URL 校验（远程 host 必须被忽略）+ debugbridge-mcp-root 路径解析
# ============================================================================

# 收集所有假桥 PID，EXIT 时一并清理
BRIDGE_PIDS=""
trap 'for __p in $BRIDGE_PIDS; do kill "$__p" >/dev/null 2>&1 || true; done; /bin/rm -rf -- "$TMP_ROOT"' EXIT

# 启动假桥：start_fake_bridge <identity> [bind_addr]
# 设置全局 FAKE_BRIDGE_PORT / FAKE_BRIDGE_PID / FAKE_BRIDGE_DIR / FAKE_BRIDGE_URL
start_fake_bridge() {
  local identity="$1"
  local bind_addr="${2:-127.0.0.1}"
  FAKE_BRIDGE_DIR="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
  local port_file="$FAKE_BRIDGE_DIR/port"
  /usr/bin/python3 - "$port_file" "$identity" "$bind_addr" <<'PY' &
import http.server
import json
import socket
import sys
from pathlib import Path

port_file, identity, bind_addr = sys.argv[1], sys.argv[2], sys.argv[3]
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind((bind_addr, 0))
port = sock.getsockname()[1]
sock.close()
Path(port_file).write_text(str(port))

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/debug/identity":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "sessionID": identity}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

http.server.HTTPServer((bind_addr, port), Handler).serve_forever()
PY
  FAKE_BRIDGE_PID=$!
  BRIDGE_PIDS="$BRIDGE_PIDS $FAKE_BRIDGE_PID"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$port_file" ]] && break
    sleep 0.5
  done
  FAKE_BRIDGE_PORT="$(/bin/cat "$port_file")"
  FAKE_BRIDGE_URL="http://${bind_addr}:${FAKE_BRIDGE_PORT}"
}

# 写 last-bridge.json：write_last_bridge <mcp_root> <bridge_base_url>
write_last_bridge() {
  local mcp_root="$1"
  local bridge_url="$2"
  /bin/mkdir -p "$mcp_root/.tmp/lookdebug-mcp"
  /usr/bin/python3 - "$mcp_root/.tmp/lookdebug-mcp/last-bridge.json" "$bridge_url" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "remotePort": 37777,
    "bundleID": "com.example.app",
    "sessionID": "last-bridge-session",
    "deviceUDID": "device-1",
    "bridgeBaseURL": sys.argv[2],
    "updatedAt": "2026-08-21T00:00:00Z",
}) + "\n")
PY
}

write_install_json() {
  local mcp_root="$1"
  /bin/mkdir -p "$TMP_ROOT/.dev-flow"
  /usr/bin/python3 - "$TMP_ROOT/.dev-flow/debugbridge-install.json" "$mcp_root" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "mcp_root": sys.argv[2],
    "pod_status": "present",
}) + "\n")
PY
}

assert_available_session() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
expected = sys.argv[2]
assert payload["status"] == "available", payload
assert payload.get("bridge_session_id") == expected, payload
PY
}

# 断言远程探针未被命中：若 status=available 且 sessionID=remote-should-not-reach，
# 说明校验放行了远程 host（FAIL）。
assert_remote_not_reached() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
if payload.get("status") == "available" and payload.get("bridge_session_id") == "remote-should-not-reach":
    raise AssertionError("remote host was curled: %s" % payload)
PY
}

# ---- 0) 直接单元测试 _bridge_url_is_loopback（不依赖网络）----
LOOPBACK_FN="$TMP_ROOT/loopback-fn.sh"
sed -n '/^_bridge_url_is_loopback()/,/^}/p' "$ROOT/scripts/validate-bridge-session.sh" > "$LOOPBACK_FN"
# shellcheck source=/dev/null
source "$LOOPBACK_FN"
expect_accept() {
  local rc
  set +e; _bridge_url_is_loopback "$1"; rc=$?; set -e
  [[ $rc -eq 0 ]] || { echo "FAIL: expected ACCEPT for '$1', got rc=$rc" >&2; exit 1; }
}
expect_reject() {
  local rc
  set +e; _bridge_url_is_loopback "$1"; rc=$?; set -e
  [[ $rc -ne 0 ]] || { echo "FAIL: expected REJECT for '$1', got rc=0" >&2; exit 1; }
}
expect_accept "http://127.0.0.1:37777/debug/identity"
expect_accept "http://127.0.0.1:1/"
expect_accept "http://LOCALHOST:1/"
expect_accept "http://localhost/"
expect_accept "http://[::1]:8080/debug/identity"
expect_accept "http://[fd8c:54e5:a969::1]:37777/debug/identity"
expect_accept "https://localhost:443/"
expect_reject "http://127.0.0.2:1/"
expect_reject "http://1.2.3.4:1/"
expect_reject "http://example.com/"
expect_reject "http://192.168.1.1/"
expect_reject "http://10.0.0.1/"
expect_reject "http://0.0.0.0:1/"
expect_reject "ftp://127.0.0.1/"
expect_reject "http://[::2]:80/"
expect_reject "http://[2001:4860:4860::8888]:443/"
expect_reject ""

# ---- 0b) 直接单元测试 _bridge_url_is_legacy_42671（不依赖网络）----
LEGACY_FN="$TMP_ROOT/legacy-fn.sh"
sed -n '/^_bridge_url_is_legacy_42671()/,/^}/p' "$ROOT/scripts/validate-bridge-session.sh" > "$LEGACY_FN"
# shellcheck source=/dev/null
source "$LEGACY_FN"
expect_legacy() {
  local rc
  set +e; _bridge_url_is_legacy_42671 "$1"; rc=$?; set -e
  [[ $rc -eq 0 ]] || { echo "FAIL: expected LEGACY for '$1', got rc=$rc" >&2; exit 1; }
}
expect_not_legacy() {
  local rc
  set +e; _bridge_url_is_legacy_42671 "$1"; rc=$?; set -e
  [[ $rc -ne 0 ]] || { echo "FAIL: expected NOT-legacy for '$1', got rc=0" >&2; exit 1; }
}
expect_legacy "http://127.0.0.1:42671/debug/identity"
expect_legacy "http://localhost:42671/"
expect_legacy "http://127.0.0.1:42671"
expect_legacy "https://127.0.0.1:42671/"
expect_not_legacy "http://127.0.0.1:37777/debug/identity"
expect_not_legacy "http://127.0.0.1:42672/"
expect_not_legacy "http://localhost/"
expect_not_legacy "http://127.0.0.1:1/"
expect_not_legacy ""
expect_not_legacy "http://example.com:8080/"

# ---- 1) 合法 loopback DEV_FLOW_DEBUGBRIDGE_URL / BRIDGE_BASE_URL 被使用（防校验过严）----
start_fake_bridge "env-url-session"
ENV_URL="$FAKE_BRIDGE_URL"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON BRIDGE_BASE_URL
  DEV_FLOW_DEBUGBRIDGE_URL="$ENV_URL" \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=env-url-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "env-url-session"

start_fake_bridge "base-url-session"
BASE_URL="$FAKE_BRIDGE_URL"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL
  BRIDGE_BASE_URL="$BASE_URL" \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=base-url-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "base-url-session"

# ---- 远程探针：0.0.0.0 绑定 + LAN IP 访问，用于证明"远程 host 被忽略"----
# 若校验错误放行远程 host，curl 会命中此探针并返回 "remote-should-not-reach"。
LAN_IP="$(/usr/bin/python3 - <<'PY'
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0])
except Exception:
    pass
PY
)"
REMOTE_PROBE_URL=""
if [[ -n "$LAN_IP" ]]; then
  start_fake_bridge "remote-should-not-reach" "0.0.0.0"
  REMOTE_PROBE_URL="http://${LAN_IP}:${FAKE_BRIDGE_PORT}"
  # 自检：经 LAN IP 必须能命中 0.0.0.0 绑定的探针，否则跳过远程类用例
  if ! /usr/bin/curl -fsS --max-time 2 "${REMOTE_PROBE_URL}/debug/identity" 2>/dev/null \
      | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("sessionID")=="remote-should-not-reach" else 1)' 2>/dev/null; then
    REMOTE_PROBE_URL=""
  fi
fi

# 准备一个合法 loopback 假桥（last-bridge 来源），返回 "last-bridge-session"
start_fake_bridge "last-bridge-session"
LAST_BRIDGE_URL="$FAKE_BRIDGE_URL"

# ---- 2) 远程 host 的 DEV_FLOW_DEBUGBRIDGE_URL 被忽略，回退到 last-bridge ----
MCP_ROOT_A="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
write_last_bridge "$MCP_ROOT_A" "$LAST_BRIDGE_URL"
if [[ -n "$REMOTE_PROBE_URL" ]]; then
  exit_code=0
  output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON BRIDGE_BASE_URL
    DEV_FLOW_DEBUGBRIDGE_URL="$REMOTE_PROBE_URL" \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_A" \
    DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=last-bridge-session \
      /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
  assert_exit_ok "$exit_code"
  assert_available_session "$output" "last-bridge-session"
  assert_remote_not_reached "$output"
else
  echo "SKIP: remote DEV_FLOW_DEBUGBRIDGE_URL fallback test (no LAN IP / remote probe)" >&2
fi

# ---- 3) last-bridge.json 里远程 host 被忽略，无候选 URL 时不再回退旧 42671 ----
# 旧逻辑会回退到 http://127.0.0.1:42671；新版（>= 0.1.14）禁止回退，应输出
# bridge_base_url_unavailable_run_mcp_ensure_ports，且不命中远程探针。
MCP_ROOT_B="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
if [[ -n "$REMOTE_PROBE_URL" ]]; then
  write_last_bridge "$MCP_ROOT_B" "$REMOTE_PROBE_URL"
  exit_code=0
  output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
      UI_DEBUGBRIDGE_MCP_ROOT
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_B" \
    DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=whatever-session \
      /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
  assert_exit_blocked "$exit_code"
  assert_remote_not_reached "$output"
  /usr/bin/python3 - "$output" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
# 新版：远程 host 被忽略后无候选 URL → 明确提示跑 MCP ensure_ports，而非含糊的 unreachable
assert payload["status"] == "blocked", payload
assert payload["evidence"] == "bridge_base_url_unavailable_run_mcp_ensure_ports", payload
# 反向断言：不可回退到 legacy 42671
assert "42671" not in payload["evidence"], payload
PY
else
  echo "SKIP: remote last-bridge.json fallback test (no LAN IP / remote probe)" >&2
fi

# ---- 3b) 无任何候选 URL（无 env / 无 last-bridge.json / 无 mcp root）----
# 新版（>= 0.1.14）禁止回退旧 42671。必须输出 bridge_base_url_unavailable_run_mcp_ensure_ports，
# 而不是含糊的 bridge_identity_unreachable，让主流程给出更准确的 evidence。
# 用一个全新空目录做 project root，确保 install.json / debugbridge-mcp-root 都不存在。
NO_CFG_ROOT="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
   DEV_FLOW_PROJECT_ROOT="$NO_CFG_ROOT" DEV_FLOW_SESSION_ID=no-url-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_blocked "$exit_code"
/usr/bin/python3 - "$output" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["status"] == "blocked", payload
assert payload["evidence"] == "bridge_base_url_unavailable_run_mcp_ensure_ports", payload
# 反向断言：不可回退到 legacy 42671，也不可输出含糊的 bridge_identity_unreachable
assert "42671" not in payload["evidence"], payload
assert "bridge_identity_unreachable" not in payload["evidence"], payload
PY

# ---- 3c) last-bridge.json 存在但 bridgeBaseURL 缺失 → 仍属"无候选 URL"----
MCP_ROOT_NO_URL="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
/bin/mkdir -p "$MCP_ROOT_NO_URL/.tmp/lookdebug-mcp"
/usr/bin/python3 - "$MCP_ROOT_NO_URL/.tmp/lookdebug-mcp/last-bridge.json" <<'PY'
import json, sys
from pathlib import Path
# bridgeBaseURL 字段缺失（或为空），不应回退到旧 42671
Path(sys.argv[1]).write_text(json.dumps({
    "remotePort": 37777,
    "bundleID": "com.example.app",
    "sessionID": "last-bridge-session",
    "deviceUDID": "device-1",
    "updatedAt": "2026-08-21T00:00:00Z",
}) + "\n")
PY
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=no-url-session \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_NO_URL" \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_blocked "$exit_code"
/usr/bin/python3 - "$output" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["status"] == "blocked", payload
assert payload["evidence"] == "bridge_base_url_unavailable_run_mcp_ensure_ports", payload
assert "42671" not in payload["evidence"], payload
PY

# ---- 3d) 显式 env 指向 legacy 42671 → 立即拒绝，绝不 curl 旧端口 ----
# 启动假桥监听 42671（如果端口空闲），用 hit 文件证明它从未被 curl。
# 若 42671 被占用无法绑定，则退化为只验证输出不含 available（仍保证不 curl）。
LEGACY_HIT_FILE="$TMP_ROOT/legacy-42671-hit"
LEGACY_42671_STARTED=0
LEGACY_42671_PID=""
if /usr/bin/python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',42671)); s.close()" 2>/dev/null; then
  /usr/bin/python3 - "$LEGACY_HIT_FILE" <<'PY' &
import http.server
import json
import sys
from pathlib import Path

hit_file = Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/debug/identity":
            hit_file.write_text("hit")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "sessionID": "legacy-42671-should-not-reach"}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 42671), Handler).serve_forever()
PY
  LEGACY_42671_PID=$!
  BRIDGE_PIDS="$BRIDGE_PIDS $LEGACY_42671_PID"
  sleep 0.5
  LEGACY_42671_STARTED=1
fi

# 3d-1: BRIDGE_BASE_URL=http://127.0.0.1:42671 必须被拒绝
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL
  BRIDGE_BASE_URL="http://127.0.0.1:42671"
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=legacy-env-test \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_blocked "$exit_code"
/usr/bin/python3 - "$output" "$LEGACY_HIT_FILE" "$LEGACY_42671_STARTED" <<'PY'
import json, sys
from pathlib import Path
payload = json.loads(sys.argv[1])
hit_file = Path(sys.argv[2])
started = int(sys.argv[3])
assert payload["status"] == "blocked", payload
ev = payload["evidence"]
# 必须明确指出 legacy 42671 被拒绝（或至少不是 available）
assert "legacy_42671" in ev or "unavailable" in ev, payload
assert "42671" not in ev or "legacy_42671" in ev, payload  # 允许 evidence 里出现 legacy_42671 标识
# 如果启动了 42671 假桥，必须证明它没被 curl
if started:
    assert not hit_file.exists(), "legacy 42671 port was curled! hit file exists"
PY

# 3d-2: DEV_FLOW_DEBUGBRIDGE_URL=http://localhost:42671 也必须被拒绝
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON BRIDGE_BASE_URL
  DEV_FLOW_DEBUGBRIDGE_URL="http://localhost:42671/debug/identity"
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=legacy-env-test \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_blocked "$exit_code"
/usr/bin/python3 - "$output" "$LEGACY_HIT_FILE" "$LEGACY_42671_STARTED" <<'PY'
import json, sys
from pathlib import Path
payload = json.loads(sys.argv[1])
hit_file = Path(sys.argv[2])
started = int(sys.argv[3])
assert payload["status"] == "blocked", payload
ev = payload["evidence"]
assert "legacy_42671" in ev or "unavailable" in ev, payload
if started:
    assert not hit_file.exists(), "legacy 42671 port was curled! hit file exists"
PY

# 3d-3: last-bridge.json 里 bridgeBaseURL 指向 42671 → 被跳过（不走 env 拒绝路径，
# 而是作为无效候选跳过，最终输出 unavailable）。同样不能 curl 42671。
MCP_ROOT_LEGACY="$(/usr/bin/mktemp -d -p "$TMP_ROOT")"
write_last_bridge "$MCP_ROOT_LEGACY" "http://127.0.0.1:42671"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_LEGACY" \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=legacy-last-bridge-test \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_blocked "$exit_code"
/usr/bin/python3 - "$output" "$LEGACY_HIT_FILE" "$LEGACY_42671_STARTED" <<'PY'
import json, sys
from pathlib import Path
payload = json.loads(sys.argv[1])
hit_file = Path(sys.argv[2])
started = int(sys.argv[3])
assert payload["status"] == "blocked", payload
# last-bridge.json 里的 42671 被跳过 → 无候选 → unavailable
assert payload["evidence"] == "bridge_base_url_unavailable_run_mcp_ensure_ports", payload
if started:
    assert not hit_file.exists(), "legacy 42671 port was curled! hit file exists"
PY

# 清理 42671 假桥
if [[ -n "$LEGACY_42671_PID" ]]; then
  kill "$LEGACY_42671_PID" >/dev/null 2>&1 || true
  wait "$LEGACY_42671_PID" 2>/dev/null || true
fi

# ---- 4) debugbridge-mcp-root plain text 分支可用，且路径含空格也可用 ----
# 强制走 plain text 分支：删掉 install.json，不设任何 mcp root 环境变量
/bin/rm -f -- "$TMP_ROOT/.dev-flow/debugbridge-install.json"
MCP_ROOT_WITH_SPACES="$TMP_ROOT/mcp root with spaces"
write_last_bridge "$MCP_ROOT_WITH_SPACES" "$LAST_BRIDGE_URL"
# plain text 文件首尾带空白/换行，验证只 strip 首尾、保留路径内部空格
printf '  %s\n\n' "$MCP_ROOT_WITH_SPACES" > "$TMP_ROOT/.dev-flow/debugbridge-mcp-root"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=last-bridge-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "last-bridge-session"
/bin/rm -f -- "$TMP_ROOT/.dev-flow/debugbridge-mcp-root"

# ---- 5) 环境变量优先级：env > install.json > plain text 仍正确 ----
start_fake_bridge "mcpA-session"
MCP_ROOT_ENV="$TMP_ROOT/mcp-env"
write_last_bridge "$MCP_ROOT_ENV" "$FAKE_BRIDGE_URL"
start_fake_bridge "mcpB-session"
MCP_ROOT_INSTALL="$TMP_ROOT/mcp-install"
write_last_bridge "$MCP_ROOT_INSTALL" "$FAKE_BRIDGE_URL"
start_fake_bridge "mcpC-session"
MCP_ROOT_PLAIN="$TMP_ROOT/mcp-plain"
write_last_bridge "$MCP_ROOT_PLAIN" "$FAKE_BRIDGE_URL"

# 5a: env (A) + install.json (B) + plain text (C) 同时存在 -> 用 env (A)
printf '%s\n' "$MCP_ROOT_PLAIN" > "$TMP_ROOT/.dev-flow/debugbridge-mcp-root"
write_install_json "$MCP_ROOT_INSTALL"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_DEBUGBRIDGE_MCP_ROOT="$MCP_ROOT_ENV" \
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=mcpA-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "mcpA-session"

# 5b: 去掉 env，保留 install.json (B) + plain text (C) -> 用 install.json (B)
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=mcpB-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "mcpB-session"

# 5c: 去掉 install.json，只剩 plain text (C) -> 用 plain text (C)
/bin/rm -f -- "$TMP_ROOT/.dev-flow/debugbridge-install.json"
exit_code=0
output="$(unset DEV_FLOW_BRIDGE_IDENTITY_JSON DEV_FLOW_DEBUGBRIDGE_URL BRIDGE_BASE_URL \
    DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT
  DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=mcpC-session \
    /bin/bash "$ROOT/scripts/validate-bridge-session.sh" run)" || exit_code=$?
assert_exit_ok "$exit_code"
assert_available_session "$output" "mcpC-session"
/bin/rm -f -- "$TMP_ROOT/.dev-flow/debugbridge-mcp-root"

# 停掉本节所有假桥（trap 也会在 EXIT 时再 kill 一次，这里提前清理）
for __p in $BRIDGE_PIDS; do kill "$__p" >/dev/null 2>&1 || true; done
wait 2>/dev/null || true
BRIDGE_PIDS=""

if DEV_FLOW_PROJECT_ROOT="$TMP_ROOT" DEV_FLOW_SESSION_ID=local CURSOR_AGENT=1 \
  /bin/bash "$ROOT/scripts/record-app-launch-report.sh" record >/dev/null 2>&1; then
  echo "FAIL: record-app-launch allowed local session inside Cursor" >&2
  exit 1
fi

echo "PASS: validate-bridge-session rejects local/mismatch and accepts matching session"
