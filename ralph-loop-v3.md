# Ralph Loop v3 — Local Plugin Setup Guide

This document contains everything needed to run Ralph Loop v3 as a **local plugin** (local commands + settings.json Stop hook). This replaces the original marketplace plugin and fixes all known issues.

## What Changed in v3

| Issue | Original Plugin | v3 Fix |
|-------|----------------|--------|
| Hook output silently dropped | Plugin hooks.json ([GH #10875](https://github.com/anthropics/claude-code/issues/10875)) | settings.json Stop hook — output fully captured |
| `/plugin update` overwrites customizations | Plugin cache replaced on update | Reads directly from repo — no cache layer |
| PPID differs between setup and hook | Used PPID for session ID | Extracts `session_id` from hook JSON (O(1) lookup) |
| Plugins re-enable randomly | [GH #28554](https://github.com/anthropics/claude-code/issues/28554) | Plugin entry REMOVED entirely from enabledPlugins |
| XML tags stripped by renderer | `<promise>` tags parsed via Perl regex | Plain-text `grep -Fx` detection |
| LLM passphrase bias | `WORD NNNN WORD NNNN` — LLM picks same words | `/dev/urandom` hex hash — true OS randomness |
| Multi-terminal conflicts | Single state file for all sessions | Session-scoped state files with flock-protected rename |
| Frontmatter corruption | `awk` skips ALL `---` lines | Only skips first two `---` (frontmatter delimiters) |

## Architecture

```
settings.json Stop hook
        |
        v
scripts/stop-hook.sh  (reads from repo directly, no cache)
        |
        v
.claude/ralph-loop.{SESSION_ID}.local.md  (session-scoped state)
```

The Stop hook fires on every session end. The script checks for state files first (fast exit if no loop active), then reads the hook JSON from stdin, checks for completion, and either exits or feeds the prompt back.

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` installed (`sudo apt install jq` or `brew install jq`)
- `xxd` available (usually pre-installed on Linux/macOS)

### Step 1: Clone the repo

```bash
git clone https://github.com/kt2saint-sec/ralphlooptemplates.git
cd ralphlooptemplates
REPO="$(pwd)"
```

### Step 2: Copy commands to Claude Code

```bash
mkdir -p ~/.claude/commands

# Core loop commands (update paths to your repo location)
for cmd in ralph-loop.md cancel-ralph.md ralph-loop-safe.md; do
  cp "commands/$cmd" ~/.claude/commands/
done

# Template generators
cp commands/ralphtemplate.md ~/.claude/commands/
cp commands/ralphtemplatetest.md ~/.claude/commands/

# Boris method commands
for cmd in boris-challenge.md grill-me.md prove-it.md; do
  cp "commands/$cmd" ~/.claude/commands/
done

# Utility commands
for cmd in knowing-everything.md scrap-and-redo.md help.md; do
  cp "commands/$cmd" ~/.claude/commands/
done
```

### Step 3: Fix the ralph-loop.md path

The `ralph-loop.md` command needs an absolute path to the setup script:

```bash
# Replace the plugin root variable with your actual repo path
sed -i "s|\${CLAUDE_PLUGIN_ROOT}|$REPO|g" ~/.claude/commands/ralph-loop.md
```

After this edit, `~/.claude/commands/ralph-loop.md` should contain:
```
allowed-tools: ["Bash(/path/to/ralphlooptemplates/scripts/setup-ralph-loop.sh:*)"]
```

### Step 4: Add the Stop hook to settings.json

This is the critical piece that makes the loop work. Add a Stop hook that points to the repo's `stop-hook.sh`:

```bash
# Backup first
cp ~/.claude/settings.json ~/.claude/settings.json.backup

# Add Stop hook (requires jq)
TEMP=$(mktemp)
jq --arg cmd "bash $REPO/scripts/stop-hook.sh" \
  '.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd, "timeout": 60}]}]' \
  ~/.claude/settings.json > "$TEMP"
mv "$TEMP" ~/.claude/settings.json
```

Or manually edit `~/.claude/settings.json` and add:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /path/to/ralphlooptemplates/scripts/stop-hook.sh",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

### Step 5: Remove the marketplace plugin (if installed)

If you previously installed `ralph-loop` from the Claude Code plugin marketplace, remove it from `enabledPlugins` to prevent double-firing:

```bash
TEMP=$(mktemp)
jq 'del(.enabledPlugins["ralph-loop@claude-plugins-official"])' \
  ~/.claude/settings.json > "$TEMP"
mv "$TEMP" ~/.claude/settings.json
```

### Step 6: Start a new session

**Claude Code caches hook script content at session start.** After any changes to scripts or commands, you must start a new Claude Code session for changes to take effect.

```bash
# Close current session, then:
claude
```

### Step 7: Verify

```bash
# In the new Claude Code session:
/ralph-loop "Say hello" --max-iterations 2 --completion-promise "HELLO DONE"
```

You should see the loop activate with a generated passphrase.

## Automated Installation

If you prefer a one-command setup, use the migration script:

```bash
bash scripts/migrate-to-hybrid.sh
```

This does steps 2-5 automatically.

## How the Stop Hook Works

The stop hook (`scripts/stop-hook.sh`) is 326 lines of bash that handles:

1. **Fast exit guard** — Checks for state files using nullglob before reading stdin. If no Ralph loop is active, exits immediately with zero overhead.

2. **Hook JSON parsing** — Reads stdin to extract `session_id`, `last_assistant_message`, and `transcript_path` via jq.

3. **Session-scoped state lookup** — Primary: direct file lookup by hook `session_id` (O(1)). Fallback: glob + `ls -t` for first iteration when setup used uuidgen.

4. **First-iteration rename** — On first iteration, renames state file from setup-generated ID to hook session ID. Uses `flock` to prevent race conditions in multi-terminal scenarios.

5. **Completion detection** — Checks if the completion promise appears as an exact standalone line in the output (`grep -Fx`). No regex, no XML parsing.

6. **Iteration continuation** — Extracts the prompt from the state file (skipping frontmatter), increments iteration counter, prepends learnings preamble on iterations 2+, outputs JSON to block the stop event and feed the prompt back.

7. **Consolidation** — When loop completes (promise met or max iterations), injects a final "consolidate learnings" prompt if learnings were enabled.

## How the Passphrase System Works

Every Ralph loop session auto-generates a unique passphrase:

```bash
echo "RALPH-$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"
# Output: RALPH-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e8f0a1b3
```

- **RALPH-** prefix prevents false matches against hex strings in code output
- **48 hex chars** from `/dev/urandom` = 2^192 combinations, zero LLM bias
- If user provides `--completion-promise "DONE"`, the actual signal becomes `RALPH-abc123...::DONE`
- Detection uses `grep -Fx` (exact full-line match) — no regex, no partial matches

**Why not LLM-generated words?** v2 used `WORD NNNN WORD NNNN WORD NNNN` format where Claude picked the words. Testing revealed consistent token bias: MARBLE, CONDOR, and LATTICE appeared disproportionately. OS randomness eliminates this entirely.

## State File Format

State files are markdown with YAML frontmatter, stored at `.claude/ralph-loop.{SESSION_ID}.local.md`:

```yaml
---
active: true
iteration: 3
max_iterations: 20
completion_promise: "RALPH-a3f7b2c9...::ALL TESTS PASSING"
learnings_enabled: true
session_id: "abc12345-6789"
started_at: "2026-03-09T12:00:00Z"
---

Your prompt text goes here...
```

The prompt text after frontmatter is fed back to Claude on each iteration.

## Learnings System

When `learnings_enabled: true` (default), on iterations 2+:
- The stop hook prepends a brief retrospective preamble asking Claude to append 2-3 lines to a learnings file
- Learnings accumulate at `.claude/ralph-learnings.{SESSION_ID}.md`
- On completion, a consolidation phase extracts durable patterns into permanent project docs (LEARNINGS.md, MEMORY.md)
- Temporary learnings file is deleted after consolidation

## Recovery

If something breaks, use the restore script:

```bash
# Health check (read-only)
bash RESTORE/restore-hybrid.sh --dry-run

# Auto-fix all issues
bash RESTORE/restore-hybrid.sh
```

This checks and fixes 6 categories:
1. Plugin entry in enabledPlugins (removes if present)
2. Stop hook existence and path (adds/corrects)
3. Stop hook timeout (ensures >= 60s)
4. Cache-watchdog hook (removes if present — unnecessary after migration)
5. Local commands (restores with absolute paths if missing)
6. Repo script integrity (warns if stop-hook.sh missing)

## Rollback to Plugin

If you want to revert to the marketplace plugin approach:

```bash
bash scripts/rollback-to-plugin.sh
```

## Important: Hook Caching

Claude Code caches hook script **content** at session start. This means:

- Editing `stop-hook.sh` or `setup-ralph-loop.sh` mid-session has **no effect**
- After ANY edit to scripts/ or commands/, start a **new** Claude Code session
- The settings.json path is resolved at session start, but the script content is cached

## Commands Reference

| Command | Description |
|---------|-------------|
| `/ralph-loop` | Start a self-iterating development loop |
| `/ralph-loop-safe` | Same as above with git safety checks (must be on feature branch) |
| `/cancel-ralph` | Cancel active loop (session-scoped) |
| `/ralphtemplate` | Generate 4-role orchestrator prompt (Builder, Challenger, Proxy, Researcher) |
| `/ralphtemplatetest` | Generate 5-role prompt (adds Tester for test-first workflow) |
| `/boris-challenge` | Challenge requirements before coding |
| `/grill-me` | Staff engineer code review |
| `/prove-it` | Demand evidence that changes work |
| `/knowing-everything` | Retrospective and knowledge capture |
| `/scrap-and-redo` | Rebuild with accumulated context |

## Test Suite

95 tests across 8 suites, all passing:

```bash
# Run all tests
for f in scripts/test-*.sh; do bash "$f"; done
```

| Suite | Tests | Coverage |
|-------|-------|----------|
| test-passphrase-detection.sh | 18 | Passphrase format, false positive rejection |
| test-multi-terminal.sh | 4 | ls -t determinism, session ID availability |
| test-rename-migration.sh | 13 | State file rename, frontmatter update, flock |
| test-cache-watchdog.sh | 7 | Watchdog script invocation |
| test-consolidation.sh | 10 | Consolidation prompt, learnings cleanup |
| test-lifecycle.sh | 18 | Full lifecycle: setup, rename, iterate, promise, consolidate, cancel |
| test-hook-input.sh | 12 | Empty/malformed/valid/binary/large hook JSON |
| test-migration.sh | 13 | Hybrid migration, rollback, idempotency |
