#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_SKILLS="$(/usr/bin/mktemp -d)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
TMP_MCP_CONFIG="$(/usr/bin/mktemp)"
TMP_ORCH="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_SKILLS" "$TMP_PROJECT" "$TMP_MCP_CONFIG" "$TMP_ORCH"' EXIT

mkdir -p "$TMP_ORCH/.venv/bin" "$TMP_ORCH/src"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP_ORCH/codex-stdio-wrapper.sh"
printf '%s\n' '#!/usr/bin/env python3' > "$TMP_ORCH/.venv/bin/python"
chmod +x "$TMP_ORCH/codex-stdio-wrapper.sh" "$TMP_ORCH/.venv/bin/python"

bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP_SKILLS" \
  --review-backend orchestrator \
  --orchestrator-root "$TMP_ORCH" \
  --skip-mcp-config >/dev/null

[[ -f "$ROOT/.dev-flow/review-backend.json" ]]
[[ -f "$ROOT/.dev-flow/orchestrator-mcp-root" ]]

mkdir -p "$TMP_SKILLS/gstack/review"
printf '%s\n' '# review' > "$TMP_SKILLS/gstack/review/SKILL.md"

bash "$ROOT/scripts/install-review-backend.sh" \
  --codex \
  --skills-root "$TMP_SKILLS" \
  --review-backend gstack \
  --project "$TMP_PROJECT" \
  --skip-mcp-config >/dev/null

[[ -f "$TMP_PROJECT/.dev-flow/review-backend.json" ]]
/usr/bin/grep -q '"backend": "gstack"' "$TMP_PROJECT/.dev-flow/review-backend.json"

python3 "$ROOT/scripts/lib/merge-orchestrator-mcp-config.py" \
  --platform cursor \
  --wrapper-path "$TMP_ORCH/codex-stdio-wrapper.sh" \
  --pythonpath "$TMP_ORCH/src" \
  --config-path "$TMP_MCP_CONFIG" >/dev/null

/usr/bin/grep -q 'orchestrator_mcp' "$TMP_MCP_CONFIG"

ORCHESTRATOR_MCP_ROOT="$TMP_ORCH" \
  DEV_FLOW_PROJECT_ROOT="$TMP_PROJECT" \
  /bin/bash "$ROOT/scripts/review-health-probe.sh" >/dev/null

echo "PASS: install-review-backend.sh and orchestrator health probe"
