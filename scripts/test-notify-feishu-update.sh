#!/usr/bin/env bash
set -euo pipefail

# 测试 scripts/notify-feishu-update.sh
# 用本地假 HTTP server 模拟飞书机器人，禁止真发生产群（教训 009）。
# 覆盖：1) 缺 webhook 失败+提示；2) 有假 webhook 时请求 JSON 结构正确；3) 输出不泄露 webhook。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

NOTIFY="$ROOT/scripts/notify-feishu-update.sh"

# ---- 启动假飞书 server：记录 POST body 到文件，返回飞书成功响应 ----
PORT_FILE="$TMP_ROOT/port"
BODY_FILE="$TMP_ROOT/body.log"
SERVER_LOG="$TMP_ROOT/server.log"
: > "$BODY_FILE"

/usr/bin/python3 - "$PORT_FILE" "$BODY_FILE" <<'PY' &
import http.server
import socketserver
import sys

port_file, body_file = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with open(body_file, "ab") as f:
            f.write(body)
        if self.path == "/http-error":
            resp = ('{"code":999,"msg":"bad webhook path http://127.0.0.1:%s/http-error"}' % self.server.server_address[1]).encode()
            self.send_response(500)
        elif self.path == "/business-error":
            resp = ('{"code":19001,"msg":"invalid webhook http://127.0.0.1:%s/business-error"}' % self.server.server_address[1]).encode()
            self.send_response(200)
        else:
            resp = b'{"code":0,"msg":"success","data":{}}'
            self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, *args):
        pass


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


srv = ReusableTCPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
sys.stdout.flush()
srv.serve_forever()
PY
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
}
trap 'cleanup; /bin/rm -rf -- "$TMP_ROOT"' EXIT

# 等待端口文件就绪
for _ in $(seq 1 50); do
  [[ -s "$PORT_FILE" ]] && break
  /bin/sleep 0.05
done
PORT="$(cat "$PORT_FILE")"
if [[ -z "$PORT" ]]; then
  echo "FAIL: 假飞书 server 未启动" >&2
  exit 1
fi
FAKE_WEBHOOK="http://127.0.0.1:${PORT}/"

# ---- 测试 1：缺 webhook 必须失败且给出配置提示 ----
OUT1="$TMP_ROOT/out1.txt"
if env -u FEISHU_UPDATE_WEBHOOK /bin/bash "$NOTIFY" \
    --repo "acme/devflow" --tag "v9.9.9" >"$OUT1" 2>&1; then
  echo "FAIL: 缺 webhook 时应失败，却退出 0" >&2
  cat "$OUT1" >&2
  exit 1
fi
if ! /usr/bin/grep -q "FEISHU_UPDATE_WEBHOOK 未配置" "$OUT1"; then
  echo "FAIL: 缺 webhook 时未给出配置提示" >&2
  cat "$OUT1" >&2
  exit 1
fi
if ! /usr/bin/grep -q "安全区" "$OUT1" || ! /usr/bin/grep -q "FEISHU_UPDATE_WEBHOOK" "$OUT1"; then
  echo "FAIL: 缺 webhook 时未提示安全区/环境变量配置方式" >&2
  cat "$OUT1" >&2
  exit 1
fi
# 同时确认没有真的发出请求
if [[ -s "$BODY_FILE" ]]; then
  echo "FAIL: 缺 webhook 时不应有请求发出，但 server 收到 body" >&2
  exit 1
fi

# ---- 测试 2：有假 webhook 时发送成功 + 请求 JSON 结构正确 ----
: > "$BODY_FILE"
OUT2="$TMP_ROOT/out2.txt"
REPO="acme/devflow-test"
TAGV="v9.9.9-test"
SHA="abcdef1234567890abcdef"
ACTOR="test-bot"
RUN_URL="https://example.invalid/runs/12345"
COMMIT_URL="https://example.invalid/commit/abcdef"
MSG="回归测试通知"

if ! FEISHU_UPDATE_WEBHOOK="$FAKE_WEBHOOK" /bin/bash "$NOTIFY" \
    --repo "$REPO" --tag "$TAGV" --sha "$SHA" --actor "$ACTOR" \
    --run-url "$RUN_URL" --commit-url "$COMMIT_URL" --message "$MSG" \
    >"$OUT2" 2>&1; then
  echo "FAIL: 有假 webhook 时应成功，却非 0 退出" >&2
  cat "$OUT2" >&2
  exit 1
fi
if ! /usr/bin/grep -q "OK: 飞书更新通知已发送" "$OUT2"; then
  echo "FAIL: 成功路径缺少 OK 输出" >&2
  cat "$OUT2" >&2
  exit 1
fi
if [[ ! -s "$BODY_FILE" ]]; then
  echo "FAIL: 成功路径 server 未收到请求 body" >&2
  exit 1
fi

# 校验请求 JSON 结构（msg_type=post，含 repo/tag/short_sha/actor/查看运行/message）
/usr/bin/python3 - "$BODY_FILE" "$REPO" "$TAGV" "$SHA" "$ACTOR" "$RUN_URL" "$MSG" <<'PY'
import json, sys

body_file = sys.argv[1]
repo, tagv, sha, actor, run_url, msg = sys.argv[2:8]

data = json.loads(open(body_file, "r", encoding="utf-8").read())
assert data["msg_type"] == "post", "msg_type 应为 post，实际：%r" % data.get("msg_type")
post = data["content"]["post"]["zh_cn"]
assert "title" in post and post["title"], "缺少 title"
assert isinstance(post["content"], list) and post["content"], "content 非非空 list"

# 拼接所有 text/a 文本
def texts(node):
    out = []
    if isinstance(node, list):
        for x in node:
            out += texts(x)
    elif isinstance(node, dict):
        if node.get("tag") in ("text", "a"):
            out.append(node.get("text", ""))
        for k in ("content", "post"):
            if k in node:
                out += texts(node[k])
    return out

blob = "\n".join(texts(post))
for needle, label in [
    (repo, "repo"),
    (tagv, "tag"),
    (sha[:7], "short_sha"),
    (actor, "actor"),
    ("查看运行", "run link text"),
    (msg, "message"),
]:
    assert needle in blob, "消息文本缺少 %s（%r）\n--- 拼接文本 ---\n%s" % (label, needle, blob)

# run_url 必须出现在某个 a 标签的 href
hrefs = []
def collect_hrefs(node):
    if isinstance(node, list):
        for x in node:
            collect_hrefs(x)
    elif isinstance(node, dict):
        if node.get("tag") == "a":
            hrefs.append(node.get("href", ""))
        for v in node.values():
            collect_hrefs(v)
collect_hrefs(data)
assert run_url in hrefs, "run_url 未出现在链接 href 中：%r" % hrefs
assert sha[:7] in blob, "short_sha 未出现在文本中"
print("body-struct-ok")
PY

# ---- 测试 3：脚本输出不得泄露 webhook URL ----
# 用测试 2 的输出 + 一次失败路径输出共同验证
if /usr/bin/grep -Fq "$FAKE_WEBHOOK" "$OUT2"; then
  echo "FAIL: 成功路径输出泄露了 webhook URL" >&2
  cat "$OUT2" >&2
  exit 1
fi

# 失败路径：把假 webhook 指向一个不存在端口，验证错误输出也不泄露 URL
BAD_PORT=$((PORT + 7))
BAD_WEBHOOK="http://127.0.0.1:${BAD_PORT}/"
OUT3="$TMP_ROOT/out3.txt"
if FEISHU_UPDATE_WEBHOOK="$BAD_WEBHOOK" /bin/bash "$NOTIFY" \
    --repo "$REPO" --tag "$TAGV" >"$OUT3" 2>&1; then
  echo "FAIL: 连接失败时应非 0 退出，却退出 0" >&2
  cat "$OUT3" >&2
  exit 1
fi
if /usr/bin/grep -Fq "$BAD_WEBHOOK" "$OUT3"; then
  echo "FAIL: 网络失败路径输出泄露了 webhook URL" >&2
  cat "$OUT3" >&2
  exit 1
fi
if ! /usr/bin/grep -q "网络" "$OUT3"; then
  echo "FAIL: 网络失败路径缺少网络错误说明" >&2
  cat "$OUT3" >&2
  exit 1
fi

# 非 2xx / 飞书业务错误路径：响应体即便包含 webhook，也不能原样泄露
OUT4="$TMP_ROOT/out4.txt"
HTTP_ERROR_WEBHOOK="${FAKE_WEBHOOK}http-error"
if FEISHU_UPDATE_WEBHOOK="$HTTP_ERROR_WEBHOOK" /bin/bash "$NOTIFY" \
    --repo "$REPO" --tag "$TAGV" >"$OUT4" 2>&1; then
  echo "FAIL: 非 2xx 响应应非 0 退出，却退出 0" >&2
  cat "$OUT4" >&2
  exit 1
fi
if /usr/bin/grep -Fq "$HTTP_ERROR_WEBHOOK" "$OUT4" || /usr/bin/grep -Fq "$FAKE_WEBHOOK" "$OUT4"; then
  echo "FAIL: 非 2xx 错误路径输出泄露了 webhook URL" >&2
  cat "$OUT4" >&2
  exit 1
fi
if ! /usr/bin/grep -q "响应摘要" "$OUT4"; then
  echo "FAIL: 非 2xx 错误路径缺少安全摘要" >&2
  cat "$OUT4" >&2
  exit 1
fi

OUT5="$TMP_ROOT/out5.txt"
BUSINESS_ERROR_WEBHOOK="${FAKE_WEBHOOK}business-error"
if FEISHU_UPDATE_WEBHOOK="$BUSINESS_ERROR_WEBHOOK" /bin/bash "$NOTIFY" \
    --repo "$REPO" --tag "$TAGV" >"$OUT5" 2>&1; then
  echo "FAIL: 飞书业务错误应非 0 退出，却退出 0" >&2
  cat "$OUT5" >&2
  exit 1
fi
if /usr/bin/grep -Fq "$BUSINESS_ERROR_WEBHOOK" "$OUT5" || /usr/bin/grep -Fq "$FAKE_WEBHOOK" "$OUT5"; then
  echo "FAIL: 业务错误路径输出泄露了 webhook URL" >&2
  cat "$OUT5" >&2
  exit 1
fi
if ! /usr/bin/grep -q "飞书业务返回错误" "$OUT5"; then
  echo "FAIL: 业务错误路径缺少错误说明" >&2
  cat "$OUT5" >&2
  exit 1
fi

echo "PASS: notify-feishu-update.sh 缺 webhook 失败+提示、假 webhook 请求结构正确、输出不泄露 webhook"
