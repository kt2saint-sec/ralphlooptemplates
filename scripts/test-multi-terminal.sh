#!/bin/bash
# Test: ls -t heuristic for multi-terminal session resolution
# Tests both identical-timestamp and different-timestamp scenarios
# Self-contained — uses mktemp for artifacts, cleans up via trap

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

echo "=== Test 1: ls -t with 1-second time difference (20 runs) ==="
CORRECT=0
for i in $(seq 1 20); do
  rm -f "$TMPDIR"/ralph-loop.*.local.md
  # Create older file first
  touch -t 202603051200.00 "$TMPDIR/ralph-loop.session-old.local.md"
  # Create newer file 1 second later
  touch -t 202603051200.01 "$TMPDIR/ralph-loop.session-new.local.md"

  SELECTED=$(ls -t "$TMPDIR"/ralph-loop.*.local.md 2>/dev/null | head -1)
  SELECTED_BASE=$(basename "$SELECTED")

  if [[ "$SELECTED_BASE" == "ralph-loop.session-new.local.md" ]]; then
    CORRECT=$((CORRECT + 1))
  fi
done

if [[ $CORRECT -eq 20 ]]; then
  pass "1-second difference: $CORRECT/20 correct (always picks newest)"
else
  fail "1-second difference: $CORRECT/20 correct (should be 20/20)"
fi

echo ""
echo "=== Test 2: ls -t with IDENTICAL timestamps (20 runs) ==="
echo "  NOTE: Identical timestamps means ls -t falls back to filesystem ordering."
echo "  This test documents the behavior — consistency is ideal but not guaranteed."
RESULTS_A=0
RESULTS_B=0
for i in $(seq 1 20); do
  rm -f "$TMPDIR"/ralph-loop.*.local.md
  # Create both files with identical timestamp
  touch -t 202603051200.00 "$TMPDIR/ralph-loop.session-aaa.local.md"
  touch -t 202603051200.00 "$TMPDIR/ralph-loop.session-zzz.local.md"

  SELECTED=$(ls -t "$TMPDIR"/ralph-loop.*.local.md 2>/dev/null | head -1)
  SELECTED_BASE=$(basename "$SELECTED")

  if [[ "$SELECTED_BASE" == "ralph-loop.session-aaa.local.md" ]]; then
    RESULTS_A=$((RESULTS_A + 1))
  else
    RESULTS_B=$((RESULTS_B + 1))
  fi
done

echo "  session-aaa selected: $RESULTS_A/20"
echo "  session-zzz selected: $RESULTS_B/20"

if [[ $RESULTS_A -eq 20 ]] || [[ $RESULTS_B -eq 20 ]]; then
  pass "Identical timestamps: consistent selection (one file always wins)"
else
  fail "Identical timestamps: inconsistent — $RESULTS_A vs $RESULTS_B (tiebreaker needed)"
fi

echo ""
echo "=== Test 3: Single state file (normal case) ==="
rm -f "$TMPDIR"/ralph-loop.*.local.md
touch "$TMPDIR/ralph-loop.single-session.local.md"

shopt -s nullglob
FILES=("$TMPDIR"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 1 ]]; then
  pass "Single file found, no ls -t needed"
else
  fail "Expected 1 file, found ${#FILES[@]}"
fi

echo ""
echo "=== Test 4: No state files (fast exit case) ==="
rm -f "$TMPDIR"/ralph-loop.*.local.md

shopt -s nullglob
FILES=("$TMPDIR"/ralph-loop.*.local.md)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  pass "No files — hook would exit early"
else
  fail "Expected 0 files, found ${#FILES[@]}"
fi

echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo ""
echo "RISK ASSESSMENT:"
echo "  Normal case (different timestamps): SAFE — ls -t reliably picks newest"
echo "  Edge case (identical timestamps): See Test 2 results above"
echo "  Mitigation: UUID-based session IDs make same-second collision extremely unlikely"
echo "  CLAUDE_SESSION_ID env var: NOT AVAILABLE (verified 2026-03-05)"

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo ""
  echo "ALL TESTS PASSED"
  exit 0
else
  echo ""
  echo "SOME TESTS FAILED — see details above"
  exit 1
fi
