#!/bin/bash
# Test: Session 20 fixes — SessionStart hook matcher + sandbox path migration to nvme-fast
# Self-contained — validates file contents in-place. No mock needed.

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
NVME_SANDBOX="/mnt/nvme-fast/claude-workspace/sandbox"

echo "=== Test Suite: Session 20 Fixes ==="
echo ""

# ============================================================
echo "=== Test 1: SessionStart hook has 'startup' matcher ==="

if [[ -f "$SETTINGS" ]]; then
  # Extract the SessionStart block and check for matcher
  if jq -e '.hooks.SessionStart[0].matcher' "$SETTINGS" >/dev/null 2>&1; then
    MATCHER=$(jq -r '.hooks.SessionStart[0].matcher' "$SETTINGS")
    if [[ "$MATCHER" == "startup" ]]; then
      pass "SessionStart hook has matcher: startup"
    else
      fail "SessionStart hook matcher is '$MATCHER', expected 'startup'"
    fi
  else
    fail "SessionStart hook has no matcher field"
  fi
else
  fail "settings.json not found at $SETTINGS"
fi

echo ""

# ============================================================
echo "=== Test 2: SessionStart hook still has correct command ==="

if [[ -f "$SETTINGS" ]]; then
  CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS")
  if [[ "$CMD" == *"init.sh"* ]]; then
    pass "SessionStart hook command points to init.sh"
  else
    fail "SessionStart hook command is '$CMD', expected init.sh path"
  fi
else
  fail "settings.json not found"
fi

echo ""

# ============================================================
echo "=== Test 3: nvme-fast sandbox directory exists ==="

if [[ -d "$NVME_SANDBOX" ]]; then
  pass "nvme-fast sandbox directory exists: $NVME_SANDBOX"
else
  fail "nvme-fast sandbox directory missing: $NVME_SANDBOX"
fi

echo ""

# ============================================================
echo "=== Test 4: Repo ralphtemplatetest.md uses nvme-fast sandbox path ==="

REPO_V1_TEST="$REPO_DIR/commands/ralphtemplatetest.md"
if [[ -f "$REPO_V1_TEST" ]]; then
  if grep -q "/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-" "$REPO_V1_TEST"; then
    pass "ralphtemplatetest.md references nvme-fast sandbox"
  else
    fail "ralphtemplatetest.md still references old sandbox path"
  fi
  # Negative: should NOT have /tmp/ralph-test-sandbox
  if grep -q "/tmp/ralph-test-sandbox-" "$REPO_V1_TEST"; then
    fail "ralphtemplatetest.md still has /tmp/ralph-test-sandbox- references"
  else
    pass "ralphtemplatetest.md has no /tmp sandbox references"
  fi
else
  fail "ralphtemplatetest.md not found at $REPO_V1_TEST"
fi

echo ""

# ============================================================
echo "=== Test 5: Repo ralphtemplatetest-v2.md uses nvme-fast sandbox path ==="

REPO_V2_TEST="$REPO_DIR/commands/ralphtemplatetest-v2.md"
if [[ -f "$REPO_V2_TEST" ]]; then
  if grep -q "/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-" "$REPO_V2_TEST"; then
    pass "ralphtemplatetest-v2.md references nvme-fast sandbox"
  else
    fail "ralphtemplatetest-v2.md still references old sandbox path"
  fi
  if grep -q "/tmp/ralph-test-sandbox-" "$REPO_V2_TEST"; then
    fail "ralphtemplatetest-v2.md still has /tmp sandbox references"
  else
    pass "ralphtemplatetest-v2.md has no /tmp sandbox references"
  fi
else
  fail "ralphtemplatetest-v2.md not found at $REPO_V2_TEST"
fi

echo ""

# ============================================================
echo "=== Test 6: ~/.claude/commands copies are in sync with repo ==="

SYNC_FAIL=0
for CMD_FILE in ralphtemplatetest.md ralphtemplatetest-v2.md; do
  REPO_FILE="$REPO_DIR/commands/$CMD_FILE"
  LOCAL_FILE="$HOME/.claude/commands/$CMD_FILE"
  if [[ -f "$LOCAL_FILE" ]]; then
    if diff -q "$REPO_FILE" "$LOCAL_FILE" >/dev/null 2>&1; then
      pass "$CMD_FILE: repo and ~/.claude/commands are in sync"
    else
      fail "$CMD_FILE: repo and ~/.claude/commands DIFFER"
      SYNC_FAIL=1
    fi
  else
    fail "$CMD_FILE: missing from ~/.claude/commands/"
    SYNC_FAIL=1
  fi
done

echo ""

# ============================================================
echo "=== Test 7: stop-hook.sh debug path references nvme-fast ==="

STOP_HOOK="$REPO_DIR/scripts/stop-hook.sh"
if [[ -f "$STOP_HOOK" ]]; then
  if grep -q "/mnt/nvme-fast/claude-workspace/tmp/ralph-hook-debug.json" "$STOP_HOOK"; then
    pass "stop-hook.sh debug path references nvme-fast"
  else
    fail "stop-hook.sh debug path still references /tmp"
  fi
  if grep -q '"/tmp/ralph-hook-debug.json"' "$STOP_HOOK"; then
    fail "stop-hook.sh still has /tmp/ralph-hook-debug.json"
  else
    pass "stop-hook.sh has no /tmp debug path"
  fi
else
  fail "stop-hook.sh not found"
fi

echo ""

# ============================================================
echo "=== Test 8: CLAUDE.md sandbox path updated ==="

CLAUDE_MD="$REPO_DIR/CLAUDE.md"
if [[ -f "$CLAUDE_MD" ]]; then
  if grep -q "/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-" "$CLAUDE_MD"; then
    pass "CLAUDE.md references nvme-fast sandbox"
  else
    fail "CLAUDE.md still references /tmp sandbox"
  fi
else
  fail "CLAUDE.md not found"
fi

echo ""

# ============================================================
echo "=== Test 9: .gitignore debug path updated ==="

GITIGNORE="$REPO_DIR/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
  if grep -q "ralph-hook-debug.json" "$GITIGNORE"; then
    # Check it's the nvme-fast path, not the old bare /tmp path
    # Use grep -F for exact line match (old path was exactly "/tmp/ralph-hook-debug.json")
    if grep -qFx "/tmp/ralph-hook-debug.json" "$GITIGNORE"; then
      fail ".gitignore still has bare /tmp/ralph-hook-debug.json"
    else
      pass ".gitignore debug path updated (no bare /tmp path)"
    fi
  else
    pass ".gitignore has no debug path entry (acceptable)"
  fi
else
  fail ".gitignore not found"
fi

echo ""

# ============================================================
echo "=== Test 10: No /tmp/ralph-test-sandbox references remain in template commands ==="

REMAINING=$(grep -rl "/tmp/ralph-test-sandbox" "$REPO_DIR/commands/" 2>/dev/null || true)
if [[ -z "$REMAINING" ]]; then
  pass "No /tmp/ralph-test-sandbox references in commands/"
else
  fail "Found /tmp/ralph-test-sandbox in: $REMAINING"
fi

echo ""

# ============================================================
echo "=== Test 11: ralphtemplate.md and ralphtemplate-v2.md have NO sandbox paths (no Tester) ==="

for CMD_FILE in ralphtemplate.md ralphtemplate-v2.md; do
  FILE="$REPO_DIR/commands/$CMD_FILE"
  if [[ -f "$FILE" ]]; then
    if grep -q "ralph-test-sandbox" "$FILE"; then
      fail "$CMD_FILE unexpectedly contains sandbox path"
    else
      pass "$CMD_FILE has no sandbox paths (correct — no Tester role)"
    fi
  else
    fail "$CMD_FILE not found"
  fi
done

echo ""

# ============================================================
echo "=== Test 12: Stop hook still has no matcher (fires on all stops) ==="

if [[ -f "$SETTINGS" ]]; then
  if jq -e '.hooks.Stop[0].matcher' "$SETTINGS" >/dev/null 2>&1; then
    fail "Stop hook has a matcher (should have none — needs to fire on all stops)"
  else
    pass "Stop hook has no matcher (correct — fires on all session ends)"
  fi
else
  fail "settings.json not found"
fi

echo ""

# ============================================================
echo "=== RESULTS ==="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Passed: $PASS_COUNT / $TOTAL"
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "FAILED: $FAIL_COUNT tests"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
