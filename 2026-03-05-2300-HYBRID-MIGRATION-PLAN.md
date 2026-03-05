# Ralph Loop: Plugin-to-Hybrid Migration Plan

## Overview

Migrate ralph-loop from a marketplace plugin to a hybrid approach:
- Local commands in ~/.claude/commands/ (already partially exist)
- Stop hook in ~/.claude/settings.json (replaces plugin hooks.json)
- Repo remains the single source of truth for all scripts

This eliminates the `/plugin update` overwrite problem permanently.

## Current State (Pre-Migration)

- Plugin: `ralph-loop@claude-plugins-official` enabled in settings.json
- Plugin hooks.json: Stop hook via `${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh`
- Plugin commands: `/ralph-loop:ralph-loop`, `/ralph-loop:cancel-ralph`, `/ralph-loop:help`
- Local commands: `/ralph-loop` (in ~/.claude/commands/ralph-loop.md)
- Settings.json hooks: SessionStart (cache-watchdog.sh), PostToolUse (lint/format)
- Sync workflow: edit -> cache-sync.sh -> new session

## Target State (Post-Migration)

- Plugin: DISABLED (`false` in enabledPlugins)
- Settings.json hooks: Stop hook pointing to repo's stop-hook.sh
- Local commands: `/ralph-loop`, `/cancel-ralph`, `/ralph-loop-help`
- Sync workflow: edit -> new session (no cache-sync needed)
- cache-sync.sh: RETAINED but only needed after `/plugin update` if re-enabled

## Migration Steps

### Step 1: Create/Update Local Commands

Ensure these files exist in ~/.claude/commands/:

1. `ralph-loop.md` — already exists, needs update to use absolute path
2. `cancel-ralph.md` — copy from repo commands/
3. `ralph-loop-help.md` — copy from repo commands/help.md (renamed to avoid subcommand ambiguity)

Key change: Replace `${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh` with absolute path
`$REPO/scripts/setup-ralph-loop.sh`

### Step 2: Add Stop Hook to settings.json

Add a "Stop" entry to the existing "hooks" object in ~/.claude/settings.json:

```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash $REPO/scripts/stop-hook.sh",
        "timeout": 60
      }
    ]
  }
]
```

NOTE: Timeout set to 60s (stop-hook.sh does jq parsing, file operations, and potential consolidation).

### Step 3: Disable the Plugin

In ~/.claude/settings.json, change:
```json
"ralph-loop@claude-plugins-official": true
```
to:
```json
"ralph-loop@claude-plugins-official": false
```

### Step 4: Remove SessionStart Cache Watchdog

The cache-watchdog.sh SessionStart hook is no longer needed (we're not syncing to marketplace).
Remove or comment out this entry from settings.json hooks.SessionStart:
```json
{
  "hooks": [
    {
      "type": "command",
      "command": "bash $REPO/scripts/cache-watchdog.sh",
      "timeout": 10
    }
  ]
}
```

### Step 5: Start New Session

Hook changes require a new session to take effect.

### Step 6: Verify

In the new session:
- `/ralph-loop "test task" --max-iterations 2 --completion-promise "TEST DONE"` should work
- `/cancel-ralph` should list/cancel active loops
- Plugin commands `/ralph-loop:ralph-loop` should NOT be available (or show as disabled)

## Rollback Procedure

If migration breaks something, run: `bash $REPO/scripts/rollback-to-plugin.sh`

Manual rollback steps:
1. Re-enable plugin: set `"ralph-loop@claude-plugins-official": true` in settings.json
2. Remove Stop hook: delete the "Stop" array from settings.json hooks
3. Re-add cache-watchdog SessionStart hook
4. Run `bash scripts/cache-sync.sh` to restore marketplace patches
5. Start new session

## Edge Cases Researched

### Shared Marketplace Repository
Disabling ralph-loop does NOT affect the marketplace git checkout. Other plugins
(superpowers, rust-analyzer-lsp) remain fully functional. The marketplace repo persists.

### Plugin Commands After Disable
Known bug (GitHub #9996): disabled plugins may still show their tools. If `/ralph-loop:ralph-loop`
still appears after disabling, it won't function. The local `/ralph-loop` takes priority anyway.

### installed_plugins.json
The entry for ralph-loop remains in installed_plugins.json after disabling. This is expected.
It's metadata only and does not affect functionality.

### Hook Stdin Parity
Settings.json Stop hooks receive IDENTICAL stdin JSON as plugin Stop hooks:
session_id, last_assistant_message, transcript_path, stop_hook_active, hook_event_name, cwd.
ADDITIONALLY: settings.json hooks are MORE reliable for JSON output capture (GitHub #10875
documents a bug where plugin hooks.json output isn't properly captured).

### Re-enabling the Plugin
Set `"ralph-loop@claude-plugins-official": true` and start a new session. The marketplace
version (possibly overwritten by /plugin update) would load. Run cache-sync.sh first.

## REVIEWABLE Decisions

1. REVIEWABLE: Timeout of 60s for Stop hook. Conservative estimate. Could be 30s for simple iterations.
2. REVIEWABLE: Keeping cache-sync.sh and cache-watchdog.sh vs deleting them. Kept for rollback.
3. REVIEWABLE: Renaming help.md to ralph-loop-help.md for local command (avoids namespace confusion).
