#!/bin/bash
# Test: Passphrase generation format and false-positive resistance
# Self-contained — uses mktemp for artifacts, cleans up via trap

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

echo "=== Test 1: Passphrase format validation ==="
# Source the generate_passphrase function from setup script
eval "$(sed -n '/^generate_passphrase()/,/^}/p' "$(dirname "$0")/setup-ralph-loop.sh")"

for i in $(seq 1 5); do
  PHRASE=$(generate_passphrase)
  # Validate format: WORD NNNN WORD NNNN WORD NNNN
  if echo "$PHRASE" | grep -qE '^[A-Z]+ [0-9]{4} [A-Z]+ [0-9]{4} [A-Z]+ [0-9]{4}$'; then
    pass "Passphrase $i: $PHRASE"
  else
    fail "Passphrase $i bad format: $PHRASE"
  fi
done

echo ""
echo "=== Test 2: False-positive resistance ==="
# Common words that could appear naturally in code output
MOCK_TRANSCRIPT="$TMPDIR/mock-transcript.txt"
cat > "$MOCK_TRANSCRIPT" <<'EOF'
DONE
COMPLETE
PASS
TRUE
SUCCESS
ALL TESTS PASSING
TASK COMPLETE
Build succeeded
Tests passed: 42/42
EOF

# Generate a test passphrase
TEST_PHRASE=$(generate_passphrase)
echo "  Test passphrase: $TEST_PHRASE"

# Check that NO common word triggers detection
while IFS= read -r line; do
  if echo "$line" | grep -qFx "$TEST_PHRASE"; then
    fail "False positive on: '$line'"
  else
    pass "No false positive on: '$line'"
  fi
done < "$MOCK_TRANSCRIPT"

echo ""
echo "=== Test 3: True-positive detection ==="
# Add the actual passphrase to the transcript
echo "$TEST_PHRASE" >> "$MOCK_TRANSCRIPT"

if grep -qFx "$TEST_PHRASE" "$MOCK_TRANSCRIPT"; then
  pass "Passphrase detected when present"
else
  fail "Passphrase NOT detected when present"
fi

echo ""
echo "=== Test 4: Prepend mode detection ==="
USER_PROMISE="ALL TESTS PASSING"
COMBINED="${TEST_PHRASE}::${USER_PROMISE}"
echo "$COMBINED" > "$TMPDIR/combined-transcript.txt"

if grep -qFx "$COMBINED" "$TMPDIR/combined-transcript.txt"; then
  pass "Combined passphrase detected: $COMBINED"
else
  fail "Combined passphrase NOT detected"
fi

# Verify the user's original promise alone does NOT match the combined
if echo "$USER_PROMISE" | grep -qFx "$COMBINED"; then
  fail "User promise alone matched combined (should not)"
else
  pass "User promise alone does NOT match combined"
fi

echo ""
echo "=== Test 5: Uniqueness (5 passphrases should all differ) ==="
PHRASES=()
for i in $(seq 1 5); do
  PHRASES+=("$(generate_passphrase)")
done
UNIQUE_COUNT=$(printf '%s\n' "${PHRASES[@]}" | sort -u | wc -l)
if [[ $UNIQUE_COUNT -eq 5 ]]; then
  pass "All 5 passphrases are unique"
else
  fail "Only $UNIQUE_COUNT of 5 passphrases are unique"
fi

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
