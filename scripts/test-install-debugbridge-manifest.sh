#!/usr/bin/env bash
set -euo pipefail

TMP_MANIFEST="$(/usr/bin/mktemp)"
trap '/bin/rm -f -- "$TMP_MANIFEST"' EXIT

SWIFT_BOOTSTRAP_REQUIRED="false"
POD_CHANGED="no"
POD_STATUS="present"
MCP_ROOT="/tmp/debugbridge-mcp"
SERVER_JS="/tmp/debugbridge-mcp/src/server.js"
DEBUGBRIDGE_TAG="0.1.7"
PODFILE_PATH="/tmp/app/Podfile"

python3 - <<PY
import json
from pathlib import Path

manifest = {
    "schema_version": 1,
    "mcp_root": "$MCP_ROOT",
    "server_js": "$SERVER_JS",
    "pod_tag": "$DEBUGBRIDGE_TAG",
    "pod_status": "$POD_STATUS",
    "podfile": "$PODFILE_PATH",
    "pod_changed": "$POD_CHANGED" == "yes",
    "swift_bootstrap_required": "$SWIFT_BOOTSTRAP_REQUIRED" == "true",
    "swift_bootstrap_snippet": ".dev-flow/debugbridge-app-bootstrap.swift.snippet",
    "ai_next_steps": [],
}

Path("$TMP_MANIFEST").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

python3 - <<PY
import json
from pathlib import Path

manifest = json.loads(Path("$TMP_MANIFEST").read_text(encoding="utf-8"))
assert manifest["swift_bootstrap_required"] is False, manifest
assert manifest["pod_changed"] is False, manifest
assert type(manifest["swift_bootstrap_required"]) is bool, manifest
print("manifest booleans ok")
PY

echo "PASS: debugbridge manifest uses valid JSON booleans"
