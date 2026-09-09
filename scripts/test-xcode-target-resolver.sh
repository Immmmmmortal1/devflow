#!/usr/bin/env bash
# xcode-target-resolver 测试：读 .xcodebuildmcp/config.yaml → 输出 session_set_defaults 字段
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/scripts/xcode-target-resolver.py"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  OK: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | /usr/bin/grep -q "$needle"; then
    echo "  OK: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — '$needle' not found in output" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ── test 1: valid config.yaml with sessionDefaults ──
echo "=== test 1: valid config ==="
mkdir -p "$TMP/proj1/.xcodebuildmcp" "$TMP/proj1/MyApp.xcodeproj"
cat > "$TMP/proj1/.xcodebuildmcp/config.yaml" <<'YAML'
sessionDefaults:
  projectPath: MyApp.xcodeproj
  scheme: MyApp
  configuration: Debug
  platform: iOS Simulator
  simulatorName: iPhone 16 Pro
  simulatorId: 12345678-1234-1234-1234-123456789012
  bundleId: com.example.MyApp
YAML
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" /usr/bin/python3 "$RESOLVER" 2>&1)"
assert_contains "has projectPath" "$result" "projectPath"
assert_contains "has scheme" "$result" "MyApp"
assert_contains "has simulatorId" "$result" "12345678"
assert_contains "has bundleId" "$result" "com.example.MyApp"

# ── test 2: missing config.yaml → fail closed ──
echo "=== test 2: missing config ==="
mkdir -p "$TMP/proj2"
if DEV_FLOW_PROJECT_ROOT="$TMP/proj2" /usr/bin/python3 "$RESOLVER" >/dev/null 2>&1; then
  echo "  FAIL: missing config should fail" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: missing config fails closed"
  PASS=$((PASS + 1))
fi

# ── test 3: invalid YAML → fail closed ──
echo "=== test 3: invalid YAML ==="
mkdir -p "$TMP/proj3/.xcodebuildmcp"
printf 'this is not: [valid yaml\n' > "$TMP/proj3/.xcodebuildmcp/config.yaml"
if DEV_FLOW_PROJECT_ROOT="$TMP/proj3" /usr/bin/python3 "$RESOLVER" >/dev/null 2>&1; then
  echo "  FAIL: invalid YAML should fail" >&2
  FAIL=$((FAIL + 1))
else
  echo "  OK: invalid YAML fails closed"
  PASS=$((PASS + 1))
fi

# ── test 4: workspace instead of project ──
echo "=== test 4: workspace config ==="
mkdir -p "$TMP/proj4/.xcodebuildmcp" "$TMP/proj4/MyApp.xcworkspace"
cat > "$TMP/proj4/.xcodebuildmcp/config.yaml" <<'YAML'
sessionDefaults:
  workspacePath: MyApp.xcworkspace
  scheme: MyApp
  configuration: Release
  platform: iOS Simulator
  simulatorName: iPhone 16
  bundleId: com.example.MyApp
YAML
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj4" /usr/bin/python3 "$RESOLVER" 2>&1)"
assert_contains "has workspacePath" "$result" "workspacePath"
assert_contains "has scheme" "$result" "MyApp"

# ── test 5: bash wrapper (xcode-target-resolver.sh) ──
echo "=== test 5: bash wrapper ==="
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" bash "$ROOT/scripts/xcode-target-resolver.sh" 2>&1)"
assert_contains "bash wrapper output" "$result" "projectPath"

# ── test 6: dev-flow.sh xcode-target subcommand ──
echo "=== test 6: dev-flow.sh xcode-target ==="
result="$(DEV_FLOW_PROJECT_ROOT="$TMP/proj1" bash "$ROOT/scripts/dev-flow.sh" xcode-target 2>&1)"
assert_contains "dev-flow subcommand output" "$result" "projectPath"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "PASS: xcode-target-resolver tests ($PASS assertions)"
else
  echo "FAIL: $FAIL assertions failed out of $((PASS + FAIL))" >&2
  exit 1
fi
