#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/project/scripts"
/bin/cp "$ROOT/scripts/environment-health-check.sh" "$TMP_ROOT/project/scripts/environment-health-check.sh"

if /bin/bash "$ROOT/scripts/dev-flow-doctor.sh" "$TMP_ROOT/project" >/dev/null 2>&1; then
  echo "FAIL: doctor should reject stale project scripts" >&2
  exit 1
fi

/bin/bash "$ROOT/scripts/link-project-scripts.sh" "$TMP_ROOT/project" >/dev/null
/bin/bash "$TMP_ROOT/project/scripts/dev-flow-doctor.sh" >/dev/null

if ! /usr/bin/grep -q 'FIGMA_ACCESS_TOKEN' "$TMP_ROOT/project/scripts/environment-health-check.sh"; then
  echo "FAIL: linked environment-health-check missing FIGMA_ACCESS_TOKEN alias" >&2
  exit 1
fi

echo "PASS: project script linking and doctor work"
