#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
TMP_SKILLS="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_PROJECT" "$TMP_SKILLS"' EXIT

CODEX_SKILLS_ROOT="$TMP_SKILLS" \
  bash "$ROOT/scripts/install-dev-flow.sh" --codex --skills-only --skip-debugbridge --skip-review >/dev/null

[[ -L "$TMP_SKILLS/dev-flow" ]]
[[ -f "$TMP_SKILLS/environment-health-check/SKILL.md" ]]

bash "$ROOT/scripts/install-dev-flow.sh" --codex --project "$TMP_PROJECT" --skip-debugbridge --skip-review >/dev/null
[[ -f "$TMP_PROJECT/.dev-flow/source-root" ]]
[[ -d "$TMP_PROJECT/.dev-flow/sessions" ]]
[[ ! -d "$TMP_PROJECT/scripts" ]]

echo "PASS: install-dev-flow.sh links skills and binds app projects"
