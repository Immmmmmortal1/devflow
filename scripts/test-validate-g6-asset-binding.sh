#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALID_FIXTURE="$ROOT/scripts/fixtures/g6-valid"
INVALID_FIXTURE="$ROOT/scripts/fixtures/g6-invalid"

if ! bash "$ROOT/scripts/validate-g6-asset-binding.sh" \
  --workspace "$VALID_FIXTURE" \
  --source-root "$VALID_FIXTURE/source" >/dev/null; then
  echo "FAIL: valid G6 fixture should pass validation" >&2
  exit 1
fi

if bash "$ROOT/scripts/validate-g6-asset-binding.sh" \
  --workspace "$INVALID_FIXTURE" \
  --source-root "$INVALID_FIXTURE/source" >/dev/null 2>&1; then
  echo "FAIL: invalid G6 fixture should fail validation" >&2
  exit 1
fi

echo "PASS: G6 asset binding validator accepts valid fixture and rejects hand-drawn fixture"
