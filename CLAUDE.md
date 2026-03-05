# Ralph Loop Templates - Project Instructions

## Plugin Cache Sync Rule

When modifying scripts in this repo, you MUST run `bash scripts/cache-sync.sh` to sync to the active plugin cache.
The script auto-discovers the active cache directory (skips orphaned versions).

Path mapping (local -> cache):

- `scripts/stop-hook.sh` -> `cache/hooks/stop-hook.sh` (NOTE: scripts/ -> hooks/ mapping!)
- `scripts/setup-ralph-loop.sh` -> `cache/scripts/setup-ralph-loop.sh`
- `commands/cancel-ralph.md` -> `cache/commands/cancel-ralph.md`

Cache version directory changes on plugin update — `cache-sync.sh` discovers it dynamically.

RULE: After ANY edit to scripts/ or commands/, run `bash scripts/cache-sync.sh` before testing.

## Transcript Format Rules

- XML/HTML tags (e.g. `<promise>`, `<tag>`) are STRIPPED by Claude Code's rendering pipeline before being written to transcript files
- Promise detection MUST use plain-text matching (`grep -Fx`), never XML tag parsing
- The transcript is JSONL format: one JSON object per line, `.message.content[].text` for text blocks

## Session ID Rules

- `PPID` is unreliable for session identification (setup and stop-hook run as separate processes with different PPIDs)
- `CLAUDE_SESSION_ID` env var: DOES NOT EXIST (verified 2026-03-05)
- `session_id` IS available in the Stop hook input JSON via stdin (discovered 2026-03-05)
- IMPLEMENTED: stop-hook.sh extracts `session_id` from hook JSON for O(1) state file lookup
- Setup generates uuidgen ID; stop hook renames file to hook session_id on first iteration
- Glob + ls -t fallback still exists for first iteration (before rename) and backward compat
- VERIFIED (session 8): `session_id` and `last_assistant_message` fields work via direct pipe invocation

## Stop Hook Input JSON Schema (from official docs)

Common fields (all hooks):
- `session_id` — current session identifier (USE THIS for multi-terminal)
- `transcript_path` — path to conversation JSONL
- `cwd` — current working directory
- `permission_mode` — default/plan/acceptEdits/dontAsk/bypassPermissions
- `hook_event_name` — "Stop" for stop hooks

Stop-specific fields:
- `stop_hook_active` — true when already continuing from a prior Stop hook (loop detection!)
- `last_assistant_message` — text of Claude's final response (no transcript parsing needed!)

Source: https://code.claude.com/docs/en/hooks

## Stop Hook Design Constraints

- Hook fires on EVERY session end (no matcher support — confirmed in official docs, silently ignored if set)
- Fast-exit guard at top of stop-hook.sh checks for state files BEFORE reading stdin
- State files: `.claude/ralph-loop.{SESSION_ID}.local.md` or `.claude/ralph-loop.local.md` (original plugin format, gitignored via `*.local.md`)
- Learnings files: `.claude/ralph-learnings.{SESSION_ID}.md` (temporary, deleted on consolidation)

## Plugin Cache Behavior (from official docs + GitHub issues)

- Cache key: plugin `name` + `version` (NOT gitCommitSha)
- Cache dir name = `version` field in installed_plugins.json
- Version change = new directory, old gets `.orphaned_at`
- `/plugin update` updates marketplace git repo but does NOT invalidate cache (known bug)
- `DISABLE_AUTOUPDATER=1` disables Claude Code auto-updates, not plugin cache
- `.orphaned_at` is undocumented; Claude Code loads only from registered `installPath`
- Protection: use local plugin pointing to repo, or SessionStart watchdog hook

## Passphrase System

- Setup auto-generates `WORD NNNN WORD NNNN WORD NNNN` format (materials x animals x science domains)
- User-provided promises get prefixed: `PASSPHRASE::USER_PROMISE`
- ~8 trillion combinations, zero false-positive risk in practice
- Detection still uses `grep -Fx` — the passphrase itself prevents false positives

## Known Risks (as of 2026-03-05, updated session 8)

33 decisions across 8 sessions (see LEARNINGS.md for full history). Active items only:

- ACTIVE: Plugin cache overwrite — watchdog detects mismatches, cache-sync.sh restores. Consider local plugin long-term.
- ACTIVE: Original plugin's stop hook may differ from ours — we patch the cached copy but Claude Code may run its own version. Promise detection in the original plugin is unverified.
- KNOWN-BEHAVIOR: cache-sync.sh mid-session does NOT affect running hooks — Claude Code loads hooks at session start.
- KNOWN-BEHAVIOR: nullglob only applies to glob patterns (`*`, `?`, `[...]`). Literal paths bypass it. Use char-class trick: `ralph-loop.loca[l].md`.
- NOTED: Bash RANDOM 15-bit modulo bias (0.006%) — not security-relevant.
- NOTED: stop_hook_active intentionally NOT used as exit guard.
- Orphaned cache cleanup: `find ~/.claude/plugins/cache -name ".orphaned_at" -exec dirname {} \; | xargs rm -rf`

## Stop Hook State File Rename Behavior

On first iteration, the stop hook renames the state file from the setup-generated uuidgen ID
to the hook-provided session_id. This enables O(1) direct lookup on subsequent iterations.
The learnings file is also renamed to match. This is a one-time migration per session.

NOTE: Frontmatter `session_id` is now updated during rename (via sed in stop-hook.sh).
Both filename and frontmatter use the hook session_id after first iteration.

## Original Plugin vs Our Patches (CRITICAL - analyzed session 8)

The original plugin's stop-hook.sh (marketplace source) differs from our version in key ways:

| Feature | Original Plugin | Our Version |
|---------|----------------|-------------|
| Promise detection | `<promise>TEXT</promise>` XML tags via Perl regex | `grep -Fx` plain text on its own line |
| Session ID | `CLAUDE_SESSION_ID` or `PPID` | Hook JSON `session_id` with uuidgen fallback |
| State file lookup | Direct by PPID | O(1) by hook session_id + dual-glob fallback |
| Output extraction | Transcript parsing only | `last_assistant_message` + transcript fallback |
| Frontmatter awk | Skips ALL `---` lines | Only skips first two `---` (frontmatter) |
| Rename on first iter | None | flock-protected rename + frontmatter update |

IMPORTANT: The running hook depends on which version is in the cache at session start.
Our `cache-sync.sh` copies our version, but plugin updates will overwrite with the original.
The promise format mismatch (`<promise>` tags vs plain text) is the most impactful difference.

## Ralph Loop Best Practices

- ALWAYS set `--completion-promise` to avoid infinite loops with no exit signal
- ALWAYS set `--max-iterations` as a safety bound (10-30 typical)
- Running with `completion_promise: null` means the loop runs until max_iterations — no early exit possible
- Hook changes require a NEW session to take effect (cache-sync updates files on disk but running hooks are cached)

## Cache Sync Helper

`scripts/cache-sync.sh` syncs local repo files to the active plugin cache directory.
Dynamically discovers active cache dir (skips orphaned). Run manually or via watchdog recommendation.
Handles the `scripts/` -> `hooks/` path mapping for stop-hook.sh automatically.
