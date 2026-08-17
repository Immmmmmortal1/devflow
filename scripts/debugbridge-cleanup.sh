#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/debugbridge-cleanup.sh [--dry-run]

Stop orphaned UI-dbugbridge-mcp server processes and iproxy forwards on this Mac.

Use when multiple MCP instances accumulated (common after repeated Codex/Cursor restarts).
Normal dev-flow completion should call ui_dbugbridge_mcp.release_session instead; this script
is for recovery only.
EOF
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
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

mapfile -t mcp_pids < <(pgrep -f 'UI-dbugbridge-mcp.*server\.js|node.*UI-dbugbridge-mcp.*server\.js' 2>/dev/null || true)
mapfile -t iproxy_pids < <(pgrep -f 'iproxy -u' 2>/dev/null || true)

echo "DebugBridge cleanup"
echo "  MCP server processes: ${#mcp_pids[@]}"
echo "  iproxy processes:     ${#iproxy_pids[@]}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "${mcp_pids[@]:-}" "${iproxy_pids[@]:-}" | sed '/^$/d' | sort -u | while read -r pid; do
    ps -p "$pid" -o pid=,command= 2>/dev/null || true
  done
  exit 0
fi

if ((${#mcp_pids[@]} + ${#iproxy_pids[@]} == 0)); then
  echo "Nothing to clean."
  exit 0
fi

for pid in "${mcp_pids[@]}"; do
  kill "$pid" 2>/dev/null || true
done
for pid in "${iproxy_pids[@]}"; do
  kill "$pid" 2>/dev/null || true
done

sleep 1
remaining_mcp="$(pgrep -fc 'UI-dbugbridge-mcp.*server\.js|node.*UI-dbugbridge-mcp.*server\.js' 2>/dev/null || echo 0)"
remaining_iproxy="$(pgrep -fc 'iproxy -u' 2>/dev/null || echo 0)"
echo "Remaining MCP server processes: $remaining_mcp"
echo "Remaining iproxy processes:     $remaining_iproxy"

if [[ "$remaining_mcp" -ne 0 || "$remaining_iproxy" -ne 0 ]]; then
  echo "WARNING: some processes could not be stopped. Quit Codex/Cursor and rerun this script." >&2
  exit 1
fi

echo "Cleanup complete. Restart Codex/Cursor before the next dev-flow session."
