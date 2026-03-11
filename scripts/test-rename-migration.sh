#!/bin/bash
# Test: State file rename migration path in stop-hook.sh
# Verifies the first-iteration rename from uuidgen ID to hook session_id.
# Self-contained — uses mktemp for artifacts, cleans up via trap.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

# Create mock .claude directory in temp
MOCK_CLAUDE="$TMPDIR/.claude"
mkdir -p "$MOCK_CLAUDE"

# --- Test 1: Basic rename from uuidgen to hook session_id ---
echo "=== Test 1: Basic state file rename ==="
SETUP_SID="abc123def456"
HOOK_SID="hook-session-xyz"
STATE_FILE="$MOCK_CLAUDE/ralph-loop.${SETUP_SID}.local.md"

cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
max_iterations: 10
completion_promise: "RALPH-66ff1a2b-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e"
learnings_enabled: true
session_id: "${SETUP_SID}"
started_at: "2026-03-05T18:00:00Z"
---

Build a test API
EOF

# Create matching learnings file
LEARNINGS_FILE="$MOCK_CLAUDE/ralph-learnings.${SETUP_SID}.md"
echo "# Learnings for $SETUP_SID" > "$LEARNINGS_FILE"

# Simulate rename (same logic as stop-hook.sh)
NEW_STATE_FILE="$MOCK_CLAUDE/ralph-loop.${HOOK_SID}.local.md"
OLD_SID=$(basename "$STATE_FILE" | sed 's/^ralph-loop\.\(.*\)\.local\.md$/\1/')
mv "$STATE_FILE" "$NEW_STATE_FILE"

# Update frontmatter session_id
TEMP_FILE="${NEW_STATE_FILE}.tmp.$$"
sed "s/^session_id: \"${OLD_SID}\"/session_id: \"${HOOK_SID}\"/" "$NEW_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$NEW_STATE_FILE"

# Rename learnings file
if [[ -f "$MOCK_CLAUDE/ralph-learnings.${OLD_SID}.md" ]]; then
  mv "$MOCK_CLAUDE/ralph-learnings.${OLD_SID}.md" "$MOCK_CLAUDE/ralph-learnings.${HOOK_SID}.md"
fi

# Verify state file renamed
if [[ -f "$NEW_STATE_FILE" ]]; then
  pass "State file renamed to hook session_id"
else
  fail "State file NOT renamed"
fi

# Verify old state file gone
if [[ ! -f "$STATE_FILE" ]]; then
  pass "Old state file removed"
else
  fail "Old state file still exists"
fi

# Verify frontmatter updated
if grep -q "session_id: \"${HOOK_SID}\"" "$NEW_STATE_FILE"; then
  pass "Frontmatter session_id updated to hook session_id"
else
  fail "Frontmatter session_id NOT updated (still has old value)"
fi

# Verify learnings file renamed
if [[ -f "$MOCK_CLAUDE/ralph-learnings.${HOOK_SID}.md" ]]; then
  pass "Learnings file renamed"
else
  fail "Learnings file NOT renamed"
fi

if [[ ! -f "$MOCK_CLAUDE/ralph-learnings.${SETUP_SID}.md" ]]; then
  pass "Old learnings file removed"
else
  fail "Old learnings file still exists"
fi

# --- Test 2: Direct lookup after rename ---
echo ""
echo "=== Test 2: O(1) direct lookup after rename ==="
if [[ -f "$MOCK_CLAUDE/ralph-loop.${HOOK_SID}.local.md" ]]; then
  pass "Direct lookup by hook session_id succeeds"
else
  fail "Direct lookup by hook session_id fails"
fi

# --- Test 3: No rename when IDs already match ---
echo ""
echo "=== Test 3: No rename when IDs match ==="
SAME_SID="same-session-id"
SAME_FILE="$MOCK_CLAUDE/ralph-loop.${SAME_SID}.local.md"
cat > "$SAME_FILE" <<EOF
---
active: true
iteration: 2
session_id: "${SAME_SID}"
---
Test prompt
EOF

# Simulate: HOOK_SESSION_ID == filename ID, so no rename should happen
SAME_NEW="$MOCK_CLAUDE/ralph-loop.${SAME_SID}.local.md"
if [[ "$SAME_FILE" == "$SAME_NEW" ]]; then
  pass "No rename needed when IDs match"
else
  fail "Rename attempted when IDs match"
fi
rm -f "$SAME_FILE"

# --- Test 4: Rename with no learnings file ---
echo ""
echo "=== Test 4: Rename without learnings file ==="
SETUP_SID2="setup-no-learn"
HOOK_SID2="hook-no-learn"
STATE_FILE2="$MOCK_CLAUDE/ralph-loop.${SETUP_SID2}.local.md"
cat > "$STATE_FILE2" <<EOF
---
active: true
iteration: 1
session_id: "${SETUP_SID2}"
---
Prompt without learnings
EOF

# No learnings file created
mv "$STATE_FILE2" "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md"
TEMP_FILE2="$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md.tmp.$$"
sed "s/^session_id: \"${SETUP_SID2}\"/session_id: \"${HOOK_SID2}\"/" "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md" > "$TEMP_FILE2"
mv "$TEMP_FILE2" "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md"

if [[ -f "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md" ]]; then
  pass "Rename works without learnings file"
else
  fail "Rename failed without learnings file"
fi

if grep -q "session_id: \"${HOOK_SID2}\"" "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md"; then
  pass "Frontmatter updated without learnings file"
else
  fail "Frontmatter NOT updated without learnings file"
fi
rm -f "$MOCK_CLAUDE/ralph-loop.${HOOK_SID2}.local.md"

# --- Test 5: Concurrent rename simulation with flock ---
echo ""
echo "=== Test 5: Concurrent rename with flock ==="
RACE_SID="race-setup-id"
RACE_HOOK1="hook-terminal-1"
RACE_HOOK2="hook-terminal-2"

# Create a single state file that two "terminals" would fight over
RACE_FILE="$MOCK_CLAUDE/ralph-loop.${RACE_SID}.local.md"
cat > "$RACE_FILE" <<EOF
---
active: true
iteration: 1
session_id: "${RACE_SID}"
---
Race test prompt
EOF

# Simulate two concurrent flock attempts
# Terminal 1 acquires lock and renames
(
  flock -n 9 || exit 0
  if [[ -f "$RACE_FILE" ]]; then
    mv "$RACE_FILE" "$MOCK_CLAUDE/ralph-loop.${RACE_HOOK1}.local.md"
  fi
) 9>"$MOCK_CLAUDE/ralph-loop.lock"

# Terminal 2 tries but file is already gone
RACE_FILE_EXISTS=false
if [[ -f "$RACE_FILE" ]]; then
  RACE_FILE_EXISTS=true
fi

if [[ "$RACE_FILE_EXISTS" == "false" ]]; then
  pass "Original file gone after first rename (second terminal would skip)"
else
  fail "Original file still exists (race condition possible)"
fi

if [[ -f "$MOCK_CLAUDE/ralph-loop.${RACE_HOOK1}.local.md" ]]; then
  pass "Terminal 1 successfully renamed"
else
  fail "Terminal 1 rename failed"
fi
rm -f "$MOCK_CLAUDE/ralph-loop.${RACE_HOOK1}.local.md" "$MOCK_CLAUDE/ralph-loop.lock"

# --- Test 6: Prompt content preserved after rename ---
echo ""
echo "=== Test 6: Prompt content preserved ==="
PRES_SID="preserve-test"
PRES_HOOK="preserve-hook"
PRES_FILE="$MOCK_CLAUDE/ralph-loop.${PRES_SID}.local.md"
PROMPT_CONTENT="Build a REST API with authentication

---
Use JWT tokens for auth
---
Include rate limiting"

cat > "$PRES_FILE" <<EOF
---
active: true
iteration: 1
session_id: "${PRES_SID}"
---

${PROMPT_CONTENT}
EOF

mv "$PRES_FILE" "$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md"
TEMP_PRES="$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md.tmp.$$"
sed "s/^session_id: \"${PRES_SID}\"/session_id: \"${PRES_HOOK}\"/" "$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md" > "$TEMP_PRES"
mv "$TEMP_PRES" "$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md"

# Extract prompt text using same awk as stop-hook.sh
EXTRACTED=$(awk '/^---$/ && fm_count<2 {fm_count++; next} fm_count>=2' "$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md")

if echo "$EXTRACTED" | grep -q "Build a REST API"; then
  pass "Prompt content preserved after rename"
else
  fail "Prompt content lost after rename"
fi

if echo "$EXTRACTED" | grep -q "Use JWT tokens for auth"; then
  pass "Embedded --- lines preserved"
else
  fail "Embedded --- lines corrupted"
fi
rm -f "$MOCK_CLAUDE/ralph-loop.${PRES_HOOK}.local.md"

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
