# Ralph Loop Templates - Project Instructions

## Hybrid Architecture (session 12 — replaces plugin approach)

MIGRATED (session 12): Ralph loop now runs as local commands + settings.json Stop hook.
The marketplace plugin `ralph-loop@claude-plugins-official` entry is REMOVED from enabledPlugins (not just disabled — prevents GitHub #28554 spontaneous re-enable).

ARCHITECTURE:
- Stop hook: `~/.claude/settings.json` -> `bash $REPO/scripts/stop-hook.sh`
- Commands: `~/.claude/commands/ralph-loop.md`, `cancel-ralph.md`, `ralph-loop-help.md`, `ralphtemplate.md`, `ralphtemplatetest.md`
- Source of truth: This repo (`$REPO/`)

RULE: After ANY edit to scripts/ or commands/, start a NEW session (hooks cached at session start).
No cache-sync needed — settings.json hook reads directly from repo.

ROLLBACK: `bash scripts/rollback-to-plugin.sh` (re-enables plugin, removes Stop hook, restores watchdog).
BACKUP: `~/.claude/settings.json.pre-migration.bak`

WHY: Settings.json Stop hooks are MORE reliable than plugin hooks.json (GitHub #10875 — plugin
hooks.json output not captured). `/plugin update` no longer breaks ralph-loop.

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

## Plugin Cache Behavior (HISTORICAL — no longer primary concern after hybrid migration)

- Cache key: plugin `name` + `version` (NOT gitCommitSha)
- Cache dir name = `version` field in installed_plugins.json
- Version change = new directory, old gets `.orphaned_at`
- `/plugin update` updates marketplace git repo but does NOT invalidate cache (known bug)
- `DISABLE_AUTOUPDATER=1` disables Claude Code auto-updates, not plugin cache
- `.orphaned_at` is undocumented; Claude Code loads from `marketplaces/` git checkout (NOT `installPath`)
- NOTE: After hybrid migration, cache-sync.sh is only needed for rollback scenarios.

## Passphrase System (updated session 15)

- Passphrases generated via Bash tool: `echo "RALPH-$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"`
- Format: `RALPH-` prefix + 48 hex chars from /dev/urandom (TRUE OS randomness, zero LLM bias)
- PREVIOUS (sessions 9-14): `WORD NNNN WORD NNNN WORD NNNN` format — DEPRECATED due to LLM token bias (MARBLE, CONDOR, LATTICE repeated)
- User-provided promises get prefixed: `PASSPHRASE::USER_PROMISE`
- Detection uses `grep -Fx` — RALPH- prefix prevents false matches against hex in code output

## Known Risks (as of 2026-03-07, updated session 16)

60 decisions across 16 sessions (see LEARNINGS.md for full history). Active items only:

- RESOLVED (session 12): `/plugin update` overwrite problem — hybrid migration eliminates this entirely. Hook reads from repo, not marketplace.
- KNOWN-BEHAVIOR: Hook changes require a NEW session. Claude Code caches hook SCRIPT CONTENT at session start. Editing hook files on disk has NO effect on the running session's hooks.
- KNOWN-BEHAVIOR: nullglob only applies to glob patterns (`*`, `?`, `[...]`). Literal paths bypass it. Use char-class trick: `ralph-loop.loca[l].md`.
- KNOWN-BUG (GitHub #9996): Disabled plugins may still show tools in slash command list. Cosmetic only — local commands take priority.
- RESOLVED (session 14): GitHub #28554 double-fire risk eliminated — plugin entry removed entirely from enabledPlugins (not just disabled). No entry = nothing to spontaneously re-enable.
- RESOLVED (session 15): LLM passphrase bias — replaced word arrays with /dev/urandom hex hash.
- RESOLVED (session 15): Prompt sometimes not generated — added CRITICAL always-generate guard + unambiguous template delimiters.
- NOTED: Bash RANDOM 15-bit modulo bias (0.006%) — not security-relevant.
- NOTED: stop_hook_active intentionally NOT used as exit guard.
- NOTED: Live hook JSON fields (session_id, last_assistant_message) still not verified via actual hook fire event. All code has fallbacks.
- NEW (session 16): Post-reboot verification needed — tmpfs /tmp fstab entry added but not yet active. Must confirm Xorg, Chrome, Docker, Claude Code, QEMU work after reboot.
- NOTED (session 16): `set -e` incompatible with `systemctl is-active` — returns exit code 3 for inactive units. Use `set -uo pipefail` (no `-e`) in scripts that check service status.

## Stop Hook State File Rename Behavior

On first iteration, the stop hook renames the state file from the setup-generated uuidgen ID
to the hook-provided session_id. This enables O(1) direct lookup on subsequent iterations.
The learnings file is also renamed to match. This is a one-time migration per session.

NOTE: Frontmatter `session_id` is now updated during rename (via sed in stop-hook.sh).
Both filename and frontmatter use the hook session_id after first iteration.

## Original Plugin vs Our Patches (HISTORICAL — plugin entry removed from enabledPlugins)

The original plugin's stop-hook.sh differs from our version in key ways:

| Feature | Original Plugin | Our Version |
|---------|----------------|-------------|
| Promise detection | `<promise>TEXT</promise>` XML tags via Perl regex | `grep -Fx` plain text on its own line |
| Session ID | `CLAUDE_SESSION_ID` or `PPID` | Hook JSON `session_id` with uuidgen fallback |
| State file lookup | Direct by PPID | O(1) by hook session_id + dual-glob fallback |
| Output extraction | Transcript parsing only | `last_assistant_message` + transcript fallback |
| Frontmatter awk | Skips ALL `---` lines | Only skips first two `---` (frontmatter) |
| Rename on first iter | None | flock-protected rename + frontmatter update |

NOTE (session 14): After hybrid migration, our version runs from settings.json Stop hook pointing
directly to the repo. The plugin entry is removed from enabledPlugins (not just disabled).
Marketplace directory and installed_plugins.json entry persist (managed by Claude Code, harmless).

## Ralph Loop Best Practices

- ALWAYS set `--completion-promise` to avoid infinite loops with no exit signal
- ALWAYS set `--max-iterations` as a safety bound (10-30 typical)
- Running with `completion_promise: null` means the loop runs until max_iterations — no early exit possible
- Hook changes require a NEW session to take effect (edits to files on disk have no effect — hooks are cached at session start)

## Ralphtemplate System (sessions 9-15)

TWO variants available:
- `/ralphtemplate` — 4 roles: Builder, Challenger, Proxy, Researcher
- `/ralphtemplatetest` — 5 roles: adds Tester (test-first, sandbox-based)

The Researcher activates when Builder or Proxy drops below 75% certainty. It delegates to subagents,
web search, and MCP servers (context7, brave, fetch, github), reports structured findings with sources
and confidence, then the delegating role incorporates findings and proceeds.

The Tester (Role 5, `/ralphtemplatetest` only) creates tests in `/tmp/ralph-test-sandbox-SESSION_ID/`
BEFORE the Builder writes implementation code. Tests verify expected BEHAVIOR, not implementation details.
Post-completion: full test suite re-run; sandbox cleaned up. Toggle off with TESTINGOFF in arguments.

Auto-generates a unique passphrase via Bash tool (`/dev/urandom` hex hash with RALPH- prefix).
Both commands include a CRITICAL always-generate guard — prompt is ALWAYS output regardless of argument content.
Template boundaries use `=== TEMPLATE START/END ===` markers (not `---`) to avoid YAML frontmatter ambiguity.

## Cache Sync (LEGACY — only needed for rollback to plugin approach)

`scripts/cache-sync.sh` syncs repo files to ALL THREE plugin directories (marketplace, cache, local).
After hybrid migration (session 12), this is only needed if rolling back to the plugin approach.
The rollback script (`scripts/rollback-to-plugin.sh`) calls cache-sync.sh automatically.

## Documentation Diagrams (session 13)

HTML diagrams in `docs/` visualize system architecture. Screenshots in `docs/screenshot-*.png`.
When architecture changes (roles, hook source, flow), update diagrams AND retake screenshots.

Files:
- `docs/diagram.html` — v2 system architecture (5 roles, hybrid hooks, all phases including sandbox)
- `docs/ralphtemplatetest-diagram.html` — /ralphtemplatetest 5-role system, TESTINGOFF toggle, sandbox flow
- `docs/before-after-diagram.html` — Before/after comparison (original plugin vs patched hybrid)
- `docs/system-improvements-diagram.html` — All fixes, stats, roles, test suites

Screenshots: `google-chrome --headless --disable-gpu --screenshot="output.png" --window-size=1920,2200 "file://input.html"`

## Migration & Recovery Scripts

- `scripts/migrate-to-hybrid.sh` — Migrate from plugin to hybrid (local commands + settings.json hooks)
- `scripts/rollback-to-plugin.sh` — Rollback hybrid to plugin approach
- `scripts/test-migration.sh` — 13 tests for migration and rollback (uses mock HOME)
- `RESTORE/restore-hybrid.sh` — Idempotent health check + fix for hybrid state (run anytime)
- `RESTORE/README.md` — Symptom-to-cause table and usage guide
- `scripts/reduce-io-pressure.sh` — I/O pressure optimization (journald caps, dedicated workspace, tmpfs fstab). Supports `--diagnose`, `--apply`, `--apply-journald`, `--apply-workspace`, `--apply-tmpfs`, `--rollback`, `--help`.

RESTORE/restore-hybrid.sh checks and fixes 6 categories:
1. Plugin entry in enabledPlugins (removes if present)
2. Stop hook existence and path (adds/corrects)
3. Stop hook timeout (ensures >= 60s)
4. Cache-watchdog hook (removes if present — unnecessary after migration)
5. Local commands (restores with absolute paths if missing or using CLAUDE_PLUGIN_ROOT)
6. Repo script integrity (warns if stop-hook.sh or setup-ralph-loop.sh missing)

Use `--dry-run` for health checks without changes. Use `--quiet` for minimal output.
