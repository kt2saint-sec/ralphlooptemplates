# RESTORE — Ralph Loop Hybrid Recovery

One-command fix for when the Ralph Loop hybrid architecture breaks.

## When to use this

Run `restore-hybrid.sh` if any of these happen:

| Symptom                                        | Cause                                                          |
| ---------------------------------------------- | -------------------------------------------------------------- |
| Ralph loop stops working between sessions      | Plugin re-enabled (GitHub #28554) — double-fire corrupts state |
| `/plugin update` and ralph loop breaks         | Plugin entry re-added to `enabledPlugins`                      |
| `/ralph-loop` command says "command not found" | Local commands deleted or overwritten                          |
| Loop runs but stop hook never fires            | Stop hook missing from `settings.json`                         |
| Stop hook fires but does nothing               | Stop hook pointing to wrong path                               |

## Usage

```bash
# Check what's wrong (no changes)
bash RESTORE/restore-hybrid.sh --dry-run

# Fix everything
bash RESTORE/restore-hybrid.sh

# Fix silently (only prints warnings and fixes)
bash RESTORE/restore-hybrid.sh --quiet
```

**After any fix, start a NEW Claude Code session.** Claude Code caches hook content at session start — edits to `settings.json` have no effect on running sessions.

## What it checks and fixes

1. **Plugin entry removal** — Removes `ralph-loop@claude-plugins-official` from `enabledPlugins` if present (prevents double-fire from GitHub #28554)
2. **Stop hook** — Ensures `settings.json` has a Stop hook pointing to `$REPO/scripts/stop-hook.sh` with >= 60s timeout
3. **Cache-watchdog cleanup** — Removes the `cache-watchdog.sh` SessionStart hook (unnecessary after hybrid migration)
4. **Local commands** — Verifies `ralph-loop.md`, `cancel-ralph.md`, `ralph-loop-help.md`, `ralphtemplate.md`, `ralphtemplatetest.md` exist in `~/.claude/commands/` with absolute paths (not `${CLAUDE_PLUGIN_ROOT}`)
5. **Repo scripts** — Confirms `stop-hook.sh` and `setup-ralph-loop.sh` exist in the repo

## Properties

- **Idempotent** — Safe to run repeatedly. Skips checks that are already correct.
- **Non-destructive** — Only modifies `settings.json` and `~/.claude/commands/`. Never touches repo files, state files, or git history.
- **Requires jq** — Install with `sudo apt install jq` if missing.

## How it differs from other scripts

| Script                          | Purpose                                            |
| ------------------------------- | -------------------------------------------------- |
| `RESTORE/restore-hybrid.sh`     | Fix broken hybrid state (run anytime)              |
| `scripts/migrate-to-hybrid.sh`  | Initial migration from plugin to hybrid (run once) |
| `scripts/rollback-to-plugin.sh` | Revert to plugin approach entirely                 |

## Example output

```
Ralph Loop Hybrid Restore
  Repo: /path/to/ralphlooptemplates
  Settings: ~/.claude/settings.json

Check 1: Plugin entry in enabledPlugins
  WARN: ralph-loop entry found in enabledPlugins (value: true)
  FIX:  Removed ralph-loop from enabledPlugins

Check 2: Stop hook in settings.json
  OK:   Stop hook points to /path/to/ralphlooptemplates/scripts/stop-hook.sh

Check 3: Stop hook timeout
  OK:   Stop hook timeout: 60s

Check 4: Cache-watchdog SessionStart hook (should be absent)
  OK:   No cache-watchdog hook (correct for hybrid)

Check 5: Local commands
  OK:   ralph-loop.md present with absolute paths
  OK:   cancel-ralph.md present
  OK:   ralph-loop-help.md present
  OK:   ralphtemplate.md present
  OK:   ralphtemplatetest.md present

Check 6: Repo script integrity
  OK:   stop-hook.sh exists in /path/to/ralphlooptemplates/scripts/
  OK:   setup-ralph-loop.sh exists in /path/to/ralphlooptemplates/scripts/

================================
Result: 1 issue(s) found, 1 fixed

IMPORTANT: Start a NEW Claude Code session for changes to take effect.
  (Claude Code caches hook content at session start)
```
