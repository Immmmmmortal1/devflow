#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PROJECT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_PROJECT"' EXIT

/bin/bash "$ROOT/scripts/dev-flow-init-project.sh" "$TMP_PROJECT" >/dev/null
/bin/bash "$ROOT/scripts/dev-flow-doctor.sh" "$TMP_PROJECT" >/dev/null

if /bin/bash "$ROOT/scripts/dev-flow-doctor.sh" "$TMP_PROJECT" 2>&1 | /usr/bin/grep -q 'Missing in dev-flow source'; then
  echo "FAIL: doctor reported missing source scripts unexpectedly" >&2
  exit 1
fi

if [[ -d "$TMP_PROJECT/scripts" ]]; then
  echo "FAIL: init should not create app scripts/ directory" >&2
  exit 1
fi

if [[ ! -f "$TMP_PROJECT/.dev-flow/source-root" ]]; then
  echo "FAIL: init did not write source-root binding" >&2
  exit 1
fi

echo "PASS: central dev-flow binding works without per-app scripts"
