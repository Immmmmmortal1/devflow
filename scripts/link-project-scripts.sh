#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=dev-flow-init-project.sh
exec bash "$ROOT/scripts/dev-flow-init-project.sh" "$@"
