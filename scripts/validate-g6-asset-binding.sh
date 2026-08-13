#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/validate-g6-asset-binding.sh \
    --workspace <artifact-workspace> \
    --source-root <target-project-root> \
    [--report <path>]
EOF
}

WORKSPACE=""
SOURCE_ROOT=""
REPORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --source-root)
      SOURCE_ROOT="${2:-}"
      shift 2
      ;;
    --report)
      REPORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$WORKSPACE" || -z "$SOURCE_ROOT" ]]; then
  usage >&2
  exit 2
fi

args=(--workspace "$WORKSPACE" --source-root "$SOURCE_ROOT")
if [[ -n "$REPORT" ]]; then
  args+=(--report "$REPORT")
fi

exec /usr/bin/python3 "$ROOT/scripts/validate-g6-asset-binding.py" "${args[@]}"
