#!/bin/bash
# Test: cache-watchdog.sh actual script invocation
# Tests the real watchdog script by creating mock cache directories.
# Self-contained — uses mktemp for mock cache, cleans up via trap.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$REPO/scripts/cache-watchdog.sh"

# --- Test 1: watchdog detects mismatch (actual script) ---
echo "=== Test 1: Watchdog detects file mismatch ==="

# Create mock cache structure under a fake HOME
FAKE_HOME="$TMPDIR/fakehome"
MOCK_CACHE="$FAKE_HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop/testversion"
mkdir -p "$MOCK_CACHE/hooks" "$MOCK_CACHE/scripts" "$MOCK_CACHE/commands"

# Copy real files then corrupt one
cp "$REPO/scripts/stop-hook.sh" "$MOCK_CACHE/hooks/stop-hook.sh"
cp "$REPO/scripts/setup-ralph-loop.sh" "$MOCK_CACHE/scripts/setup-ralph-loop.sh"
cp "$REPO/commands/cancel-ralph.md" "$MOCK_CACHE/commands/cancel-ralph.md"
echo "# CORRUPTED BY UPDATE" >> "$MOCK_CACHE/hooks/stop-hook.sh"

# Run actual watchdog with HOME overridden
OUTPUT=$(HOME="$FAKE_HOME" bash "$WATCHDOG" 2>&1) || true

if echo "$OUTPUT" | grep -q "MISMATCH.*stop-hook.sh"; then
  pass "Watchdog detected stop-hook.sh mismatch"
else
  fail "Watchdog missed stop-hook.sh mismatch. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "cache-sync.sh"; then
  pass "Watchdog suggests cache-sync.sh"
else
  fail "Watchdog missing sync suggestion. Output: $OUTPUT"
fi

# --- Test 2: watchdog passes when synced ---
echo ""
echo "=== Test 2: Watchdog passes when cache is synced ==="
cp "$REPO/scripts/stop-hook.sh" "$MOCK_CACHE/hooks/stop-hook.sh"

OUTPUT=$(HOME="$FAKE_HOME" bash "$WATCHDOG" 2>&1) || true

if [[ -z "$OUTPUT" ]]; then
  pass "No output when cache is synced (silent success)"
else
  fail "Unexpected output when synced: $OUTPUT"
fi

# --- Test 3: Version update (old orphaned, new active) ---
echo ""
echo "=== Test 3: Version update simulation ==="
touch "$MOCK_CACHE/.orphaned_at"

NEW_CACHE="$FAKE_HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop/newversion"
mkdir -p "$NEW_CACHE/hooks" "$NEW_CACHE/scripts" "$NEW_CACHE/commands"
echo "#!/bin/bash" > "$NEW_CACHE/hooks/stop-hook.sh"
echo "#!/bin/bash" > "$NEW_CACHE/scripts/setup-ralph-loop.sh"
echo "---" > "$NEW_CACHE/commands/cancel-ralph.md"

OUTPUT=$(HOME="$FAKE_HOME" bash "$WATCHDOG" 2>&1) || true

# Should find 3 mismatches in new version, ignore orphaned old version
MISMATCH_COUNT=$(echo "$OUTPUT" | grep -c "MISMATCH" || true)

if [[ $MISMATCH_COUNT -eq 3 ]]; then
  pass "All 3 files mismatch in new version (fresh install detected)"
else
  fail "Expected 3 mismatches, found $MISMATCH_COUNT. Output: $OUTPUT"
fi

# --- Test 4: Sync restores new version ---
echo ""
echo "=== Test 4: Sync restores files to new version ==="
cp "$REPO/scripts/stop-hook.sh" "$NEW_CACHE/hooks/stop-hook.sh"
cp "$REPO/scripts/setup-ralph-loop.sh" "$NEW_CACHE/scripts/setup-ralph-loop.sh"
cp "$REPO/commands/cancel-ralph.md" "$NEW_CACHE/commands/cancel-ralph.md"

OUTPUT=$(HOME="$FAKE_HOME" bash "$WATCHDOG" 2>&1) || true

if [[ -z "$OUTPUT" ]]; then
  pass "No mismatches after sync to new version"
else
  fail "Still mismatched after sync: $OUTPUT"
fi

# --- Test 5: No active cache directory ---
echo ""
echo "=== Test 5: No active cache directory ==="
EMPTY_HOME="$TMPDIR/emptyhome"
mkdir -p "$EMPTY_HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop"

OUTPUT=$(HOME="$EMPTY_HOME" bash "$WATCHDOG" 2>&1) || true
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$OUTPUT" ]]; then
  pass "Exits cleanly with no active cache"
else
  fail "Unexpected behavior with no cache: exit=$EXIT_CODE output=$OUTPUT"
fi

# --- Test 6: Multiple mismatches reported ---
echo ""
echo "=== Test 6: Multiple file mismatches ==="
# Remove orphaned marker from old version so it's active again, remove new version
rm -f "$MOCK_CACHE/.orphaned_at"
rm -rf "$NEW_CACHE"

# Corrupt two files
echo "# MODIFIED" >> "$MOCK_CACHE/hooks/stop-hook.sh"
echo "# MODIFIED" >> "$MOCK_CACHE/scripts/setup-ralph-loop.sh"

OUTPUT=$(HOME="$FAKE_HOME" bash "$WATCHDOG" 2>&1) || true
MISMATCH_COUNT=$(echo "$OUTPUT" | grep -c "MISMATCH" || true)

if [[ $MISMATCH_COUNT -eq 2 ]]; then
  pass "Detected exactly 2 mismatches"
else
  fail "Expected 2 mismatches, found $MISMATCH_COUNT"
fi

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
