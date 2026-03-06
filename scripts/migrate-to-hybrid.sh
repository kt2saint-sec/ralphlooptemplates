#!/bin/bash
# Migrate ralph-loop from marketplace plugin to hybrid (local commands + settings.json hooks)
# This permanently solves the /plugin update overwrite problem.
# Rollback: bash scripts/rollback-to-plugin.sh

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"

echo "Migrating ralph-loop from plugin to hybrid approach..."
echo "  Repo: $REPO"
echo ""

# Pre-flight: verify jq is available
if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  echo "  Install: sudo apt install jq" >&2
  exit 1
fi

# Pre-flight: verify settings.json exists
if [[ ! -f "$SETTINGS" ]]; then
  echo "ERROR: $SETTINGS not found." >&2
  exit 1
fi

# Pre-flight: backup settings.json
cp "$SETTINGS" "${SETTINGS}.pre-migration.bak"
echo "OK: Backed up settings.json to ${SETTINGS}.pre-migration.bak"

# Step 1: Update local commands
echo ""
echo "--- Step 1: Local commands ---"
mkdir -p "$COMMANDS_DIR"

# ralph-loop.md (update to use absolute path)
cat > "$COMMANDS_DIR/ralph-loop.md" << 'CMDEOF'
---
description: "Start Ralph Loop in current session"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT]"
allowed-tools: ["Bash(REPO_PLACEHOLDER/scripts/setup-ralph-loop.sh:*)"]
---

# Ralph Loop Command

Execute the setup script to initialize the Ralph loop:

```!
"REPO_PLACEHOLDER/scripts/setup-ralph-loop.sh" $ARGUMENTS
```

Please work on the task. When you try to exit, the Ralph loop will feed the SAME PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

CRITICAL RULE: If a completion passphrase is set, you may ONLY output it on its own line when the statement is completely and unequivocally TRUE. The passphrase is auto-generated (RALPH- prefix + hex hash from /dev/urandom) and shown in the setup output. Do not output false promises to escape the loop. The loop continues until genuine completion.
CMDEOF
# Replace placeholder with actual repo path
sed -i "s|REPO_PLACEHOLDER|$REPO|g" "$COMMANDS_DIR/ralph-loop.md"
echo "OK: Updated $COMMANDS_DIR/ralph-loop.md"

# cancel-ralph.md
cp "$REPO/commands/cancel-ralph.md" "$COMMANDS_DIR/cancel-ralph.md"
echo "OK: Copied $COMMANDS_DIR/cancel-ralph.md"

# ralph-loop-help.md (renamed from help.md to avoid subcommand confusion)
if [[ -f "$REPO/commands/help.md" ]]; then
  cp "$REPO/commands/help.md" "$COMMANDS_DIR/ralph-loop-help.md"
  echo "OK: Copied $COMMANDS_DIR/ralph-loop-help.md"
fi

# Step 2: Add Stop hook to settings.json
echo ""
echo "--- Step 2: Add Stop hook ---"
TEMP=$(mktemp)

# Check if Stop hook already exists
HAS_STOP=$(jq 'has("hooks") and (.hooks | has("Stop"))' "$SETTINGS")
if [[ "$HAS_STOP" == "true" ]]; then
  echo "SKIP: Stop hook already exists in settings.json"
else
  jq --arg cmd "bash $REPO/scripts/stop-hook.sh" \
    '.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd, "timeout": 60}]}]' \
    "$SETTINGS" > "$TEMP"
  mv "$TEMP" "$SETTINGS"
  echo "OK: Added Stop hook pointing to $REPO/scripts/stop-hook.sh"
fi

# Step 3: Remove plugin entry entirely (prevents GitHub #28554 spontaneous re-enable)
echo ""
echo "--- Step 3: Remove plugin entry ---"
CURRENT=$(jq -r '.enabledPlugins["ralph-loop@claude-plugins-official"] // "missing"' "$SETTINGS")
if [[ "$CURRENT" != "missing" ]]; then
  TEMP=$(mktemp)
  jq 'del(.enabledPlugins["ralph-loop@claude-plugins-official"])' "$SETTINGS" > "$TEMP"
  mv "$TEMP" "$SETTINGS"
  echo "OK: Removed ralph-loop@claude-plugins-official from enabledPlugins"
else
  echo "SKIP: Plugin entry already absent"
fi

# Step 4: Remove cache-watchdog SessionStart hook (no longer needed)
echo ""
echo "--- Step 4: Remove cache-watchdog hook ---"
TEMP=$(mktemp)
jq '.hooks.SessionStart = [.hooks.SessionStart[] | select(.hooks[].command | contains("cache-watchdog") | not)]' "$SETTINGS" > "$TEMP"
mv "$TEMP" "$SETTINGS"
echo "OK: Removed cache-watchdog SessionStart hook"

echo ""
echo "Migration complete!"
echo ""
echo "NEXT STEPS:"
echo "  1. Start a NEW Claude Code session for changes to take effect"
echo "  2. Verify: /ralph-loop \"test\" --max-iterations 2 --completion-promise \"TEST DONE\""
echo "  3. Verify: /cancel-ralph"
echo ""
echo "ROLLBACK (if needed):"
echo "  bash $REPO/scripts/rollback-to-plugin.sh"
echo ""
echo "WHAT CHANGED:"
echo "  - Plugin entry removed from enabledPlugins (prevents #28554 re-enable)"
echo "  - Stop hook in settings.json (reads directly from repo, no cache-sync needed)"
echo "  - Local commands: /ralph-loop, /cancel-ralph, /ralph-loop-help"
echo "  - Workflow: edit -> new session (was: edit -> cache-sync -> new session)"
