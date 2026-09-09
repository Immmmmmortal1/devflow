#!/usr/bin/env bash
# reviewer-readiness.sh model 校验测试
# 验证：model 必须是非空、包含单个 "/" 分隔、provider 和 model 均非空
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

# source reviewer-readiness.sh
source "$ROOT/scripts/lib/reviewer-readiness.sh"

# 辅助：创建 opencode.json 并返回路径
make_oc() {
  local model="$1"
  local path="$TMP/opencode.json"
  /usr/bin/python3 -c "
import json
payload = {
    'agent': {'openai-reviewer': {'model': '$model', 'mode': 'subagent'}},
    'provider': {
        'openrouter': {
            'name': 'OpenRouter',
            'options': {'baseURL': 'https://openrouter.ai/api/v1', 'apiKey': '{env:OPENROUTER_API_KEY}'}
        },
        'customprovider': {
            'name': 'Custom',
            'options': {'apiKey': 'test-key'}
        }
    }
}
import sys; sys.stdout.write(json.dumps(payload))
" > "$path"
  printf '%s\n' "$path"
}

# ============================================================
# 1. 合法 model "openrouter/openai/gpt-5.5" → reviewer_available
# ============================================================
echo "=== test 1: valid model provider/model ==="
config="$(make_oc 'openrouter/openai/gpt-5.5')"
evidence="$(reviewer_ready "$config")"
[[ "$evidence" == "reviewer_available" ]] || {
  echo "FAIL: valid model should be available, got: $evidence" >&2
  exit 1
}
echo "OK: valid model → reviewer_available"

# ============================================================
# 2. model 无 "/" → reviewer_model_invalid_format
# ============================================================
echo "=== test 2: model without slash → invalid format ==="
config="$(make_oc 'noprovider')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_model_invalid_format" ]] || {
  echo "FAIL: model without slash should be invalid_format, got: $evidence" >&2
  exit 1
}
echo "OK: model without slash → reviewer_model_invalid_format"

# ============================================================
# 3. model 以 "/" 开头（provider 空）→ reviewer_model_invalid_format
# ============================================================
echo "=== test 3: model with empty provider ==="
config="$(make_oc '/gpt-5.5')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_model_invalid_format" ]] || {
  echo "FAIL: model with empty provider should be invalid_format, got: $evidence" >&2
  exit 1
}
echo "OK: model with empty provider → reviewer_model_invalid_format"

# ============================================================
# 4. model 以 "/" 结尾（model 名空）→ reviewer_model_invalid_format
# ============================================================
echo "=== test 4: model with empty model name ==="
config="$(make_oc 'openrouter/')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_model_invalid_format" ]] || {
  echo "FAIL: model with empty model name should be invalid_format, got: $evidence" >&2
  exit 1
}
echo "OK: model with empty model name → reviewer_model_invalid_format"

# ============================================================
# 5. model 有多个 "/"（如 a/b/c）→ provider 不存在 → reviewer_provider_missing
# ============================================================
echo "=== test 5: model with multiple slashes (provider not found) ==="
config="$(make_oc 'a/b/c')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_provider_missing" ]] || {
  echo "FAIL: model 'a/b/c' should be provider_missing (provider 'a' not configured), got: $evidence" >&2
  exit 1
}
echo "OK: model with multiple slashes → reviewer_provider_missing (provider 'a' not configured)"

# 5b. 合法多斜杠 model（provider 存在）→ reviewer_available
echo "=== test 5b: valid model with multiple slashes (provider exists) ==="
config="$(make_oc 'openrouter/openai/gpt-5.5')"
evidence="$(reviewer_ready "$config")"
[[ "$evidence" == "reviewer_available" ]] || {
  echo "FAIL: valid multi-slash model should be available, got: $evidence" >&2
  exit 1
}
echo "OK: valid multi-slash model → reviewer_available"

# ============================================================
# 6. model 为空字符串 → reviewer_model_missing
# ============================================================
echo "=== test 6: empty model string ==="
config="$(make_oc '')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_model_missing" ]] || {
  echo "FAIL: empty model should be missing, got: $evidence" >&2
  exit 1
}
echo "OK: empty model → reviewer_model_missing"

# ============================================================
# 7. model 缺失（None）→ reviewer_model_missing
# ============================================================
echo "=== test 7: model field missing ==="
path="$TMP/oc-no-model.json"
/usr/bin/python3 -c "
import json
payload = {
    'agent': {'openai-reviewer': {'mode': 'subagent'}},
    'provider': {'openrouter': {'name': 'OpenRouter', 'options': {'apiKey': '{env:OPENROUTER_API_KEY}'}}}
}
import sys; sys.stdout.write(json.dumps(payload))
" > "$path"
evidence="$(reviewer_ready "$path" 2>&1)" || true
[[ "$evidence" == "reviewer_model_missing" ]] || {
  echo "FAIL: missing model should be missing, got: $evidence" >&2
  exit 1
}
echo "OK: missing model → reviewer_model_missing"

# ============================================================
# 8. model 为非字符串（数字）→ reviewer_model_missing
# ============================================================
echo "=== test 8: model as number ==="
path="$TMP/oc-num-model.json"
/usr/bin/python3 -c "
import json
payload = {
    'agent': {'openai-reviewer': {'model': 123, 'mode': 'subagent'}},
    'provider': {'openrouter': {'name': 'OpenRouter', 'options': {'apiKey': '{env:OPENROUTER_API_KEY}'}}}
}
import sys; sys.stdout.write(json.dumps(payload))
" > "$path"
evidence="$(reviewer_ready "$path" 2>&1)" || true
[[ "$evidence" == "reviewer_model_missing" ]] || {
  echo "FAIL: model as number should be missing, got: $evidence" >&2
  exit 1
}
echo "OK: model as number → reviewer_model_missing"

# ============================================================
# 9. provider/model 前后有空格但 strip 后非空 → reviewer_available
# ============================================================
echo "=== test 9: model with surrounding spaces ==="
config="$(make_oc ' customprovider /mymodel ')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
# model.count("/") == 1 但 provider " customprovider " strip 后非空
# 但 provider_name = " customprovider " 不匹配 "customprovider" → provider_missing
[[ "$evidence" == "reviewer_provider_missing" ]] || {
  echo "FAIL: model with spaces should be provider_missing, got: $evidence" >&2
  exit 1
}
echo "OK: model with spaces → reviewer_provider_missing (provider name has spaces)"

# ============================================================
# 10. model "provider/" 后只有空格 → reviewer_model_invalid_format
# ============================================================
echo "=== test 10: model with only spaces after slash ==="
config="$(make_oc 'openrouter/   ')"
evidence="$(reviewer_ready "$config" 2>&1)" || true
[[ "$evidence" == "reviewer_model_invalid_format" ]] || {
  echo "FAIL: model with only spaces after slash should be invalid_format, got: $evidence" >&2
  exit 1
}
echo "OK: model with only spaces after slash → reviewer_model_invalid_format"

echo ""
echo "PASS: reviewer-readiness model validation (format + missing + provider)"
