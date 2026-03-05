#!/bin/bash
# Ralph Loop Cache Sync
# Copies local repo files to the active plugin cache directory.
# Handles the scripts/ -> hooks/ path mapping for stop-hook.sh.
# Run manually or called by cache-watchdog.sh when mismatches detected.

set -euo pipefail

# Derive repo path from script location (portable across users/clone locations)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_BASE="$HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop"

# Find active cache directory (the one without .orphaned_at)
CACHE_DIR=""
for dir in "$CACHE_BASE"/*/; do
  if [[ -d "$dir" ]] && [[ ! -f "$dir/.orphaned_at" ]]; then
    CACHE_DIR="$dir"
    break
  fi
done

if [[ -z "$CACHE_DIR" ]]; then
  echo "❌ No active ralph-loop plugin cache found" >&2
  echo "   Expected: $CACHE_BASE/<version>/ (without .orphaned_at)" >&2
  exit 1
fi

echo "Syncing repo -> cache"
echo "  Repo:  $REPO"
echo "  Cache: $CACHE_DIR"
echo ""

# Path mapping: local -> cache (note: scripts/stop-hook.sh -> hooks/stop-hook.sh)
SYNC_PAIRS=(
  "$REPO/scripts/stop-hook.sh|${CACHE_DIR}hooks/stop-hook.sh"
  "$REPO/scripts/setup-ralph-loop.sh|${CACHE_DIR}scripts/setup-ralph-loop.sh"
  "$REPO/commands/cancel-ralph.md|${CACHE_DIR}commands/cancel-ralph.md"
)

SYNCED=0
ERRORS=0

for pair in "${SYNC_PAIRS[@]}"; do
  LOCAL="${pair%%|*}"
  CACHED="${pair##*|}"
  LABEL=$(basename "$LOCAL")

  if [[ ! -f "$LOCAL" ]]; then
    echo "  SKIP: $LABEL (local file missing: $LOCAL)"
    continue
  fi

  # Ensure target directory exists
  mkdir -p "$(dirname "$CACHED")"

  cp "$LOCAL" "$CACHED"

  # Verify copy succeeded
  if diff -q "$LOCAL" "$CACHED" > /dev/null 2>&1; then
    echo "  OK: $LABEL"
    SYNCED=$((SYNCED + 1))
  else
    echo "  ERROR: $LABEL (copy succeeded but diff failed)" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "Synced: $SYNCED files, Errors: $ERRORS"

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi
