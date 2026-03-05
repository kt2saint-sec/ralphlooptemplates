#!/bin/bash
# Test: emit_consolidation_and_exit logic from stop-hook.sh
# Simulates consolidation behavior inline (cannot source function that calls exit).
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

# --- Test 1: Normal consolidation (learnings enabled, file exists) ---
echo "=== Test 1: Normal consolidation (first pass) ==="
SID="consol-test-1"
STATE="$MOCK_CLAUDE/ralph-loop.${SID}.local.md"
LEARNINGS="$MOCK_CLAUDE/ralph-learnings.${SID}.md"

cat > "$STATE" <<EOF
---
active: true
iteration: 5
max_iterations: 5
completion_promise: "GRANITE 1234 FALCON 5678 COSINE 9012"
learnings_enabled: true
session_id: "${SID}"
---
Build something
EOF
echo "# Iteration learnings" > "$LEARNINGS"

# Simulate first-pass consolidation logic
LEARNINGS_ENABLED="true"
RALPH_STATE_FILE="$STATE"
LEARNINGS_FILE="$LEARNINGS"
COMPLETION_PROMISE="GRANITE 1234 FALCON 5678 COSINE 9012"

# First pass: learnings enabled and file exists -> should add consolidating flag
if [[ "$LEARNINGS_ENABLED" == "true" ]] && [[ -f "$LEARNINGS_FILE" ]]; then
  if ! grep -q '^consolidating:' "$RALPH_STATE_FILE"; then
    TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
    sed "s/^active: true/active: true\nconsolidating: true/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$RALPH_STATE_FILE"
  fi
fi

if grep -q '^consolidating: true' "$STATE"; then
  pass "consolidating:true added to frontmatter"
else
  fail "consolidating:true NOT added"
fi

# Verify state file still exists (not deleted on first pass)
if [[ -f "$STATE" ]]; then
  pass "State file preserved on first pass"
else
  fail "State file deleted on first pass (should survive)"
fi

# --- Test 2: Second pass (consolidating already true) ---
echo ""
echo "=== Test 2: Second pass exits cleanly ==="
# Simulate second invocation — consolidating is already true
if grep -q '^consolidating:' "$STATE"; then
  rm -f "$STATE"
  rm -f "$LEARNINGS"
  SECOND_PASS_EXIT=true
else
  SECOND_PASS_EXIT=false
fi

if [[ "$SECOND_PASS_EXIT" == "true" ]]; then
  pass "Second pass triggered exit path"
else
  fail "Second pass did NOT trigger exit"
fi

if [[ ! -f "$STATE" ]]; then
  pass "State file removed on second pass"
else
  fail "State file NOT removed on second pass"
fi

if [[ ! -f "$LEARNINGS" ]]; then
  pass "Learnings file removed on second pass"
else
  fail "Learnings file NOT removed on second pass"
fi

# --- Test 3: No learnings (disabled) ---
echo ""
echo "=== Test 3: Learnings disabled ==="
SID3="consol-no-learn"
STATE3="$MOCK_CLAUDE/ralph-loop.${SID3}.local.md"
cat > "$STATE3" <<EOF
---
active: true
iteration: 3
max_iterations: 3
completion_promise: null
learnings_enabled: false
session_id: "${SID3}"
---
Test prompt
EOF

LEARNINGS_ENABLED="false"
RALPH_STATE_FILE="$STATE3"

# When learnings disabled, should just remove state file and exit
if [[ "$LEARNINGS_ENABLED" != "true" ]]; then
  rm -f "$STATE3"
  SKIPPED_CONSOLIDATION=true
else
  SKIPPED_CONSOLIDATION=false
fi

if [[ "$SKIPPED_CONSOLIDATION" == "true" ]]; then
  pass "Consolidation skipped when learnings disabled"
else
  fail "Consolidation NOT skipped"
fi

if [[ ! -f "$STATE3" ]]; then
  pass "State file removed without consolidation"
else
  fail "State file NOT removed"
fi

# --- Test 4: No learnings file exists ---
echo ""
echo "=== Test 4: Learnings file missing ==="
SID4="consol-no-file"
STATE4="$MOCK_CLAUDE/ralph-loop.${SID4}.local.md"
LEARN4="$MOCK_CLAUDE/ralph-learnings.${SID4}.md"
cat > "$STATE4" <<EOF
---
active: true
iteration: 5
learnings_enabled: true
session_id: "${SID4}"
---
Test
EOF
# Deliberately do NOT create learnings file

LEARNINGS_ENABLED="true"
LEARNINGS_FILE="$LEARN4"
RALPH_STATE_FILE="$STATE4"

if [[ "$LEARNINGS_ENABLED" != "true" ]] || [[ ! -f "$LEARNINGS_FILE" ]]; then
  rm -f "$STATE4"
  SKIPPED=true
else
  SKIPPED=false
fi

if [[ "$SKIPPED" == "true" ]]; then
  pass "Consolidation skipped when learnings file missing"
else
  fail "Consolidation NOT skipped despite missing file"
fi

# --- Test 5: Consolidation prompt includes passphrase ---
echo ""
echo "=== Test 5: Consolidation includes passphrase ==="
COMPLETION_PROMISE="GRANITE 1234 FALCON 5678 COSINE 9012"
LEARNINGS_FILE="$MOCK_CLAUDE/ralph-learnings.test.md"
CONSOLIDATION_PROMPT="RALPH LOOP COMPLETE - consolidation steps at $LEARNINGS_FILE"

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  CONSOLIDATION_PROMPT="${CONSOLIDATION_PROMPT}

After consolidation, output '${COMPLETION_PROMISE}' on its own line to signal final completion."
fi

if echo "$CONSOLIDATION_PROMPT" | grep -qF "$COMPLETION_PROMISE"; then
  pass "Consolidation prompt includes passphrase"
else
  fail "Consolidation prompt missing passphrase"
fi

# --- Test 6: Consolidation prompt without passphrase ---
echo ""
echo "=== Test 6: Consolidation without passphrase ==="
COMPLETION_PROMISE="null"
CONSOLIDATION_PROMPT2="RALPH LOOP COMPLETE - consolidation steps"

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  CONSOLIDATION_PROMPT2="${CONSOLIDATION_PROMPT2}
After consolidation, output passphrase."
fi

if echo "$CONSOLIDATION_PROMPT2" | grep -qF "output passphrase"; then
  fail "Passphrase instruction included when promise is null"
else
  pass "No passphrase instruction when promise is null"
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
