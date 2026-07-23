#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/usr/bin/trash "$TMP_ROOT"' EXIT

/bin/mkdir -p "$TMP_ROOT/scripts"
/bin/cp "$ROOT/scripts/dev-flow-session.sh" "$TMP_ROOT/scripts/dev-flow-session.sh"

run_for() {
  local session_id="$1"
  shift
  CODEX_THREAD_ID="$session_id" /bin/bash "$TMP_ROOT/scripts/dev-flow-session.sh" "$@"
}

run_for thread-a start --type feature --task "task a" >/dev/null
run_for thread-b start --type bug --task "task b" >/dev/null
run_for thread-a confirm-plan >/dev/null
run_for thread-a end >/dev/null

/usr/bin/python3 - "$TMP_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
a_path = root / ".dev-flow" / "sessions" / "thread-a.json"
b_path = root / ".dev-flow" / "sessions" / "thread-b.json"

assert a_path.exists(), a_path
assert b_path.exists(), b_path
assert not (root / ".dev-flow" / "session.json").exists()

a = json.loads(a_path.read_text())
b = json.loads(b_path.read_text())
assert a["session_id"] == "thread-a"
assert a["active"] is False
assert a["confirmed_at"] is not None
assert b["session_id"] == "thread-b"
assert b["active"] is True
assert b["confirmed_at"] is None
assert b["task"] == "task b"
PY

echo "PASS: dev-flow sessions are isolated"
