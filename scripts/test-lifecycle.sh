#!/bin/bash
# Test: Full lifecycle integration (setup -> iterate -> promise -> consolidate -> exit)
# Simulates the complete loop using mock files (NOT a real ralph loop).
# Self-contained — uses mktemp for artifacts, cleans up via trap.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

MOCK_CLAUDE="$TMPDIR/.claude"
mkdir -p "$MOCK_CLAUDE"

# Shared passphrase for all tests
PASSPHRASE="RALPH-66ff1a2b-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e"
PROMISE="${PASSPHRASE}::ALL TESTS PASSING"

# ============================================================
echo "=== Phase A: Setup (simulating setup-ralph-loop.sh) ==="
SETUP_SID="a1b2c3d4e5f6"  # simulated uuidgen short form
STATE="$MOCK_CLAUDE/ralph-loop.${SETUP_SID}.local.md"
LEARNINGS="$MOCK_CLAUDE/ralph-learnings.${SETUP_SID}.md"

cat > "$STATE" <<EOF
---
active: true
iteration: 1
max_iterations: 5
completion_promise: "${PROMISE}"
learnings_enabled: true
session_id: "${SETUP_SID}"
started_at: "2026-03-05T18:00:00Z"
---

Build a test API with auth
EOF

if [[ -f "$STATE" ]]; then
  pass "Setup: state file created with uuidgen ID"
else
  fail "Setup: state file NOT created"
fi

# ============================================================
echo ""
echo "=== Phase B: First iteration (hook renames to hook session_id) ==="
HOOK_SID="hook-real-session-id"
NEW_STATE="$MOCK_CLAUDE/ralph-loop.${HOOK_SID}.local.md"

# Simulate: direct lookup fails (file not named with hook SID yet)
FOUND=""
if [[ -f "$MOCK_CLAUDE/ralph-loop.${HOOK_SID}.local.md" ]]; then
  FOUND="direct"
fi

if [[ -z "$FOUND" ]]; then
  pass "First iter: direct lookup misses (expected)"
else
  fail "First iter: direct lookup hit (unexpected)"
fi

# Simulate glob fallback
shopt -s nullglob
FILES=("$MOCK_CLAUDE"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 1 ]]; then
  pass "First iter: glob finds exactly 1 file"
else
  fail "First iter: glob found ${#FILES[@]} files (expected 1)"
fi

# Simulate flock rename
OLD_SID=$(basename "${FILES[0]}" | sed 's/^ralph-loop\.\(.*\)\.local\.md$/\1/')
mv "${FILES[0]}" "$NEW_STATE"
TEMP_FILE="${NEW_STATE}.tmp.$$"
sed "s/^session_id: \"${OLD_SID}\"/session_id: \"${HOOK_SID}\"/" "$NEW_STATE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$NEW_STATE"
STATE="$NEW_STATE"

if [[ -f "$NEW_STATE" ]]; then
  pass "First iter: state file renamed to hook SID"
else
  fail "First iter: rename failed"
fi

if grep -q "session_id: \"${HOOK_SID}\"" "$NEW_STATE"; then
  pass "First iter: frontmatter updated"
else
  fail "First iter: frontmatter NOT updated"
fi

# ============================================================
echo ""
echo "=== Phase C: Iteration 2 (promise not met, loop continues) ==="
# Simulate: last_assistant_message does NOT contain the passphrase
LAST_OUTPUT="I've started building the API. Here are the endpoints so far."

if echo "$LAST_OUTPUT" | grep -qFx "$PROMISE"; then
  fail "Iter 2: false positive promise detection"
else
  pass "Iter 2: promise correctly NOT detected"
fi

# Increment iteration
NEXT_ITER=2
TEMP_FILE="${STATE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITER/" "$STATE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE"

if grep -q "^iteration: 2" "$STATE"; then
  pass "Iter 2: iteration counter incremented"
else
  fail "Iter 2: iteration counter NOT incremented"
fi

# Direct lookup should work now (O(1))
if [[ -f "$MOCK_CLAUDE/ralph-loop.${HOOK_SID}.local.md" ]]; then
  pass "Iter 2: direct O(1) lookup works"
else
  fail "Iter 2: direct lookup fails"
fi

# Create learnings file (simulating Claude writing to it)
echo "# Iteration 2: API endpoints created, auth not yet done" > "$MOCK_CLAUDE/ralph-learnings.${HOOK_SID}.md"
LEARNINGS="$MOCK_CLAUDE/ralph-learnings.${HOOK_SID}.md"

# ============================================================
echo ""
echo "=== Phase D: Promise met (passphrase in output) ==="
LAST_OUTPUT="All endpoints tested, auth working.

${PROMISE}

Done."

if echo "$LAST_OUTPUT" | grep -qFx "$PROMISE"; then
  pass "Promise: passphrase detected"
else
  fail "Promise: passphrase NOT detected"
fi

# ============================================================
echo ""
echo "=== Phase E: Consolidation fires ==="
# Simulate consolidation first pass
LEARNINGS_ENABLED="true"
if [[ "$LEARNINGS_ENABLED" == "true" ]] && [[ -f "$LEARNINGS" ]]; then
  if ! grep -q '^consolidating:' "$STATE"; then
    TEMP_FILE="${STATE}.tmp.$$"
    sed "s/^active: true/active: true\nconsolidating: true/" "$STATE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE"
  fi
  CONSOLIDATION_FIRED=true
else
  CONSOLIDATION_FIRED=false
fi

if [[ "$CONSOLIDATION_FIRED" == "true" ]]; then
  pass "Consolidation: first pass fires"
else
  fail "Consolidation: first pass NOT fired"
fi

if grep -q '^consolidating: true' "$STATE"; then
  pass "Consolidation: flag added to frontmatter"
else
  fail "Consolidation: flag NOT added"
fi

# Second pass: clean up
if grep -q '^consolidating:' "$STATE"; then
  rm -f "$STATE"
  rm -f "$LEARNINGS"
fi

if [[ ! -f "$STATE" ]] && [[ ! -f "$LEARNINGS" ]]; then
  pass "Consolidation: second pass cleaned up both files"
else
  fail "Consolidation: cleanup incomplete"
fi

# ============================================================
echo ""
echo "=== Phase F: Max iterations (separate test) ==="
MAX_SID="max-iter-test"
MAX_STATE="$MOCK_CLAUDE/ralph-loop.${MAX_SID}.local.md"
cat > "$MAX_STATE" <<EOF
---
active: true
iteration: 5
max_iterations: 5
completion_promise: null
learnings_enabled: false
session_id: "${MAX_SID}"
---
Task
EOF

ITERATION=5
MAX_ITERATIONS=5
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  rm -f "$MAX_STATE"
  MAX_ITER_EXIT=true
else
  MAX_ITER_EXIT=false
fi

if [[ "$MAX_ITER_EXIT" == "true" ]] && [[ ! -f "$MAX_STATE" ]]; then
  pass "Max iterations: loop exits and cleans up"
else
  fail "Max iterations: loop did NOT exit"
fi

# ============================================================
echo ""
echo "=== Phase G: Cancel mid-loop ==="
CANCEL_SID="cancel-test"
CANCEL_STATE="$MOCK_CLAUDE/ralph-loop.${CANCEL_SID}.local.md"
cat > "$CANCEL_STATE" <<EOF
---
active: true
iteration: 3
session_id: "${CANCEL_SID}"
---
Task
EOF

# Simulate cancel: delete state file
rm -f "$CANCEL_STATE"

# Simulate next stop hook invocation: glob finds nothing
shopt -s nullglob
REMAINING=("$MOCK_CLAUDE"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#REMAINING[@]} -eq 0 ]]; then
  pass "Cancel: stop hook finds no state files (exits cleanly)"
else
  fail "Cancel: ${#REMAINING[@]} state files still exist"
fi

# ============================================================
echo ""
echo "=== Phase H: Glob matches both filename formats ==="
# Test that our dual-glob pattern finds BOTH original plugin format and our format
GLOB_STATE1="$MOCK_CLAUDE/ralph-loop.local.md"
GLOB_STATE2="$MOCK_CLAUDE/ralph-loop.glob-test-sid.local.md"
echo "test" > "$GLOB_STATE1"
echo "test" > "$GLOB_STATE2"

shopt -s nullglob
BOTH=("$MOCK_CLAUDE"/ralph-loop.loca[l].md "$MOCK_CLAUDE"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#BOTH[@]} -eq 2 ]]; then
  pass "Glob: both filename formats found (original + session ID)"
else
  fail "Glob: expected 2 files, found ${#BOTH[@]}"
fi

# Test session ID extraction from both formats
SID1=$(basename "$GLOB_STATE1" | sed -E 's/^ralph-loop\.(.+)\.local\.md$/\1/; t; s/^ralph-loop\.local\.md$//')
SID2=$(basename "$GLOB_STATE2" | sed -E 's/^ralph-loop\.(.+)\.local\.md$/\1/; t; s/^ralph-loop\.local\.md$//')

if [[ -z "$SID1" ]]; then
  pass "Glob: original format yields empty session ID"
else
  fail "Glob: original format yielded '$SID1' (expected empty)"
fi

if [[ "$SID2" == "glob-test-sid" ]]; then
  pass "Glob: session ID format extracts correctly"
else
  fail "Glob: session ID format yielded '$SID2' (expected 'glob-test-sid')"
fi

rm -f "$GLOB_STATE1" "$GLOB_STATE2"

# Test nullglob: only session-ID file exists, no ralph-loop.local.md
GLOB_STATE3="$MOCK_CLAUDE/ralph-loop.nullglob-test.local.md"
echo "test" > "$GLOB_STATE3"

shopt -s nullglob
NULLGLOB_FILES=("$MOCK_CLAUDE"/ralph-loop.loca[l].md "$MOCK_CLAUDE"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#NULLGLOB_FILES[@]} -eq 1 ]]; then
  pass "Nullglob: non-existent ralph-loop.local.md correctly excluded"
else
  fail "Nullglob: expected 1 file, found ${#NULLGLOB_FILES[@]}"
fi
rm -f "$GLOB_STATE3"

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
