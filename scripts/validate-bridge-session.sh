#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
# shellcheck source=lib/dev-flow-paths.sh
source "$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/lib/dev-flow-paths.sh"
dev_flow_load_paths "$SCRIPT_PATH"
# shellcheck source=resolve-dev-flow-session-id.sh
source "$(dev_flow_script_path resolve-dev-flow-session-id.sh)"
SESSION_ID="$(resolve_dev_flow_session_id)" || exit $?

usage() {
  cat <<'EOF'
Usage:
  scripts/validate-bridge-session.sh run

Validate that the in-App DebugBridge /debug/identity sessionID matches the current dev-flow session.
Rejects bridge session "local" when the dev-flow session is not "local".

Output: one JSON object on stdout with status available|blocked.
Tests may set DEV_FLOW_BRIDGE_IDENTITY_JSON instead of calling /identity.

Bridge URL resolution order (first VALID local/CoreDevice URL wins; invalid entries are skipped):
  1. DEV_FLOW_DEBUGBRIDGE_URL
  2. BRIDGE_BASE_URL
  3. bridgeBaseURL in <mcp_root>/.tmp/lookdebug-mcp/last-bridge.json

新版端口语义（UI-dbugbridge-mcp >= 0.1.14）：
  - App remote 默认端口 37777（由 App 侧 DebugBridge 监听）
  - CoreDevice 场景应使用 MCP ensure_ports/ping 返回并记录的 bridgeBaseURL
  - iproxy 场景使用动态 localPort（由 MCP 决定，不要再假设固定端口）
  - 禁止回退旧 legacy fixed port 42671；无候选 URL 时输出
    bridge_base_url_unavailable_run_mcp_ensure_ports，提示先跑 MCP ensure_ports
  - 显式 env (DEV_FLOW_DEBUGBRIDGE_URL / BRIDGE_BASE_URL) 指向 42671 时，
    输出 bridge_base_url_legacy_42671_rejected_run_mcp_ensure_ports 并 exit 1，
    绝不 curl 旧端口

A URL is valid only when scheme is http/https AND hostname is loopback
(127.0.0.1, localhost, ::1) or private/link-local IPv6 used by CoreDevice. Public and
non-private remote hosts are never contacted. Port 42671 is the legacy fixed port and
is always rejected (never curled) regardless of source.

MCP root resolution order (for step 3):
  1. DEV_FLOW_DEBUGBRIDGE_MCP_ROOT
  2. UI_DEBUGBRIDGE_MCP_ROOT
  3. mcp_root field in $DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-install.json
  4. $DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-mcp-root (plain text)
EOF
}

# 判定 URL 是否为可用的本地/CoreDevice 地址：scheme 必须是 http/https，hostname 必须是
# 127.0.0.1 / localhost / ::1，或 CoreDevice 使用的私有/链路本地 IPv6。公网和其他远程
# host 一律拒绝，防止把 DebugBridge 流量打到外部。
_bridge_url_is_loopback() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  /usr/bin/python3 - "$url" <<'PY'
import sys
import urllib.parse
import ipaddress

url = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
try:
    parsed = urllib.parse.urlparse(url)
except Exception:
    sys.exit(1)
if parsed.scheme not in ("http", "https"):
    sys.exit(1)
hostname = (parsed.hostname or "").lower()
if hostname in ("127.0.0.1", "localhost", "::1"):
    sys.exit(0)
try:
    address = ipaddress.ip_address(hostname)
except ValueError:
    sys.exit(1)
if isinstance(address, ipaddress.IPv6Address) and (address.is_private or address.is_link_local):
    sys.exit(0)
sys.exit(1)
PY
}

# 判定 URL 是否指向旧 legacy fixed port 42671。显式 env 指向 42671 时调用方应输出
# bridge_base_url_legacy_42671_rejected_run_mcp_ensure_ports 并 exit 1，绝不 curl 旧端口。
# last-bridge.json 里的 42671 也应被跳过（视为无效候选）。
_bridge_url_is_legacy_42671() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  /usr/bin/python3 - "$url" <<'PY'
import sys
import urllib.parse

url = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
try:
    parsed = urllib.parse.urlparse(url)
except Exception:
    sys.exit(1)
if str(parsed.port) == "42671":
    sys.exit(0)
sys.exit(1)
PY
}

# 解析 DebugBridge MCP 安装根目录，用于定位 .tmp/lookdebug-mcp/last-bridge.json。
# 优先级：环境变量 → .dev-flow/debugbridge-install.json (mcp_root) → .dev-flow/debugbridge-mcp-root。
_resolve_debugbridge_mcp_root() {
  local candidate=""
  for var in DEV_FLOW_DEBUGBRIDGE_MCP_ROOT UI_DEBUGBRIDGE_MCP_ROOT; do
    candidate="${!var:-}"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  local install_json="$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-install.json"
  if [[ -f "$install_json" ]]; then
    local from_manifest
    from_manifest="$(DEV_FLOW_INSTALL_JSON="$install_json" /usr/bin/python3 - <<'PY'
import json
import os
try:
    payload = json.load(open(os.environ["DEV_FLOW_INSTALL_JSON"], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
root = payload.get("mcp_root") if isinstance(payload, dict) else None
if isinstance(root, str) and root.strip():
    print(root.strip())
PY
)"
    if [[ -n "$from_manifest" ]]; then
      printf '%s\n' "$from_manifest"
      return 0
    fi
  fi

  local root_file="$DEV_FLOW_PROJECT_ROOT/.dev-flow/debugbridge-mcp-root"
  if [[ -f "$root_file" ]]; then
    local from_file
    from_file="$(DEV_FLOW_ROOT_FILE="$root_file" /usr/bin/python3 - <<'PY'
import os
try:
    with open(os.environ["DEV_FLOW_ROOT_FILE"], encoding="utf-8") as f:
        content = f.read()
except Exception:
    raise SystemExit(0)
# 只去掉首尾换行/空白，保留路径内部的空格（路径可能含空格）
content = content.strip()
if content:
    print(content)
PY
)"
    if [[ -n "$from_file" ]]; then
      printf '%s\n' "$from_file"
      return 0
    fi
  fi
}

# 解析 DebugBridge URL。优先级见 usage()。每个候选 URL 必须通过 _bridge_url_is_loopback
# 校验且不是 legacy 42671 才会使用；不合法（远程 host、非 http/https scheme、或 42671）
# 则跳过，继续下一个来源。不再回退到 legacy fixed port 42671；无候选 URL 时返回非 0，
# 让主流程输出 bridge_base_url_unavailable_run_mcp_ensure_ports，而不是
# bridge_identity_unreachable。
_resolve_bridge_debug_url() {
  local candidate=""

  candidate="${DEV_FLOW_DEBUGBRIDGE_URL:-}"
  if [[ -n "$candidate" ]] && _bridge_url_is_loopback "$candidate" \
     && ! _bridge_url_is_legacy_42671 "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="${BRIDGE_BASE_URL:-}"
  if [[ -n "$candidate" ]] && _bridge_url_is_loopback "$candidate" \
     && ! _bridge_url_is_legacy_42671 "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  local mcp_root
  mcp_root="$(_resolve_debugbridge_mcp_root)"
  if [[ -n "$mcp_root" ]]; then
    local last_bridge="$mcp_root/.tmp/lookdebug-mcp/last-bridge.json"
    if [[ -f "$last_bridge" ]]; then
      local bridge_base_url
      bridge_base_url="$(DEV_FLOW_LAST_BRIDGE_JSON="$last_bridge" /usr/bin/python3 - <<'PY'
import json
import os
try:
    payload = json.load(open(os.environ["DEV_FLOW_LAST_BRIDGE_JSON"], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
url = payload.get("bridgeBaseURL") if isinstance(payload, dict) else None
if isinstance(url, str) and url.strip():
    print(url.strip())
PY
)"
      if [[ -n "$bridge_base_url" ]] && _bridge_url_is_loopback "$bridge_base_url" \
         && ! _bridge_url_is_legacy_42671 "$bridge_base_url"; then
        printf '%s\n' "$bridge_base_url"
        return 0
      fi
    fi
  fi

  # 无可用候选 URL：返回非 0，主流程据此输出
  # bridge_base_url_unavailable_run_mcp_ensure_ports（提示先跑 MCP ensure_ports）。
  return 1
}

# 输出 legacy 42671 拒绝的 blocked JSON。显式 env 指向 42671 时调用，绝不 curl 旧端口。
_emit_legacy_42671_blocked() {
  /usr/bin/python3 - <<'PY'
import json
print(json.dumps({
    "status": "blocked",
    "evidence": "bridge_base_url_legacy_42671_rejected_run_mcp_ensure_ports",
}, ensure_ascii=False))
PY
}

if [[ "${1:-}" != "run" ]]; then
  usage >&2
  exit 2
fi

identity_json=""
if [[ -n "${DEV_FLOW_BRIDGE_IDENTITY_JSON:-}" ]]; then
  identity_json="$DEV_FLOW_BRIDGE_IDENTITY_JSON"
else
  # 显式 env (DEV_FLOW_DEBUGBRIDGE_URL / BRIDGE_BASE_URL) 指向 legacy 42671 → 立即拒绝，
  # 绝不 curl 旧端口，输出专门的 evidence 提示跑 MCP ensure_ports。
  if [[ -n "${DEV_FLOW_DEBUGBRIDGE_URL:-}" ]] && _bridge_url_is_legacy_42671 "$DEV_FLOW_DEBUGBRIDGE_URL"; then
    _emit_legacy_42671_blocked
    exit 1
  fi
  if [[ -n "${BRIDGE_BASE_URL:-}" ]] && _bridge_url_is_legacy_42671 "$BRIDGE_BASE_URL"; then
    _emit_legacy_42671_blocked
    exit 1
  fi
  debug_url=""
  resolve_rc=0
  set +e
  debug_url="$(_resolve_bridge_debug_url)"
  resolve_rc=$?
  set -e
  if [[ $resolve_rc -ne 0 || -z "$debug_url" ]]; then
    # 无可用 bridgeBaseURL（未跑 MCP ensure_ports 或 last-bridge.json 缺失/无效）：
    # 输出更准确的 evidence，提示先跑 MCP ensure_ports，而不是含糊的 bridge_identity_unreachable。
    /usr/bin/python3 - <<'PY'
import json
print(json.dumps({
    "status": "blocked",
    "evidence": "bridge_base_url_unavailable_run_mcp_ensure_ports",
}, ensure_ascii=False))
PY
    exit 1
  fi
  set +e
  identity_json="$(/usr/bin/curl -fsS --max-time 3 "${debug_url%/}/debug/identity" 2>/dev/null)"
  curl_exit=$?
  set -e
  if [[ $curl_exit -ne 0 || -z "$identity_json" ]]; then
    identity_json=""
  fi
fi

/usr/bin/python3 - "$SESSION_ID" "$identity_json" <<'PY'
import json
import sys

session_id = sys.argv[1]
identity_raw = sys.argv[2]

def emit(status, evidence, bridge_session_id=None):
    payload = {"status": status, "evidence": evidence}
    if bridge_session_id is not None:
        payload["bridge_session_id"] = bridge_session_id
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0 if status == "available" else 1)

if not identity_raw:
    emit("blocked", "bridge_identity_unreachable")

try:
    identity = json.loads(identity_raw)
except json.JSONDecodeError:
    emit("blocked", "bridge_identity_invalid_json")

if not isinstance(identity, dict):
    emit("blocked", "bridge_identity_not_object")

bridge_session = identity.get("sessionID")
if bridge_session is None:
    bridge_session = identity.get("session_id")
if not isinstance(bridge_session, str) or not bridge_session:
    emit("blocked", "bridge_identity_missing_session_id")

if bridge_session == "local" and session_id != "local":
    emit(
        "blocked",
        "bridge_session_local;pass_DEV_FLOW_SESSION_ID_via_build_run_device_env",
        bridge_session,
    )

if bridge_session != session_id:
    emit(
        "blocked",
        f"bridge_session_mismatch;expected={session_id};actual={bridge_session}",
        bridge_session,
    )

emit(
    "available",
    f"bridge_session={bridge_session};matches_dev_flow",
    bridge_session,
)
PY
