#!/usr/bin/env bash
set -euo pipefail

# devflow 更新通知 —— 推送飞书群自定义机器人。
# webhook 只从 FEISHU_UPDATE_WEBHOOK 环境变量读取，绝不写死、不打印、不进日志（教训 009）。
# 本地/CI 测试请用假 webhook（http://127.0.0.1:<port>/）覆盖，禁止直发生产群。

usage() {
  cat <<'EOF'
Usage:
  scripts/notify-feishu-update.sh [--repo <owner/name>] [--ref <ref>] [--tag <tag>]
    [--sha <sha>] [--actor <actor>] [--commit-url <url>] [--run-url <url>]
    [--message <text>]

通过飞书自定义机器人推送 devflow 更新通知。
webhook 只从 FEISHU_UPDATE_WEBHOOK 环境变量读取（由 AI / 维护者从安全区注入）。
其余字段同名环境变量（NOTIFY_REPO / NOTIFY_REF / NOTIFY_TAG / NOTIFY_SHA /
NOTIFY_ACTOR / NOTIFY_RUN_URL / NOTIFY_COMMIT_URL / NOTIFY_MESSAGE）作为默认值，
命令行参数覆盖环境变量。

安全：脚本不打印 webhook；缺失时失败并给出配置提示。
测试：用 FEISHU_UPDATE_WEBHOOK=http://127.0.0.1:<port>/ 覆盖，禁止用生产 webhook 跑测试。
EOF
}

REPO="${NOTIFY_REPO:-}"
REF="${NOTIFY_REF:-}"
TAG="${NOTIFY_TAG:-}"
SHA="${NOTIFY_SHA:-}"
ACTOR="${NOTIFY_ACTOR:-}"
RUN_URL="${NOTIFY_RUN_URL:-}"
COMMIT_URL="${NOTIFY_COMMIT_URL:-}"
MESSAGE="${NOTIFY_MESSAGE:-}"
WEBHOOK="${FEISHU_UPDATE_WEBHOOK:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="${2:-}";        shift 2 ;;
    --ref)        REF="${2:-}";         shift 2 ;;
    --tag)        TAG="${2:-}";         shift 2 ;;
    --sha)        SHA="${2:-}";         shift 2 ;;
    --actor)      ACTOR="${2:-}";       shift 2 ;;
    --run-url)    RUN_URL="${2:-}";     shift 2 ;;
    --commit-url) COMMIT_URL="${2:-}";  shift 2 ;;
    --message)    MESSAGE="${2:-}";     shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$WEBHOOK" ]]; then
  cat >&2 <<'EOF'
ERROR: FEISHU_UPDATE_WEBHOOK 未配置。
- 发布通知：由 AI / 维护者从安全区读取真实 webhook，并通过 FEISHU_UPDATE_WEBHOOK 注入。
- 本地测试：导出 FEISHU_UPDATE_WEBHOOK=http://127.0.0.1:<port>/ 后再运行
  （禁止用生产 webhook 跑测试，见教训 009）。
EOF
  exit 1
fi

# 用 Python 标准库 urllib 发 JSON，避免依赖 jq/curl；webhook 不进任何输出。
NOTIFY_REPO="$REPO" NOTIFY_REF="$REF" NOTIFY_TAG="$TAG" NOTIFY_SHA="$SHA" \
NOTIFY_ACTOR="$ACTOR" NOTIFY_RUN_URL="$RUN_URL" NOTIFY_COMMIT_URL="$COMMIT_URL" \
NOTIFY_MESSAGE="$MESSAGE" FEISHU_UPDATE_WEBHOOK="$WEBHOOK" \
  /usr/bin/python3 - <<'PY'
import json
import os
import re
import sys
import urllib.error
import urllib.request

webhook = os.environ["FEISHU_UPDATE_WEBHOOK"]
repo = os.environ.get("NOTIFY_REPO", "")
ref = os.environ.get("NOTIFY_REF", "")
tag = os.environ.get("NOTIFY_TAG", "")
sha = os.environ.get("NOTIFY_SHA", "")
actor = os.environ.get("NOTIFY_ACTOR", "")
run_url = os.environ.get("NOTIFY_RUN_URL", "")
commit_url = os.environ.get("NOTIFY_COMMIT_URL", "")
message = os.environ.get("NOTIFY_MESSAGE", "")

# 版本显示：优先 tag，其次 ref
version = tag or ref
# 简短说明
if message:
    note = message
elif tag:
    note = "devflow 发布新版本 {}".format(tag)
else:
    note = "devflow 更新通知"

short_sha = sha[:7] if sha else ""


def text(t):
    return {"tag": "text", "text": t}


def link(t, href):
    return {"tag": "a", "text": t, "href": href}


content = []
# 仓库
content.append([text("仓库：{}".format(repo) if repo else "仓库：-")])
# 版本
if version:
    row = [text("版本：")]
    row.append(link(version, commit_url) if commit_url else text(version))
    content.append(row)
# 提交
if sha:
    row = [text("提交：")]
    row.append(link(short_sha, commit_url) if commit_url else text(short_sha))
    content.append(row)
# 触发者
if actor:
    content.append([text("触发者：{}".format(actor))])
# 构建运行
if run_url:
    content.append([text("构建："), link("查看运行", run_url)])
# 说明
content.append([text("说明：{}".format(note))])

payload = {
    "msg_type": "post",
    "content": {
        "post": {
            "zh_cn": {
                "title": "devflow 更新通知",
                "content": content,
            }
        }
    },
}

data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(
    webhook,
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)

status = 0
body = ""


def sanitize(text):
    """脱敏外部响应文本，避免 webhook/path/token 被写入日志。"""
    if not isinstance(text, str):
        return ""
    redacted = text.replace(webhook, "<redacted-webhook>")
    redacted = re.sub(r"https?://[^\s\"'<>]+", "<redacted-url>", redacted)
    redacted = re.sub(r"/open-apis/bot/v2/hook/[^\s\"'<>]+", "/open-apis/bot/v2/hook/<redacted>", redacted)
    if len(redacted) > 300:
        redacted = redacted[:300] + "...<truncated>"
    return redacted


def safe_response_summary(raw_body):
    """只输出安全摘要；JSON 响应仅取 code/msg 并脱敏，不原样打印 body。"""
    try:
        payload = json.loads(raw_body or "{}")
    except json.JSONDecodeError:
        return "非 JSON 响应（{} bytes）".format(len(raw_body or ""))
    code = payload.get("code", "<missing>")
    msg = sanitize(str(payload.get("msg", ""))) if payload.get("msg") is not None else ""
    return "code={} msg={}".format(code, msg or "<empty>")


try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        status = resp.status
        body = resp.read().decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    # HTTPError 是非 2xx 响应；只取 code 与响应体，不打印 e.url（含 webhook）
    status = e.code
    body = e.read().decode("utf-8", "replace")
except urllib.error.URLError as e:
    # 网络层错误；e.reason 不含 URL
    print("ERROR: 发送飞书通知失败（网络）：{}".format(e.reason), file=sys.stderr)
    sys.exit(1)
except Exception as e:
    # 兜底：只打印类型名，不打印可能含 URL 的异常字符串
    print("ERROR: 发送飞书通知失败：{}".format(type(e).__name__), file=sys.stderr)
    sys.exit(1)

if not (200 <= status < 300):
    print("ERROR: 飞书返回非 2xx 状态：{}，响应摘要：{}".format(status, safe_response_summary(body)), file=sys.stderr)
    sys.exit(1)

# 飞书自定义机器人成功一般返回 {"code":0,"msg":"success"}；业务错误带非 0 code
try:
    resp_json = json.loads(body)
except json.JSONDecodeError:
    resp_json = {}
code = resp_json.get("code")
if code not in (0, None):
    print("ERROR: 飞书业务返回错误：{}".format(safe_response_summary(body)), file=sys.stderr)
    sys.exit(1)

print("OK: 飞书更新通知已发送")
PY
