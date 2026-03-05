#!/bin/bash
# Test: stop-hook.sh behavior with malformed, empty, and valid HOOK_INPUT JSON
# Tests the jq parsing resilience and fallback paths.
# Self-contained — uses mktemp for artifacts, cleans up via trap.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

# Helper: test jq extraction with various inputs
test_jq_extraction() {
  local LABEL="$1"
  local INPUT="$2"
  local EXPECTED_SID="$3"
  local EXPECTED_MSG="$4"

  local SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  local MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null || echo "")
  local TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")

  local PASS=true
  if [[ "$SID" != "$EXPECTED_SID" ]]; then
    fail "$LABEL: session_id expected '$EXPECTED_SID', got '$SID'"
    PASS=false
  fi
  if [[ "$MSG" != "$EXPECTED_MSG" ]]; then
    fail "$LABEL: last_assistant_message expected '$EXPECTED_MSG', got '$MSG'"
    PASS=false
  fi
  if [[ "$PASS" == "true" ]]; then
    pass "$LABEL"
  fi
}

# --- Test 1: Empty string ---
echo "=== Test 1: Empty HOOK_INPUT ==="
test_jq_extraction "Empty string" "" "" ""

# --- Test 2: Empty JSON object ---
echo ""
echo "=== Test 2: Empty JSON object ==="
test_jq_extraction "Empty object" "{}" "" ""

# --- Test 3: Null values ---
echo ""
echo "=== Test 3: Null field values ==="
test_jq_extraction "Null values" '{"session_id": null, "last_assistant_message": null}' "" ""

# --- Test 4: Valid JSON with all fields ---
echo ""
echo "=== Test 4: Valid complete JSON ==="
VALID_JSON='{"session_id":"abc-123","last_assistant_message":"Hello world","transcript_path":"/tmp/test.jsonl","stop_hook_active":false}'
test_jq_extraction "Valid JSON" "$VALID_JSON" "abc-123" "Hello world"

# --- Test 5: Malformed JSON (not valid) ---
echo ""
echo "=== Test 5: Malformed JSON ==="
MALFORMED="this is not json at all"
SID=$(echo "$MALFORMED" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -z "$SID" ]]; then
  pass "Malformed JSON: jq returns empty (no crash)"
else
  fail "Malformed JSON: unexpected result '$SID'"
fi

# --- Test 6: Partial JSON (missing fields) ---
echo ""
echo "=== Test 6: Partial JSON (only session_id) ==="
test_jq_extraction "Partial JSON" '{"session_id":"partial-test"}' "partial-test" ""

# --- Test 7: JSON with extra unknown fields ---
echo ""
echo "=== Test 7: JSON with extra fields ==="
EXTRA_JSON='{"session_id":"x","last_assistant_message":"y","unknown_field":"z","another":42}'
test_jq_extraction "Extra fields" "$EXTRA_JSON" "x" "y"

# --- Test 8: Multiline last_assistant_message ---
echo ""
echo "=== Test 8: Multiline message ==="
MULTILINE_JSON='{"session_id":"multi","last_assistant_message":"line1\nline2\nDONE"}'
MSG=$(echo "$MULTILINE_JSON" | jq -r '.last_assistant_message // empty' 2>/dev/null || echo "")
if echo "$MSG" | grep -qFx "DONE"; then
  pass "Multiline message: grep -Fx finds DONE on its own line"
else
  fail "Multiline message: grep -Fx did not find DONE"
fi

# --- Test 9: stop_hook_active field ---
echo ""
echo "=== Test 9: stop_hook_active extraction ==="
SHA_JSON='{"stop_hook_active":true}'
SHA=$(echo "$SHA_JSON" | jq -r '.stop_hook_active // empty' 2>/dev/null || echo "")
if [[ "$SHA" == "true" ]]; then
  pass "stop_hook_active extracted correctly"
else
  fail "stop_hook_active expected 'true', got '$SHA'"
fi

# --- Test 10: Binary/garbage input ---
echo ""
echo "=== Test 10: Binary garbage input ==="
GARBAGE=$(printf '\x00\x01\x02\xff\xfe')
SID=$(echo "$GARBAGE" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -z "$SID" ]]; then
  pass "Binary garbage: jq returns empty (no crash)"
else
  fail "Binary garbage: unexpected result"
fi

# --- Test 11: Very long message ---
echo ""
echo "=== Test 11: Large message (10KB) ==="
LONG_MSG=$(python3 -c "print('x' * 10000)" 2>/dev/null || printf '%10000s' | tr ' ' 'x')
LONG_JSON="{\"session_id\":\"long\",\"last_assistant_message\":\"${LONG_MSG}\"}"
SID=$(echo "$LONG_JSON" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ "$SID" == "long" ]]; then
  pass "Large message: session_id still extractable"
else
  fail "Large message: session_id extraction failed"
fi

# --- Test 12: Integration — stop-hook.sh fast exit with no state file ---
echo ""
echo "=== Test 12: Stop hook fast exit (no state files) ==="
MOCK_DIR="$TMPDIR/integration"
mkdir -p "$MOCK_DIR/.claude"
STOP_HOOK="$(cd "$(dirname "$0")" && pwd)/stop-hook.sh"

# Run stop-hook.sh from a dir with no state files — should exit 0 immediately
EXIT_CODE=0
cd "$MOCK_DIR"
echo '{"session_id":"test"}' | bash "$STOP_HOOK" 2>/dev/null || EXIT_CODE=$?
cd "$REPO_DIR"

# The script uses relative paths (.claude/), so from MOCK_DIR it should find nothing
if [[ $EXIT_CODE -eq 0 ]]; then
  pass "Stop hook exits cleanly with no state files"
else
  fail "Stop hook exit code $EXIT_CODE (expected 0)"
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
