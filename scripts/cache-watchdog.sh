#!/bin/bash
# Ralph Loop Cache Watchdog
# Compares local repo files against plugin cache on session start.
# Warns if cache has been overwritten by an update (patches lost).
# Runs as a SessionStart hook — fast, read-only, no side effects.

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
  exit 0  # No active cache found, nothing to check
fi

# Path mapping: local -> cache (note: scripts/stop-hook.sh -> hooks/stop-hook.sh)
DIFFS_FOUND=0
check_file() {
  local LOCAL="$1"
  local CACHED="$2"
  local LABEL="$3"
  if [[ -f "$LOCAL" ]] && [[ -f "$CACHED" ]]; then
    if ! diff -q "$LOCAL" "$CACHED" > /dev/null 2>&1; then
      if [[ $DIFFS_FOUND -eq 0 ]]; then
        echo "⚠️  Ralph Loop cache out of sync!" >&2
        echo "   Cache: $CACHE_DIR" >&2
        echo "   Repo:  $REPO" >&2
        echo "" >&2
      fi
      DIFFS_FOUND=$((DIFFS_FOUND + 1))
      echo "   MISMATCH: $LABEL" >&2
    fi
  fi
}

check_file "$REPO/scripts/stop-hook.sh" "${CACHE_DIR}hooks/stop-hook.sh" "stop-hook.sh (scripts/ -> hooks/)"
check_file "$REPO/scripts/setup-ralph-loop.sh" "${CACHE_DIR}scripts/setup-ralph-loop.sh" "setup-ralph-loop.sh"
check_file "$REPO/commands/cancel-ralph.md" "${CACHE_DIR}commands/cancel-ralph.md" "cancel-ralph.md"

if [[ $DIFFS_FOUND -gt 0 ]]; then
  echo "" >&2
  echo "   To re-sync, run: bash $REPO/scripts/cache-sync.sh" >&2
fi

exit 0
