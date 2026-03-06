#!/bin/bash
# Tests for migrate-to-hybrid.sh and rollback-to-plugin.sh
# These tests use a mock HOME to avoid touching real settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"; }

# Create isolated test environment
MOCK_HOME=$(mktemp -d)
MOCK_SETTINGS="$MOCK_HOME/.claude/settings.json"
MOCK_COMMANDS="$MOCK_HOME/.claude/commands"
trap "rm -rf $MOCK_HOME" EXIT

setup_mock() {
  rm -rf "$MOCK_HOME"
  mkdir -p "$MOCK_HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/hooks"
  mkdir -p "$MOCK_HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/commands"
  mkdir -p "$MOCK_HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/scripts"
  mkdir -p "$MOCK_HOME/.claude/commands"
  # Create minimal settings.json (uses $REPO for portability)
  cat > "$MOCK_SETTINGS" << EOF
{
  "permissions": {"allow": [], "deny": [], "defaultMode": "acceptEdits"},
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "bash /some/init.sh"}]},
      {"hooks": [{"type": "command", "command": "bash $REPO/scripts/cache-watchdog.sh", "timeout": 10}]}
    ]
  },
  "enabledPlugins": {
    "ralph-loop@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true
  }
}
EOF
  # Create dummy files in marketplace for cache-sync
  echo "original" > "$MOCK_HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/hooks/stop-hook.sh"
  echo "original" > "$MOCK_HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/scripts/setup-ralph-loop.sh"
}

echo "=== Migration Script Tests ==="

# --- Test 1: Migration creates Stop hook ---
echo ""
echo "Test 1: Migration adds Stop hook to settings.json"
setup_mock
HOME="$MOCK_HOME" bash "$REPO/scripts/migrate-to-hybrid.sh" > /dev/null 2>&1
if jq -e '.hooks.Stop' "$MOCK_SETTINGS" > /dev/null 2>&1; then
  pass "Stop hook added to settings.json"
else
  fail "Stop hook NOT found in settings.json"
fi

# --- Test 2: Migration removes plugin entry ---
echo ""
echo "Test 2: Migration removes ralph-loop plugin entry"
PLUGIN_STATE=$(jq -r '.enabledPlugins["ralph-loop@claude-plugins-official"] // "missing"' "$MOCK_SETTINGS")
if [[ "$PLUGIN_STATE" == "missing" ]]; then
  pass "Plugin entry removed"
else
  fail "Plugin state: $PLUGIN_STATE (expected missing)"
fi

# --- Test 3: Other plugins unaffected ---
echo ""
echo "Test 3: Other plugins remain enabled"
SP_STATE=$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$MOCK_SETTINGS")
if [[ "$SP_STATE" == "true" ]]; then
  pass "superpowers plugin still enabled"
else
  fail "superpowers plugin state: $SP_STATE"
fi

# --- Test 4: Cache-watchdog hook removed ---
echo ""
echo "Test 4: Cache-watchdog SessionStart hook removed"
WATCHDOG_COUNT=$(jq '[.hooks.SessionStart[] | select(.hooks[].command | contains("cache-watchdog"))] | length' "$MOCK_SETTINGS")
if [[ "$WATCHDOG_COUNT" == "0" ]]; then
  pass "Cache-watchdog hook removed"
else
  fail "Cache-watchdog hooks remaining: $WATCHDOG_COUNT"
fi

# --- Test 5: Other SessionStart hooks preserved ---
echo ""
echo "Test 5: Other SessionStart hooks preserved"
INIT_COUNT=$(jq '[.hooks.SessionStart[] | select(.hooks[].command | contains("init.sh"))] | length' "$MOCK_SETTINGS")
if [[ "$INIT_COUNT" == "1" ]]; then
  pass "init.sh hook preserved"
else
  fail "init.sh hooks: $INIT_COUNT (expected 1)"
fi

# --- Test 6: Local commands created ---
echo ""
echo "Test 6: Local commands created"
if [[ -f "$MOCK_COMMANDS/ralph-loop.md" ]] && [[ -f "$MOCK_COMMANDS/cancel-ralph.md" ]]; then
  pass "ralph-loop.md and cancel-ralph.md created"
else
  fail "Missing local commands"
fi

# --- Test 7: ralph-loop.md uses absolute path (no CLAUDE_PLUGIN_ROOT) ---
echo ""
echo "Test 7: ralph-loop.md uses absolute path"
if grep -q "CLAUDE_PLUGIN_ROOT" "$MOCK_COMMANDS/ralph-loop.md" 2>/dev/null; then
  fail "ralph-loop.md still references CLAUDE_PLUGIN_ROOT"
elif grep -q "$REPO/scripts/setup-ralph-loop.sh" "$MOCK_COMMANDS/ralph-loop.md" 2>/dev/null; then
  pass "ralph-loop.md uses absolute repo path"
else
  fail "ralph-loop.md path not found"
fi

# --- Test 8: Backup created ---
echo ""
echo "Test 8: Settings backup created"
if [[ -f "${MOCK_SETTINGS}.pre-migration.bak" ]]; then
  pass "Backup file exists"
else
  fail "No backup file"
fi

# --- Test 9: Stop hook command points to repo ---
echo ""
echo "Test 9: Stop hook points to repo stop-hook.sh"
STOP_CMD=$(jq -r '.hooks.Stop[0].hooks[0].command' "$MOCK_SETTINGS")
if echo "$STOP_CMD" | grep -q "$REPO/scripts/stop-hook.sh"; then
  pass "Stop hook points to $REPO/scripts/stop-hook.sh"
else
  fail "Stop hook command: $STOP_CMD"
fi

# --- Test 10: Idempotent - running migration twice doesn't duplicate ---
echo ""
echo "Test 10: Migration is idempotent"
HOME="$MOCK_HOME" bash "$REPO/scripts/migrate-to-hybrid.sh" > /dev/null 2>&1
STOP_COUNT=$(jq '.hooks.Stop | length' "$MOCK_SETTINGS")
if [[ "$STOP_COUNT" == "1" ]]; then
  pass "Stop hook not duplicated"
else
  fail "Stop hook count: $STOP_COUNT (expected 1)"
fi

echo ""
echo "=== Rollback Script Tests ==="

# --- Test 11: Rollback re-enables plugin ---
echo ""
echo "Test 11: Rollback re-enables plugin"
HOME="$MOCK_HOME" bash "$REPO/scripts/rollback-to-plugin.sh" > /dev/null 2>&1
PLUGIN_STATE=$(jq -r '.enabledPlugins["ralph-loop@claude-plugins-official"]' "$MOCK_SETTINGS")
if [[ "$PLUGIN_STATE" == "true" ]]; then
  pass "Plugin re-enabled"
else
  fail "Plugin state: $PLUGIN_STATE (expected true)"
fi

# --- Test 12: Rollback removes Stop hook ---
echo ""
echo "Test 12: Rollback removes Stop hook"
if jq -e '.hooks.Stop' "$MOCK_SETTINGS" > /dev/null 2>&1; then
  fail "Stop hook still present after rollback"
else
  pass "Stop hook removed"
fi

# --- Test 13: Rollback re-adds cache-watchdog ---
echo ""
echo "Test 13: Rollback re-adds cache-watchdog"
WATCHDOG_COUNT=$(jq '[.hooks.SessionStart[] | select(.hooks[].command | contains("cache-watchdog"))] | length' "$MOCK_SETTINGS")
if [[ "$WATCHDOG_COUNT" == "1" ]]; then
  pass "Cache-watchdog hook re-added"
else
  fail "Cache-watchdog hooks: $WATCHDOG_COUNT (expected 1)"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
  exit 1
fi
