#!/bin/bash
# Rollback: Hybrid -> Plugin approach
# Restores ralph-loop as a marketplace plugin and removes settings.json Stop hook
# Run this if the hybrid migration causes issues.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "Rolling back hybrid migration to plugin approach..."
echo ""

# Step 1: Re-enable plugin in settings.json
if command -v jq > /dev/null 2>&1; then
  TEMP=$(mktemp)
  jq '.enabledPlugins["ralph-loop@claude-plugins-official"] = true' "$SETTINGS" > "$TEMP"
  mv "$TEMP" "$SETTINGS"
  echo "OK: Re-enabled ralph-loop@claude-plugins-official in settings.json"
else
  echo "MANUAL: Set \"ralph-loop@claude-plugins-official\": true in $SETTINGS"
fi

# Step 2: Remove Stop hook from settings.json
if command -v jq > /dev/null 2>&1; then
  TEMP=$(mktemp)
  jq 'del(.hooks.Stop)' "$SETTINGS" > "$TEMP"
  mv "$TEMP" "$SETTINGS"
  echo "OK: Removed Stop hook from settings.json"
else
  echo "MANUAL: Remove the \"Stop\" entry from hooks in $SETTINGS"
fi

# Step 3: Re-add cache-watchdog SessionStart hook
if command -v jq > /dev/null 2>&1; then
  HAS_WATCHDOG=$(jq '.hooks.SessionStart // [] | map(select(.hooks[].command | contains("cache-watchdog"))) | length' "$SETTINGS")
  if [[ "$HAS_WATCHDOG" == "0" ]]; then
    TEMP=$(mktemp)
    jq '.hooks.SessionStart += [{"hooks": [{"type": "command", "command": "bash '"$REPO"'/scripts/cache-watchdog.sh", "timeout": 10}]}]' "$SETTINGS" > "$TEMP"
    mv "$TEMP" "$SETTINGS"
    echo "OK: Re-added cache-watchdog SessionStart hook"
  else
    echo "SKIP: cache-watchdog SessionStart hook already present"
  fi
fi

# Step 4: Sync patched files to marketplace
echo ""
echo "Running cache-sync.sh to restore marketplace patches..."
bash "$REPO/scripts/cache-sync.sh"

echo ""
echo "Rollback complete. Start a NEW session for changes to take effect."
echo ""
echo "After new session, verify:"
echo "  /ralph-loop:ralph-loop \"test\" --max-iterations 2 --completion-promise \"TEST\""
