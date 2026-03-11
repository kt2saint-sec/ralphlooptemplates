#!/bin/bash
# Test: v3 epoch-stamped passphrase format (RALPH-{epoch8}-{random40})
# Validates format, epoch accuracy, cross-session uniqueness, and detection compatibility.
# Self-contained — uses mktemp for artifacts, cleans up via trap.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

# Source the generate_passphrase function from setup script
eval "$(sed -n '/^generate_passphrase()/,/^}/p' "$(dirname "$0")/setup-ralph-loop.sh")"

# ============================================================
echo "=== Section 1: New Format Validation (5 tests) ==="
for i in $(seq 1 5); do
  PHRASE=$(generate_passphrase)
  if echo "$PHRASE" | grep -qE '^RALPH-[0-9a-f]{8}-[0-9a-f]{40}$'; then
    pass "Passphrase $i format valid: $PHRASE"
  else
    fail "Passphrase $i bad format: $PHRASE"
  fi
done

# ============================================================
echo ""
echo "=== Section 2: Epoch Component Validation (3 tests) ==="
PHRASE=$(generate_passphrase)
EPOCH_HEX=$(echo "$PHRASE" | sed 's/^RALPH-\([0-9a-f]\{8\}\)-.*/\1/')
EPOCH_DEC=$(printf '%d' "0x${EPOCH_HEX}")
NOW=$(date +%s)
DIFF=$((NOW - EPOCH_DEC))
if [[ $DIFF -ge 0 ]] && [[ $DIFF -le 10 ]]; then
  pass "Test 6: Epoch within 10 seconds of now (diff=${DIFF}s)"
else
  fail "Test 6: Epoch too far from now (diff=${DIFF}s, epoch=${EPOCH_DEC}, now=${NOW})"
fi

PHRASE_A=$(generate_passphrase)
PHRASE_B=$(generate_passphrase)
EPOCH_A=$(echo "$PHRASE_A" | sed 's/^RALPH-\([0-9a-f]\{8\}\)-.*/\1/')
EPOCH_B=$(echo "$PHRASE_B" | sed 's/^RALPH-\([0-9a-f]\{8\}\)-.*/\1/')
EPOCH_A_DEC=$(printf '%d' "0x${EPOCH_A}")
EPOCH_B_DEC=$(printf '%d' "0x${EPOCH_B}")
EPOCH_DIFF=$((EPOCH_B_DEC - EPOCH_A_DEC))
if [[ $EPOCH_DIFF -ge 0 ]] && [[ $EPOCH_DIFF -le 1 ]]; then
  pass "Test 7: Two instant passphrases have same/+1 epoch (diff=${EPOCH_DIFF})"
else
  fail "Test 7: Epoch diff too large: $EPOCH_DIFF"
fi

if echo "$EPOCH_HEX" | grep -qE '^[0-9a-f]{8}$'; then
  pass "Test 8: Epoch portion is valid hex"
else
  fail "Test 8: Epoch portion invalid: $EPOCH_HEX"
fi

# ============================================================
echo ""
echo "=== Section 3: Random Component Validation (2 tests) ==="
RANDOMS=()
for i in $(seq 1 5); do
  P=$(generate_passphrase)
  R=$(echo "$P" | sed 's/^RALPH-[0-9a-f]\{8\}-//')
  RANDOMS+=("$R")
done
UNIQUE_RANDOMS=$(printf '%s\n' "${RANDOMS[@]}" | sort -u | wc -l)
if [[ $UNIQUE_RANDOMS -eq 5 ]]; then
  pass "Test 9: All 5 random portions are unique"
else
  fail "Test 9: Only $UNIQUE_RANDOMS of 5 random portions unique"
fi

RAND_LEN=${#RANDOMS[0]}
if [[ $RAND_LEN -eq 40 ]]; then
  pass "Test 10: Random portion is exactly 40 hex chars"
else
  fail "Test 10: Random portion length is $RAND_LEN (expected 40)"
fi

# ============================================================
echo ""
echo "=== Section 4: Cross-Session Isolation (3 tests) ==="
BATCH_FILE="$TMPDIR/batch.txt"
for i in $(seq 1 100); do
  generate_passphrase >> "$BATCH_FILE"
done
TOTAL=$(wc -l < "$BATCH_FILE")
UNIQUE=$(sort -u "$BATCH_FILE" | wc -l)

if [[ $TOTAL -eq 100 ]]; then
  pass "Test 11: Generated 100 passphrases"
else
  fail "Test 11: Generated $TOTAL passphrases (expected 100)"
fi

if [[ $UNIQUE -eq 100 ]]; then
  pass "Test 12: All 100 passphrases unique"
else
  fail "Test 12: Only $UNIQUE of 100 unique"
fi

# Two passphrases in same second still differ (random portion)
SAME_SEC_A=$(generate_passphrase)
SAME_SEC_B=$(generate_passphrase)
if [[ "$SAME_SEC_A" != "$SAME_SEC_B" ]]; then
  pass "Test 13: Two same-second passphrases differ"
else
  fail "Test 13: Two same-second passphrases identical: $SAME_SEC_A"
fi

# ============================================================
echo ""
echo "=== Section 5: Detection Compatibility (4 tests) ==="
TEST_PHRASE=$(generate_passphrase)
echo "$TEST_PHRASE" > "$TMPDIR/detect.txt"

if grep -qFx "$TEST_PHRASE" "$TMPDIR/detect.txt"; then
  pass "Test 14: grep -Fx finds new-format passphrase"
else
  fail "Test 14: grep -Fx missed new-format passphrase"
fi

PREFIX=$(echo "$TEST_PHRASE" | cut -c1-20)
if echo "$PREFIX" | grep -qFx "$TEST_PHRASE"; then
  fail "Test 15: Partial match should NOT trigger"
else
  pass "Test 15: Partial passphrase does NOT match"
fi

USER_PROMISE="ALL TESTS PASSING"
COMBINED="${TEST_PHRASE}::${USER_PROMISE}"
echo "$COMBINED" > "$TMPDIR/combined.txt"
if grep -qFx "$COMBINED" "$TMPDIR/combined.txt"; then
  pass "Test 16: Combined passphrase::promise detected"
else
  fail "Test 16: Combined passphrase::promise NOT detected"
fi

if echo "$USER_PROMISE" | grep -qFx "$COMBINED"; then
  fail "Test 17: User promise alone should NOT match combined"
else
  pass "Test 17: User promise alone does NOT match combined"
fi

# ============================================================
echo ""
echo "=== Section 6: False Positive Resistance (4 tests) ==="
FP_PHRASE=$(generate_passphrase)
for word in DONE COMPLETE PASS SUCCESS; do
  if echo "$word" | grep -qFx "$FP_PHRASE"; then
    fail "Test 18-21: False positive on '$word'"
  else
    pass "Test 18-21: No false positive on '$word'"
  fi
done

# ============================================================
echo ""
echo "=== Section 7: Backward Compatibility (2 tests) ==="
OLD_V2="RALPH-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e8f0a1b3"
echo "$OLD_V2" > "$TMPDIR/oldv2.txt"
if grep -qFx "$OLD_V2" "$TMPDIR/oldv2.txt"; then
  pass "Test 22: Old RALPH-hex48 format still detectable by grep -Fx"
else
  fail "Test 22: Old RALPH-hex48 format NOT detectable"
fi

OLD_V1="GRANITE 1234 FALCON 5678 COSINE 9012"
echo "$OLD_V1" > "$TMPDIR/oldv1.txt"
if grep -qFx "$OLD_V1" "$TMPDIR/oldv1.txt"; then
  pass "Test 23: Old WORD NNNN format still detectable by grep -Fx"
else
  fail "Test 23: Old WORD NNNN format NOT detectable"
fi

# ============================================================
echo ""
echo "=== Section 8: YAML Frontmatter Round-Trip (2 tests) ==="
YAML_PHRASE=$(generate_passphrase)
YAML_FILE="$TMPDIR/yaml-test.md"
cat > "$YAML_FILE" <<EOF
---
completion_promise: "${YAML_PHRASE}"
---
content
EOF
EXTRACTED=$(sed -n 's/^completion_promise: "\(.*\)"/\1/p' "$YAML_FILE")
if [[ "$EXTRACTED" == "$YAML_PHRASE" ]]; then
  pass "Test 24: Passphrase survives YAML round-trip"
else
  fail "Test 24: YAML round-trip failed: got '$EXTRACTED' expected '$YAML_PHRASE'"
fi

YAML_COMBINED="${YAML_PHRASE}::MY PROMISE"
cat > "$YAML_FILE" <<EOF
---
completion_promise: "${YAML_COMBINED}"
---
content
EOF
EXTRACTED2=$(sed -n 's/^completion_promise: "\(.*\)"/\1/p' "$YAML_FILE")
if [[ "$EXTRACTED2" == "$YAML_COMBINED" ]]; then
  pass "Test 25: Combined passphrase with :: survives YAML round-trip"
else
  fail "Test 25: Combined YAML round-trip failed: got '$EXTRACTED2'"
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
