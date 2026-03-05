#!/bin/bash
# Ralph Loop Cache Sync
# Copies local repo files to ALL plugin directories (marketplace, cache, and local).
# Claude Code loads from marketplaces/ (confirmed session 10), so that dir is PRIMARY.
# Handles the scripts/ -> hooks/ path mapping for stop-hook.sh.
# Run manually or called by cache-watchdog.sh when mismatches detected.

set -euo pipefail

# Derive repo path from script location (portable across users/clone locations)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_BASE="$HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop"
MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop"
LOCAL_DIR="$HOME/.claude/plugins/local/ralph-loop"

# Find active cache directory (the one without .orphaned_at)
CACHE_DIR=""
for dir in "$CACHE_BASE"/*/; do
  if [[ -d "$dir" ]] && [[ ! -f "$dir/.orphaned_at" ]]; then
    CACHE_DIR="$dir"
    break
  fi
done

# Build list of target directories (marketplace is mandatory, others optional)
TARGET_DIRS=()
TARGET_LABELS=()

if [[ -d "$MARKETPLACE_DIR" ]]; then
  TARGET_DIRS+=("$MARKETPLACE_DIR")
  TARGET_LABELS+=("marketplace (PRIMARY)")
else
  echo "⚠️  Marketplace dir not found: $MARKETPLACE_DIR" >&2
  echo "   This is the PRIMARY target — Claude Code loads plugins from here." >&2
fi

if [[ -n "$CACHE_DIR" ]]; then
  TARGET_DIRS+=("$CACHE_DIR")
  TARGET_LABELS+=("cache")
fi

if [[ -d "$LOCAL_DIR" ]]; then
  TARGET_DIRS+=("$LOCAL_DIR")
  TARGET_LABELS+=("local")
fi

if [[ ${#TARGET_DIRS[@]} -eq 0 ]]; then
  echo "❌ No plugin directories found to sync to" >&2
  exit 1
fi

echo "Syncing repo -> plugin directories"
echo "  Repo: $REPO"
for i in "${!TARGET_DIRS[@]}"; do
  echo "  Target: ${TARGET_LABELS[$i]} -> ${TARGET_DIRS[$i]}"
done
echo ""

# Source files to sync (repo path -> relative dest path)
# Note: scripts/stop-hook.sh -> hooks/stop-hook.sh (path mapping)
SYNC_FILES=(
  "scripts/stop-hook.sh|hooks/stop-hook.sh"
  "scripts/setup-ralph-loop.sh|scripts/setup-ralph-loop.sh"
  "scripts/learnings-preamble.md|scripts/learnings-preamble.md"
  "commands/cancel-ralph.md|commands/cancel-ralph.md"
  "commands/ralph-loop.md|commands/ralph-loop.md"
  "commands/help.md|commands/help.md"
)

SYNCED=0
ERRORS=0

for target_idx in "${!TARGET_DIRS[@]}"; do
  TARGET="${TARGET_DIRS[$target_idx]}"
  LABEL="${TARGET_LABELS[$target_idx]}"
  echo "--- $LABEL ---"

  for file_pair in "${SYNC_FILES[@]}"; do
    SRC_REL="${file_pair%%|*}"
    DST_REL="${file_pair##*|}"
    SRC="$REPO/$SRC_REL"
    DST="$TARGET/$DST_REL"
    FILE_LABEL=$(basename "$SRC_REL")

    if [[ ! -f "$SRC" ]]; then
      echo "  SKIP: $FILE_LABEL (source missing: $SRC)"
      continue
    fi

    mkdir -p "$(dirname "$DST")"
    cp "$SRC" "$DST"

    if diff -q "$SRC" "$DST" > /dev/null 2>&1; then
      echo "  OK: $FILE_LABEL"
      SYNCED=$((SYNCED + 1))
    else
      echo "  ERROR: $FILE_LABEL (copy succeeded but diff failed)" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done
  echo ""
done

echo "Synced: $SYNCED files across ${#TARGET_DIRS[@]} targets, Errors: $ERRORS"

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi
