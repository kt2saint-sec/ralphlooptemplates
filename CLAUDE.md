# Ralph Loop Templates - Project Instructions

## Hybrid Architecture (session 12 — replaces plugin approach)

MIGRATED (session 12): Ralph loop now runs as local commands + settings.json Stop hook.
The marketplace plugin `ralph-loop@claude-plugins-official` entry is REMOVED from enabledPlugins (not just disabled — prevents GitHub #28554 spontaneous re-enable).

ARCHITECTURE:

- Stop hook: `~/.claude/settings.json` AND `~/.claude-planB/settings.json` -> `bash $REPO/scripts/stop-hook.sh`
- SessionStart hook: Both settings.json files -> `/home/rebelsts/.config/claude-code/init.sh`
- PostToolUse hooks: Both settings.json files -> `~/.claude/hooks/post-tool-lint.sh`, `post-tool-git-warn.sh`
- Commands: `~/.claude/commands/` (symlinked from `~/.claude-planB/commands/`)
- Source of truth: This repo (`$REPO/`)
- CRITICAL: `claudeB` uses `~/.claude-planB/settings.json`. Plain `claude` uses `~/.claude/settings.json`. BOTH must have hooks.

RULE: After ANY edit to scripts/ or commands/, start a NEW session (hooks cached at session start).
No cache-sync needed — settings.json hook reads directly from repo.

ROLLBACK: `bash scripts/rollback-to-plugin.sh` (re-enables plugin, removes Stop hook, restores watchdog).
ROLLBACK (session 24): `bash ~/.claude-planB/BACKUP_RESTORE/rollback-session24.sh` (reverts planB hooks + init.sh + ghost hook disabling).
BACKUP: `~/.claude/settings.json.pre-migration.bak`, `~/.claude-planB/BACKUP_RESTORE/*.pre-session24.bak`

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

## Passphrase System (updated session 18)

- Passphrases generated via Bash tool: `echo "RALPH-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')"`
- Format: `RALPH-` prefix + 8-char epoch hex + `-` + 40 hex chars from /dev/urandom
- v3 (session 18): Added epoch timestamp for structural temporal uniqueness + debuggability. Decode: `printf '%d\n' 0xEPOCH`
- v2 (session 15): `RALPH-` + 48 hex chars — no temporal binding, probabilistic-only uniqueness
- v1 (sessions 9-14): `WORD NNNN WORD NNNN WORD NNNN` — DEPRECATED due to LLM token bias
- User-provided promises get prefixed: `PASSPHRASE::USER_PROMISE`
- Detection uses `grep -Fx` — RALPH- prefix prevents false matches against hex in code output

## Known Risks (as of 2026-03-10, updated session 24)

85+ decisions across 24 sessions (see LEARNINGS.md for full history). Active items only:

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
- NEW (session 17): v2 template files (4 total) must stay in sync between `commands/` and `~/.claude/commands/`.
- NEW (session 17): RESTORE/restore-hybrid.sh does NOT restore v2 command files. Manual sync required after restore.
- NEW (session 17): TESTINGOFF + EVALUATOR interaction — EVALUATOR tier descriptions reference Tester counts. Claude must omit these when TESTINGOFF is active. Relies on instruction compliance, not structural enforcement.
- NEW (session 19): v1/v2 template drift — 4 template files share core roles. Bug fix in v1 must be manually applied to v2. No automated drift detection.
- NEW (session 19): README.md stats drift — decision/test/session counts were stale for 3 sessions. Update README in same commit as decision changes.
- NEW (session 19): LEARNINGS.md decision 65 appears twice (sessions 17 and 18). Second instance should be renumbered or clarified.
- FIXED (session 17): test-passphrase-detection.sh format regex was stale (still validated WORD NNNN format from session 9-14, not RALPH-hex from session 15). Now 18/18 pass.
- NEW (session 18): v3 epoch-hex passphrase format. Regex updated from `^RALPH-[0-9a-f]{48}$` to `^RALPH-[0-9a-f]{8}-[0-9a-f]{40}$`. 25 new tests in test-passphrase-v2.sh.
- FIXED (session 20+23+24): SessionStart hook error — THREE root causes found across 5 sessions:
  (a) Session 20: background process held stdout FD open for 5s. Fixed with `>/dev/null 2>&1 & disown`.
  (b) Session 23: Confirmed `"matcher": "startup"` IS valid for SessionStart (matches: startup, resume, clear, compact).
  (c) Session 24: Ghost plugin hooks.json in `~/.claude-planB/plugins/` (10 files disabled including semgrep — CLI not installed).
  Plus: init.sh now outputs `{"suppressOutput": true}` JSON (GitHub #21643 — non-JSON stdout = UI error).
- RULE: Hook scripts MUST NOT spawn background processes that inherit stdout/stderr FDs. Use `>/dev/null 2>&1 & disown` for any background work in hooks.
- RULE: SessionStart hooks DO support matchers. Valid values: `startup`, `resume`, `clear`, `compact`. Stop hooks do NOT support matchers.
- RULE: SessionStart hooks MUST output valid JSON to stdout. Empty or non-JSON output triggers the Claude Code UI error display (GitHub #21643, #12671).
- FIXED (session 24): init.sh `export` statements are dead code — now uses CLAUDE_ENV_FILE. Hook creates the file (check parent dir writable, not file itself).
- FIXED (session 24): Double SSH password prompts — removed manual ssh-agent startup from .bashrc (was competing with gcr-ssh-agent systemd service).
- RESOLVED (session 23): /doctor dual install warning is cosmetic — npm already uninstalled, cache metadata persists (GitHub #12414).
- FIXED (session 24): Config directory mismatch. `claudeB` alias sets `CLAUDE_CONFIG_DIR=~/.claude-planB`.
  Hooks now exist in BOTH `~/.claude/settings.json` (plain `claude`) AND `~/.claude-planB/settings.json` (`claudeB`).
  Sessions 12-22 edits were to wrong file. Session 24 ported all hooks to planB.
- FIXED (session 24): Ghost plugin hooks in `~/.claude-planB/plugins/` — 10 hooks.json files renamed to .disabled.
  Includes: learning-output-style, explanatory-output-style, superpowers, ralph-loop (5), semgrep (2).
  Semgrep disabled because CLI not installed — hooks calling `semgrep mcp` failed with non-JSON error output.
- RULE: When CLAUDE_CONFIG_DIR is set, ALL settings (hooks, plugins, permissions) come from that directory's settings.json.
  Edits to ~/.claude/settings.json have NO effect when running as `claudeB`.
- RULE: ALWAYS check `echo $CLAUDE_CONFIG_DIR` BEFORE editing any settings.json. This determines which file is active.
- RULE: Plugin hooks.json fires even if the plugin's CLI tool isn't installed. The hook runs, the command fails, non-JSON output triggers UI error.
- RULE: CLAUDE_ENV_FILE — the hook script CREATES this file. Check `[[ -d "$(dirname "$CLAUDE_ENV_FILE")" ]]`, not `[[ -w "$CLAUDE_ENV_FILE" ]]`.
- FIXED (session 21): PostToolUse hooks used nonexistent `$CLAUDE_FILE_PATH` env var. Claude Code passes hook data via stdin JSON, not env vars. Rewrote as external scripts using `jq`. Prettier reformatted 5 HTML files via empty path — reverted.
- RULE: Claude Code hook data comes via stdin JSON. Use `INPUT=$(cat); jq -r '.tool_input.file_path'` — NOT `$CLAUDE_FILE_PATH` or `$CLAUDE_BASH_COMMAND` (these env vars do not exist).
- FIXED (session 22): Ghost hooks existed in THREE directories (marketplace, cache, local). Session 21 only disabled marketplace. Cache ralph-loop, local ralph-loop, and cache superpowers (Windows .cmd on Linux) were still firing.
- FIXED (session 22): v2 command file rename reverted. `rlphtempnew.md` → `ralphtemplate-v2.md`, `rlphtemptestnew.md` → `ralphtemplatetest-v2.md`.
- NEW (session 22): restore-hybrid.sh Check 7 automates ghost hooks.json disabling across all plugin directories.
- RULE: After `/plugin update`, run `bash RESTORE/restore-hybrid.sh` to re-disable ghost hooks (git pull restores hooks.json files).

## Stop Hook State File Rename Behavior

On first iteration, the stop hook renames the state file from the setup-generated uuidgen ID
to the hook-provided session_id. This enables O(1) direct lookup on subsequent iterations.
The learnings file is also renamed to match. This is a one-time migration per session.

NOTE: Frontmatter `session_id` is now updated during rename (via sed in stop-hook.sh).
Both filename and frontmatter use the hook session_id after first iteration.

## Original Plugin vs Our Patches (HISTORICAL — plugin entry removed from enabledPlugins)

The original plugin's stop-hook.sh differs from our version in key ways:

| Feature              | Original Plugin                                   | Our Version                                    |
| -------------------- | ------------------------------------------------- | ---------------------------------------------- |
| Promise detection    | `<promise>TEXT</promise>` XML tags via Perl regex | `grep -Fx` plain text on its own line          |
| Session ID           | `CLAUDE_SESSION_ID` or `PPID`                     | Hook JSON `session_id` with uuidgen fallback   |
| State file lookup    | Direct by PPID                                    | O(1) by hook session_id + dual-glob fallback   |
| Output extraction    | Transcript parsing only                           | `last_assistant_message` + transcript fallback |
| Frontmatter awk      | Skips ALL `---` lines                             | Only skips first two `---` (frontmatter)       |
| Rename on first iter | None                                              | flock-protected rename + frontmatter update    |

NOTE (session 14): After hybrid migration, our version runs from settings.json Stop hook pointing
directly to the repo. The plugin entry is removed from enabledPlugins (not just disabled).
Marketplace directory and installed_plugins.json entry persist (managed by Claude Code, harmless).

## Ralph Loop Best Practices

- ALWAYS set `--completion-promise` to avoid infinite loops with no exit signal
- ALWAYS set `--max-iterations` as a safety bound (10-30 typical)
- Running with `completion_promise: null` means the loop runs until max_iterations — no early exit possible
- Hook changes require a NEW session to take effect (edits to files on disk have no effect — hooks are cached at session start)

## Ralphtemplate System (sessions 9-17)

FOUR variants available:

- `/ralphtemplate` — 4 roles: Builder, Challenger, Proxy, Researcher
- `/ralphtemplatetest` — 5 roles: adds Tester (test-first, sandbox-based)
- `/ralphtemplate-v2` — 5 roles: adds EVALUATOR (complexity tiers), dynamic iterations, DOCUMENTOR
- `/ralphtemplatetest-v2` — 6 roles: EVALUATOR + Tester, dynamic iterations, DOCUMENTOR, test preservation

The Researcher activates when Builder or Proxy drops below 75% certainty. It delegates to subagents,
web search, and MCP servers (context7, brave, fetch, github), reports structured findings with sources
and confidence, then the delegating role incorporates findings and proceeds.

The Tester (Role 5, `/ralphtemplatetest` and `/ralphtemplatetest-v2`) creates tests in `/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-SESSION_ID/`
BEFORE the Builder writes implementation code. Tests verify expected BEHAVIOR, not implementation details.
Post-completion: full test suite re-run; sandbox cleaned up. Toggle off with TESTINGOFF in arguments.

v2 enhancements (session 17):

- EVALUATOR (Role 0): Assesses task complexity, assigns qualitative tier (LIGHT/STANDARD/THOROUGH/RIGOROUS/MAXIMAL).
  Uses linguistic triggers (not numeric tracking) — avoids the token-bias failure from decision 54.
  Tier governs Challenger objection count, Tester test count, and suggested iteration budget (5-30).
- Dynamic iterations: Replaces "Maximum 10 iterations" with EVALUATOR-suggested budget. Hard limit is `--max-iterations`.
- DOCUMENTOR: Post-generation step writes raw prompt to `.txt` + haiku-generated summary to `-summary.txt`.
  Raw file enables `cat ralph-prompt-*.txt | /ralph-loop` piping. Summary includes metadata and suggested command.
- Test preservation (`/ralphtemplatetest-v2` only): Copies sandbox tests to `TESTS/ralph-TIMESTAMP/before/` and
  `TESTS/ralph-TIMESTAMP/after/` with `CHANGES.txt` documenting what changed and why. Stripped by TESTINGOFF.

Rollback: Delete the 4 v2 files (2 in `commands/` + 2 in `~/.claude/commands/`). Zero risk to originals.

Auto-generates a unique passphrase via Bash tool (`/dev/urandom` hex hash with RALPH- prefix).
All commands include a CRITICAL always-generate guard — prompt is ALWAYS output regardless of argument content.
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
- `docs/v3-architecture-diagram.html` — v3 architecture overview with passphrase evolution

Screenshots: `google-chrome --headless --disable-gpu --screenshot="output.png" --window-size=1920,2200 "file://input.html"`

## Migration & Recovery Scripts

- `scripts/migrate-to-hybrid.sh` — Migrate from plugin to hybrid (local commands + settings.json hooks)
- `scripts/rollback-to-plugin.sh` — Rollback hybrid to plugin approach
- `scripts/test-migration.sh` — 13 tests for migration and rollback (uses mock HOME)
- `RESTORE/restore-hybrid.sh` — Idempotent health check + fix for hybrid state (run anytime)
- `RESTORE/README.md` — Symptom-to-cause table and usage guide
- `scripts/reduce-io-pressure.sh` — I/O pressure optimization (journald caps, dedicated workspace, tmpfs fstab). Supports `--diagnose`, `--apply`, `--apply-journald`, `--apply-workspace`, `--apply-tmpfs`, `--rollback`, `--help`.

RESTORE/restore-hybrid.sh checks and fixes 7 categories:

1. Plugin entry in enabledPlugins (removes if present)
2. Stop hook existence and path (adds/corrects)
3. Stop hook timeout (ensures >= 60s)
4. Cache-watchdog hook (removes if present — unnecessary after migration)
5. Local commands (restores with absolute paths if missing or using CLAUDE_PLUGIN_ROOT)
6. Repo script integrity (warns if stop-hook.sh or setup-ralph-loop.sh missing)
7. Ghost plugin hooks.json (disables in marketplace, cache, and local directories)

NOTE (session 24): restore-hybrid.sh currently only checks `~/.claude/plugins/`. It does NOT check
`~/.claude-planB/plugins/`. After `/plugin update`, ghost hooks must be manually disabled in planB too.
TODO: Update restore-hybrid.sh to detect CLAUDE_CONFIG_DIR and check the active plugins directory.

Use `--dry-run` for health checks without changes. Use `--quiet` for minimal output.
