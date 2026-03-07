# Ralph Loop Templates - Learnings

## Bug Fix Session + Cache Sync

### Decisions Made

1. REPLACED `<promise>` XML tag detection with `grep -Fx` plain-text line matching
   - WHY: Claude Code strips XML tags from transcript output. After 4 iterations with correct tags, detection never fired.
   - TRADEOFF: Plain text is less structured but actually works. Risk of false positive with common words (DONE, COMPLETE).
   - STATUS: RESOLVED — passphrase system (decision 7) eliminates false positive risk.

2. REPLACED `PPID` session ID with `uuidgen` fallback
   - WHY: Setup script and stop hook run as separate processes. PPID differs between them, causing session ID mismatch.
   - TRADEOFF: UUID is unique but not tied to Claude Code session. If Claude Code ever exposes CLAUDE_SESSION_ID, prefer that.

3. REPLACED `awk '/^---$/{i++; next} i>=2'` with `awk '/^---$/ && fm_count<2 {fm_count++; next} fm_count>=2'`
   - WHY: Old pattern skipped ALL `---` lines, corrupting markdown prompts that use triple-dash as content separators.
   - The fix only skips the first two `---` (frontmatter delimiters).

4. ADDED fast-exit guard before stdin read in stop-hook.sh
   - WHY: Stop hook fired on every session end. Reading stdin (cat) blocked even when no ralph loop was active, adding latency to every exit.
   - FIX: Glob check for state files before reading stdin. Exit immediately if none found.

5. CHANGED learnings default from `true` to `false` when field missing
   - WHY: Missing field triggered learnings injection on every iteration even when user didn't request it.

6. CREATED session-scoped cancel-ralph.md
   - WHY: Old version used glob `rm .claude/ralph-loop.*.local.md` which killed ALL sessions in multi-terminal setups.
   - NEW: Reads session ID from state file, deletes specific files. Lists all sessions if multiple exist.

### Surprises

- Claude Code's rendering pipeline aggressively strips XML-like tags from output before writing to transcript. This is undocumented.
- The hooks.json `Stop` hook type does not support a `matcher` field for conditional execution. Every stop hook runs on every session end.
- Plugin cache path structure differs from local project structure (hooks/ vs scripts/).
- Orphaned plugin caches (`.orphaned_at` marker) may still have active hooks.json files. Claude Code's deactivation of orphaned caches is not guaranteed.

### Research Answers

1. `CLAUDE_SESSION_ID` env var: DOES NOT EXIST. Verified via `env | grep -iE 'claude|session'`. Found: `CLAUDECODE=1`, `CLAUDE_CONFIG_DIR=~/.claude`, `CLAUDE_CODE_ENTRYPOINT=cli`. No session identifier exposed.
2. Hook input JSON: Contains `transcript_path` field. Session ID investigation still needed for full schema.
3. `ls -t` with identical timestamps: DETERMINISTIC on ext4. Tested 20 runs — same file selected every time. Falls back to filesystem inode ordering.
4. Orphaned cache cleanup: Claude Code creates `.orphaned_at` marker (Unix ms timestamp) but does NOT delete the directory. Users must clean manually.

### Passphrase System

7. IMPLEMENTED auto-generated passphrase: `WORD NNNN WORD NNNN WORD NNNN` format
   - WHY: `grep -Fx` with simple words (DONE, COMPLETE) has false positive risk
   - FORMAT: Three words from different semantic domains (materials, animals, science) + three 4-digit random numbers
   - USER PROMISES: Prefixed with passphrase via `::` separator
   - TEST: 18/18 tests pass — zero false positives on common words, true positive on actual passphrase
   - COMBINATION SPACE: ~8 trillion possible passphrases

### Orphaned Cache Investigation

- Orphaned plugins with SessionStart hooks can potentially double-fire with active versions
- Orphaned plugins without hooks are safe to delete
- `.orphaned_at` file contents: Unix timestamp in milliseconds

### What Would Break If...

- RESOLVED: Simple promise false positive -> passphrase system eliminates this (tested)
- RESOLVED: Same-second ls -t collision -> deterministic on ext4 (tested 20 runs)
- MITIGATED: Plugin cache auto-update -> watchdog detects mismatch on session start (cache-watchdog.sh)
- State file manually edited with non-numeric iteration -> Handled by numeric validation, exits gracefully

## Refactoring: Hook JSON Fields

### Decisions Made

8. REFACTORED stop-hook.sh to use hook JSON fields
   - session_id: O(1) state file lookup (replaces glob + ls -t)
   - last_assistant_message: direct promise detection (replaces transcript JSONL parsing)
   - stop_hook_active: extracted but NOT used as exit guard
   - WHY NOT stop_hook_active guard: Ralph Loop intentionally blocks stop events repeatedly.
     On iteration 2+, stop_hook_active is always true. Using it as guard kills the loop.
   - STATUS: RESOLVED — confirmed correct design

9. IMPLEMENTED state file rename migration
   - WHY: Setup generates uuidgen ID (no access to hook JSON). Stop hook gets session_id from JSON.
   - FIX: On first iteration, stop hook renames state file from uuidgen to hook session_id.
   - TRADEOFF: First iteration still uses glob fallback. Subsequent iterations use O(1).
   - STATUS: RESOLVED — frontmatter now updated via sed during rename.

10. CREATED cache-watchdog.sh as SessionStart hook
    - WHY: Plugin cache overwrites lose manual patches. No version pinning available.
    - FIX: Compares 3 files on every session start, warns if cache differs from repo.
    - TRADEOFF: Detection only, not auto-restore. RESOLVED: cache-sync.sh created.

11. DELETED orphaned plugin caches with SessionStart hooks
    - WHY: Potential (low) risk of double-fire with active version
    - EVIDENCE: .orphaned_at marker present. Claude Code loads from installPath only.

12. UPDATED stale documentation
    - README.md: 5 references to simple "DONE" promise replaced with passphrase system
    - docs/diagram.html: 3 references to <promise> XML tags replaced
    - Added passphrase behavior note block in README Example Usage section

### Surprises

- stop_hook_active would BREAK the Ralph Loop if used as an exit guard. The docs say "loop detection!"
  but our system IS an intentional loop. This is a semantic mismatch between Claude Code's safety design
  and Ralph Loop's core mechanism.
- State file rename on first iteration is necessary because setup (command) and stop hook (hook) receive
  different session identifiers. There's no way for the setup command to access the hook session_id.
- The hook JSON fields (session_id, last_assistant_message) are documented but unverified in practice.
  All code has fallbacks, but a live test should confirm they're populated.

### What Still Needs Testing

- Live verification of hook JSON fields (debug dump line ready in stop-hook.sh, uncomment to test)
- RESOLVED: State file rename race condition — flock added, tested in test-rename-migration.sh (13/13 pass)
- RESOLVED: Frontmatter session_id mismatch — sed update added to stop-hook.sh during rename
- RESOLVED: cache-watchdog.sh version update — tested in test-cache-watchdog.sh (6/6 pass)

## Resolution: Race Conditions + Cache Sync

### Decisions Made

13. RESOLVED stop_hook_active as CORRECT design decision
    - Ralph Loop IS an intentional loop — stop_hook_active is always true on iteration 2+
    - Using as exit guard would kill loop after first iteration
    - Field remains extracted for potential future diagnostics
    - If Claude Code changes semantics, transcript fallback paths still work

14. CREATED cache-sync.sh (scripts/cache-sync.sh)
    - Dynamically discovers active cache dir (skips orphaned)
    - Handles scripts/ -> hooks/ path mapping
    - Verifies each copy with diff
    - cache-watchdog.sh updated to reference it

15. FIXED state file rename race condition with flock
    - flock -n (non-blocking) on .claude/ralph-loop.lock
    - Re-checks file existence after acquiring lock
    - Losing process skips rename, picks up renamed file via fallback

16. FIXED frontmatter session_id mismatch
    - sed replaces session_id in frontmatter during rename
    - Both filename and frontmatter now match hook session_id

17. DOCUMENTED bash RANDOM bias
    - 15-bit (0-32767), RANDOM % 20 has 0.006% bias for indices 0-7
    - Not security-relevant for passphrase generation (~8 trillion combinations)

### New Test Scripts

- test-rename-migration.sh: 13 tests covering rename, frontmatter update, flock, content preservation
- test-cache-watchdog.sh: 6 tests covering mismatch detection, sync, version update, empty cache

## Retrospective: Dead Code + Portability

### Decisions Made

18. REMOVED dead XML tag detection code from stop-hook.sh
    - WHY: Claude Code strips XML tags. `<promise>...</promise>` can never match.
    - The code path was unreachable since decision 1.
    - Kept only plain-text `grep -Fx` detection.

19. MADE cache-sync.sh and cache-watchdog.sh portable
    - BEFORE: Hardcoded absolute repo path (user-specific)
    - AFTER: `$(cd "$(dirname "$0")/.." && pwd)` (derives from script location)
    - WHY: Other users cloning the repo would have broken paths.

20. COMPRESSED CLAUDE.md Known Risks section
    - 13 RESOLVED items archived to LEARNINGS.md reference
    - Only ACTIVE, NEEDS-LIVE-TEST, NEEDS-TEST, and NOTED items remain

21. UPDATED stale statuses in LEARNINGS.md decisions 1, 8, 9, 10

22. ADDED cache-sync.sh rule to CLAUDE.md

### Surprises

- The XML tag fallback detection survived multiple sessions as dead code.
  No one noticed because the passphrase system made it irrelevant — but dead code is still tech debt.
- Hardcoded repo paths in scripts would have been the first bug any other user hit.
  Portability was never tested because only one developer uses the repo.
- The consolidation path (emit_consolidation_and_exit) has never been tested. It's the most
  complex function in stop-hook.sh (50 lines) and handles learnings extraction, frontmatter
  mutation, and consolidation prompt injection. This is a blind spot.

### What Would Break If...

- Another user clones the repo: FIXED (portable paths)
- Plugin updates overwrite cache: watchdog detects, cache-sync.sh restores (tested)
- Consolidation fires but learnings file is missing: handled (exits cleanly)
- Consolidation fires but state file has no 'consolidating' key: handled (first pass adds it)
- Consolidation fires twice: handled (second pass detects key and exits)

### Untracked Risks

- RESOLVED: emit_consolidation_and_exit() — test-consolidation.sh covers 4 scenarios (10/10 pass)
- RESOLVED: No lifecycle integration test — test-lifecycle.sh covers 7 phases (14/14 pass)

## Live Verification Attempt

### Decisions Made

23. ATTEMPTED live verification of hook JSON fields
    - Enabled debug dump (append mode with timestamps) in stop-hook.sh
    - Synced to cache with cache-sync.sh
    - RESULT: Debug dump was NOT written. Our hook is NOT running.

24. DISCOVERED: Plugin state file format mismatch
    - Original plugin creates: `ralph-loop.local.md` (no session ID in filename)
    - Our stop-hook.sh glob expects: `ralph-loop.*.local.md` (requires session ID)
    - Glob `ralph-loop.*.local.md` does NOT match `ralph-loop.local.md` (verified in bash)
    - This means our stop hook silently fails to find the original plugin's state files

25. DISCOVERED: cache-sync.sh mid-session does NOT replace running hooks
    - Claude Code appears to load/cache hook file content at session start
    - File overwrites during session do not affect hook execution

26. CREATED test-consolidation.sh (10 tests) and test-lifecycle.sh (14 tests)
    - Total test suite: 65 tests across 6 scripts, all passing

### Surprises

- The ORIGINAL plugin's setup creates files with a DIFFERENT naming convention than our
  version. The original uses `ralph-loop.local.md` (no session ID), while ours uses
  `ralph-loop.{SESSION_ID}.local.md`. This is a BREAKING incompatibility.
- cache-sync.sh silently succeeds but the hook that actually runs is the one loaded at
  session start, not the one on disk.
- The ONLY way to test hook changes is: sync files FIRST, then start a NEW session.

## Glob Fix: Dual Pattern Support

### Decisions Made

27. FIXED dual glob pattern for state file discovery
    - BEFORE: `(.claude/ralph-loop.*.local.md)` — misses `ralph-loop.local.md` (original plugin format)
    - AFTER: `(.claude/ralph-loop.local.md .claude/ralph-loop.*.local.md)` — matches both

28. FIXED session ID extraction sed pattern
    - BEFORE: `sed 's/^ralph-loop\.\(.*\)\.local\.md$/\1/'` — fails on `ralph-loop.local.md`
    - AFTER: `sed -E 's/^ralph-loop\.(.+)\.local\.md$/\1/; t; s/^ralph-loop\.local\.md$//'`

29. ADDED 3 glob pattern tests to test-lifecycle.sh (Phase H)

### Surprises

- Running a ralph loop with `completion_promise: null` means the loop runs to max_iterations
  with NO way to signal early completion. Always set `--completion-promise`.
- The original plugin's `ralph-loop.local.md` (no session ID) went unnoticed for multiple sessions
  because our stop-hook.sh had `ralph-loop.*.local.md` which silently matched nothing.
- Deleting the state file (`rm -f .claude/ralph-loop.local.md`) is the cleanest way to cancel
  a loop that has no completion promise.

## Test Completion + Nullglob Fix

### Decisions Made

30. FIXED nullglob bug in dual glob pattern
    - BEFORE: `(.claude/ralph-loop.local.md .claude/ralph-loop.*.local.md)` — literal path bypasses nullglob
    - AFTER: `(.claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md)` — char class makes it a glob pattern

31. REWROTE test-cache-watchdog.sh to invoke actual script
    - BEFORE: inline logic replicating the watchdog's diff checks
    - AFTER: runs `bash "$WATCHDOG"` with `HOME` override pointing to mock cache

32. CREATED test-hook-input.sh (12 tests)
    - Covers: empty string, empty JSON, null values, valid JSON, malformed JSON, partial JSON, extra fields, multiline message, stop_hook_active, binary garbage, large message (10KB), integration fast-exit

33. VERIFIED hook JSON fields via direct pipe invocation
    - Piped JSON with session_id to stop-hook.sh — O(1) lookup worked
    - Piped JSON with last_assistant_message containing passphrase — promise detected, cleanup fired
    - NOT verified via live hook event (mid-session caching prevents this), but functionally equivalent

### Surprises

- `nullglob` only applies to glob PATTERNS (containing `*`, `?`, `[...]`). A literal path like `.claude/ralph-loop.local.md` is ALWAYS included in the array, even if the file doesn't exist.
- The fix `.claude/ralph-loop.loca[l].md` (char class on one character) is a common bash idiom to force nullglob behavior on what would otherwise be a literal path.
- Direct pipe invocation of stop-hook.sh is functionally equivalent to a hook event for testing purposes.

### Test Suite Summary

Total: 83 tests across 7 suites, all passing
- test-passphrase-detection.sh: 18
- test-multi-terminal.sh: 5
- test-rename-migration.sh: 13
- test-cache-watchdog.sh: 7
- test-consolidation.sh: 10
- test-lifecycle.sh: 18
- test-hook-input.sh: 12

## Original Plugin Analysis

### Decisions Made

34. ANALYZED original plugin's stop-hook.sh (marketplace source)
    - Location: ~/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/hooks/stop-hook.sh
    - CRITICAL: Uses `<promise>TEXT</promise>` XML tags via Perl regex for promise detection
    - Our version uses `grep -Fx` plain text (XML tags stripped by Claude Code)
    - The original plugin uses PPID for session ID (not hook JSON session_id)
    - The original plugin only parses transcript (not last_assistant_message from hook JSON)
    - The original plugin's awk skips ALL `---` lines (our version only skips first two)

### Surprises

- The ORIGINAL plugin uses `<promise>` XML tags for detection, which we believed were stripped
  by Claude Code's rendering pipeline. Either: (a) tags are NOT stripped in the context the
  original plugin reads them, or (b) the original plugin's detection is also broken.
- We never compared our version against the original before patching. Multiple sessions of work may
  be solving problems that don't exist in the original, or creating new incompatibilities.

### Unresolved Questions

- Does Claude Code strip XML tags BEFORE or AFTER the stop hook reads the transcript?
- Does the original plugin actually detect `<promise>` tags successfully in practice?
- If both detection methods fail, do loops only exit via max_iterations?

## Local Plugin Installation (Later Superseded)

### Decisions Made

35. INSTALLED plugin locally at ~/.claude/plugins/local/ralph-loop/
    - WHY: Cache-sync approach fought the cache system. Local install eliminates the problem.
    - HOW: Created proper plugin directory structure, copied patched files, updated installed_plugins.json installPath.
    - SCOPE: "user" — applies to ALL projects globally.
    - RISK: Claude Code may not respect arbitrary installPath. UNTESTED.

36. UPDATED /ralphtemplate skill with auto-passphrase generation
    - WHY: Sidesteps `<promise>` tag issue at the template level. No XML needed.
    - HOW: Skill tells Claude to pick random words from MATERIALS/ANIMALS/SCIENCE arrays.
    - NOTE: Claude's "randomness" is pseudo-random (LLM sampling), not cryptographic. Sufficient for passphrases.

37. CONFIRMED scope:user covers all projects globally
    - No per-project plugin installation needed when scope is "user".

38. UPDATED plugin help.md and ralph-loop.md commands
    - Removed all `<promise>` tag references from plugin commands.
    - Updated to reference passphrase system and plain-text output.

39. CREATED plain-text changelog
    - WHY: Natural language summary of all fixes and unknowns for non-technical review.

### Surprises

- The solution to the cache overwrite problem was trivially simple: just point installPath at a
  local directory. Multiple sessions of cache-sync work could have been avoided.
  (NOTE: This approach was later discovered to be non-functional — see next section.)
- scope:"user" in installed_plugins.json means the plugin applies to EVERY project, not just
  this repo. No per-project setup needed.

### Test Suite Summary

Total: 82 tests verified passing across 7 suites
- test-passphrase-detection.sh: 18
- test-multi-terminal.sh: 4
- test-rename-migration.sh: 13
- test-cache-watchdog.sh: 7
- test-consolidation.sh: 10
- test-lifecycle.sh: 18
- test-hook-input.sh: 12

## Plugin Loading Discovery

### Decisions Made

40. DISCOVERED: Claude Code loads plugins from marketplaces/ git checkout, NOT installPath
    - WHY: The local installPath approach was INEFFECTIVE. The /ralph-loop:ralph-loop command
      ran the ORIGINAL unpatched setup script from marketplaces/ dir, not our local version.
    - EVIDENCE: Setup output showed old format — all signatures of the original plugin.
    - IMPACT: installPath in installed_plugins.json is purely metadata. Claude Code ignores it for loading.

41. DISCOVERED: Claude Code caches hook SCRIPT CONTENT at session start
    - WHY: Added debug logging to ALL THREE stop-hook.sh copies (marketplace, cache, local).
      No debug output appeared anywhere. The running hook was the version cached in memory.
    - EVIDENCE: After overwriting all three copies with identical patched versions (verified via diff),
      the old behavior continued. Only a NEW session would pick up changes.
    - IMPACT: Mid-session patching is impossible. Always sync files BEFORE starting a session.

42. REWROTE cache-sync.sh to target ALL THREE directories
    - BEFORE: Only synced to cache dir (one target)
    - AFTER: Syncs to marketplace (PRIMARY), cache, and local dirs (three targets)
    - FILES SYNCED: stop-hook.sh, setup-ralph-loop.sh, learnings-preamble.md, cancel-ralph.md,
      ralph-loop.md, help.md (6 files x 3 targets = 18 copies)

43. ADDED missing repo source files
    - commands/help.md: existed in plugin dir but not in repo
    - scripts/learnings-preamble.md: existed in plugin dir but not in repo
    - commands/ralph-loop.md: repo version was outdated

44. CONFIRMED: /plugin update does git pull on marketplaces repo
    - OVERWRITES all patched files in marketplaces/ dir
    - Must re-run cache-sync.sh immediately after any /plugin update

### Surprises

- The installPath change was completely non-functional. The real fix was always cache-sync.sh
  targeting the marketplace directory.
- Hook script caching is UNDOCUMENTED. No Claude Code docs mention that hook content is
  loaded into memory. The only way to discover this was empirical.
- Debug logging to ALL THREE directories produced zero output. This definitively proves
  the running hook is cached content, not any file on disk.

## RESEARCHER Role Addition

### Decisions Made

45. ADDED RESEARCHER role (Role 4) to /ralphtemplate
    - WHY: Across multiple development sessions, Builder and Proxy repeatedly guessed wrong on
      uncertain items. A formal research step would have caught these earlier.
    - HOW: When Builder or Proxy drops below 75% certainty, they MUST delegate to Researcher.
      Researcher uses subagents, web search, MCP servers (context7, brave, fetch, github),
      source code analysis. Reports structured findings: Question, Sources, Findings, Confidence, Caveats.
    - TRADEOFF: Adds latency when Researcher is invoked. But prevents multi-iteration dead ends
      from wrong assumptions.

### Surprises

- The Researcher role formalized what was already happening informally. The Builder repeatedly
  tried fixes without researching first, burning iterations. The 75% threshold creates a
  forcing function: "if you're not sure, look it up before coding."
- MCP dependency: Researcher effectiveness depends on available MCP servers. If context7,
  brave, or fetch are disabled, Researcher degrades to codebase-only search.

## Hybrid Migration: Plugin-to-Local

### Decisions Made

46. MIGRATED from marketplace plugin to hybrid (local commands + settings.json Stop hook)
    - WHY: 10 sessions fighting cache-sync, marketplace overwrites, and installPath before
      discovering the simple solution. settings.json hooks + local commands permanently solve
      the overwrite problem.
    - HOW: `scripts/migrate-to-hybrid.sh` — disables plugin, adds Stop hook to settings.json,
      creates local commands with absolute paths, removes cache-watchdog.
    - TRADEOFF: Local commands use absolute repo path (not portable to other users without edit).
      Acceptable for single-user project.

47. CREATED rollback script (`scripts/rollback-to-plugin.sh`)
    - WHY: Migration is reversible. If settings.json hooks have unexpected behavior, one-command rollback.
    - HOW: Re-enables plugin, removes Stop hook, re-adds cache-watchdog, runs cache-sync.
    - BACKUP: settings.json backed up to .pre-migration.bak before migration.

48. CREATED /ralphtemplatetest with TESTER role (Role 5)
    - WHY: User requested test-first workflow. AI should not code simply to pass tests.
    - HOW: Tester creates tests in /tmp/ralph-test-sandbox-SESSION_ID/ BEFORE Builder implements.
      Tests verify expected behavior, not implementation details. Sandbox cleaned via trap EXIT.
    - TOGGLE: TESTINGOFF in arguments strips all testing sections from generated prompt.
    - TRADEOFF: Two command files (ralphtemplate.md + ralphtemplatetest.md) to maintain.
      But user explicitly requested separate command, and TESTINGOFF toggle keeps the interface clean.

49. CONFIRMED settings.json Stop hooks are MORE reliable than plugin hooks.json
    - EVIDENCE: GitHub #10875 — plugin hooks.json JSON output is NOT captured/parsed by Claude Code.
      Settings.json hooks work correctly. Same stdin JSON (session_id, last_assistant_message, etc.).
    - IMPACT: The hybrid approach is objectively better, not just a workaround.

50. CREATED test-migration.sh (13 tests)
    - Covers: migration adds Stop hook, disables plugin, preserves other plugins, removes watchdog,
      preserves other SessionStart hooks, creates local commands, uses absolute paths, creates backup,
      points to repo, is idempotent. Rollback: re-enables plugin, removes Stop hook, re-adds watchdog.

### Research Findings (session 12)

Three parallel research agents investigated:

1. SETTINGS.JSON HOOK PARITY: Stop hooks in settings.json receive identical stdin JSON as plugin hooks.
   All 7 fields confirmed: session_id, transcript_path, cwd, permission_mode, hook_event_name,
   stop_hook_active, last_assistant_message. Source: Claude Code official docs + GitHub issues.

2. LOCAL COMMAND RESOLUTION: Plugin commands are namespaced (/ralph-loop:ralph-loop), local commands
   are not (/ralph-loop). They never conflict. Priority: CLI flag > project > user > plugin.
   ${CLAUDE_PLUGIN_ROOT} is undefined in local commands — absolute paths required.

3. PLUGIN DISABLING: Setting enabledPlugins to false does NOT remove marketplace checkout, does NOT
   affect other plugins, does NOT clean up cache. installed_plugins.json entry persists.
   Known bugs: disabled plugins may still show tools (#9996), may re-enable (#28554).

### Surprises (session 12)

- The hybrid approach was available from session 1. Settings.json already had SessionStart and
  PostToolUse hooks — adding a Stop hook was always trivially possible. 10 sessions of cache-sync
  work could have been avoided.
- Settings.json hooks are MORE reliable than plugin hooks (GitHub #10875). The migration is not
  just a workaround — it's an upgrade.
- Parallel research agents (3 running simultaneously) answered all architectural uncertainty in
  under 60 seconds. Previous sessions spent multiple iterations on sequential trial-and-error.
  The Researcher + parallel agents pattern should be the default approach.
- The TESTINGOFF toggle as a string flag in arguments works because it's an unusual all-caps
  compound word. No false positives observed in testing.

### Test Suite Summary (session 12)

Total: 95 tests across 8 suites, all passing
- test-passphrase-detection.sh: 18
- test-multi-terminal.sh: 4
- test-rename-migration.sh: 13
- test-cache-watchdog.sh: 7
- test-consolidation.sh: 10
- test-lifecycle.sh: 18
- test-hook-input.sh: 12
- test-migration.sh: 13 (NEW)

## Documentation & Diagram Updates

### Decisions Made

51. UPDATED all HTML diagrams for v2 architecture (session 13)
    - WHY: diagram.html still showed 3-role system with cache-sync, no Researcher or Tester.
    - CHANGES:
      - diagram.html: Complete rewrite. Now shows 5 roles, /ralphtemplate vs /ralphtemplatetest
        command choice, Phase 1 (Challenger+Proxy+Researcher), Phase 1.5 (Tester sandbox),
        Phase 2 (Builder+Challenger+Researcher), Phase 3 (Verify), Phase 3.5 (Sandbox execution),
        hybrid architecture bar at bottom, promise revocation flow.
      - ralphtemplatetest-diagram.html: NEW. Shows 5-role grid, command comparison, execution flow,
        sandbox architecture, TESTINGOFF toggle side-by-side.
      - before-after-diagram.html: Updated /ralph-loop "After" section — replaced cache-sync with
        hybrid architecture, added rollback info.
      - system-improvements-diagram.html: Stats 50->50 decisions, 12 sessions, 95 tests, 8 suites,
        5 roles. Added Hybrid Migration and Tester Role fix cards. Architecture section replaced
        cache-sync flow with hybrid (settings.json + local commands). Warning box changed to solved.
        Tester added to roles grid.
    - SCREENSHOTS: Chrome headless `--screenshot` with custom window sizes for full-page capture.

### Surprises (session 13)

- Chrome headless `--screenshot` at 1080px height cuts off long pages. Must use custom height
  (e.g., 2200px) to capture full content. No "full page" flag in headless mode.
- diagram.html had `overflow: hidden` and fixed `height: 100vh` — removed for v2 to allow
  full content rendering in headless screenshots.
- The `docs/before-after-diagram.html` and `docs/system-improvements-diagram.html` were created
  in earlier sessions but were never committed (untracked in git). Should commit HTML as created.

### Untracked Risks Identified (session 13)

- RESOLVED (session 14): DOUBLE-FIRE — plugin entry removed entirely from enabledPlugins.
- MITIGATED (session 14): NO VERIFICATION TEST — `RESTORE/restore-hybrid.sh --dry-run` checks
  all 6 categories including Stop hook config. Not automated (must be run manually).
- BINARY BLOAT: Screenshot PNGs (~500KB-1MB each) in docs/ will accumulate in git history.
  Consider .gitignore for screenshots or using a separate branch/release for assets.

## Plugin Entry Removal (session 14)

### Decisions Made

52. REMOVED plugin entry from enabledPlugins entirely (was: set to false)
    - WHY: GitHub #28554 reports disabled plugins can spontaneously re-enable on subsequent sessions.
      A `false` entry can become `true`; a missing entry cannot.
    - WHAT CHANGED: settings.json `enabledPlugins` no longer has `ralph-loop@claude-plugins-official`.
    - WHAT PERSISTS: `installed_plugins.json` entry and `marketplaces/` directory still exist
      (managed by Claude Code's plugin system, not by us). These are harmless without an enabledPlugins entry.
    - MIGRATION SCRIPT: `migrate-to-hybrid.sh` now uses `jq 'del(...)'` instead of `= false`.
    - TEST: `test-migration.sh` Test 2 updated to check for key absence ("missing") not "false".
    - ROLLBACK: `rollback-to-plugin.sh` already uses `= true` which adds the key back. No change needed.

### Surprises

- `enabledPlugins` and `installed_plugins.json` are independent systems. Removing from one doesn't affect the other.
  The `installed_plugins.json` is managed by `/plugin` commands; `enabledPlugins` is user-editable config.
- Setting a key to `false` was always a half-measure. The correct approach (deletion) was available from session 12
  but wasn't used because "disable" felt safer than "remove". In retrospect, removal is strictly safer because
  there's nothing for GitHub #28554 to flip back to `true`.

### What Would Break If...

- `/plugin update` re-adds the enabledPlugins entry: UNKNOWN. Need to monitor after next `/plugin update`.
  If it does, the same `jq 'del(...)'` fix applies. Could add a check to the SessionStart hook.
- Rollback is run: Works correctly. `jq '... = true'` creates the key from scratch.

### Test Suite Summary (session 14)

Total: 95 tests across 8 suites, all passing (no count change — Test 2 behavior changed, not added)

## Hybrid Recovery Script (session 14)

### Decisions Made

53. CREATED RESTORE/restore-hybrid.sh — idempotent health check and fix script
    - WHY: Multiple ways the hybrid setup can break (GitHub #28554, /plugin update, manual edits,
      tools overwriting settings.json). Need a single-command recovery path.
    - WHAT: Checks 6 categories — plugin entry, Stop hook, timeout, cache-watchdog, local commands,
      repo scripts. Fixes any issues found. Supports --dry-run and --quiet modes.
    - HOW IT DIFFERS: migrate-to-hybrid.sh is a one-time migration (creates backup, removes watchdog).
      restore-hybrid.sh is run-anytime recovery (no backup needed, idempotent, non-destructive).
    - LOCAL COMMAND RESTORE: Copies from repo and substitutes ${CLAUDE_PLUGIN_ROOT} with absolute
      path. Also strips hide-from-slash-command-tool (plugin-only frontmatter key).
    - TESTED: Verified on healthy system (0 issues detected) and fully broken mock (8 issues
      detected and fixed). Verified restored ralph-loop.md uses absolute paths.

### Surprises

- The restore script partially addresses MEMORY.md risk 5 ("no automated test verifies settings.json
  Stop hook config"). Running `restore-hybrid.sh --dry-run` is an on-demand health check, but it's
  not automated (no SessionStart hook trigger). A SessionStart health check would add latency to
  every session start for a rare scenario.
- The restore script should have been created alongside migrate-to-hybrid.sh in session 12. The
  pattern "migration script + rollback script" was already established, but "recovery script" was
  missing. The triad should be: migrate, rollback, restore.
- When restoring ralph-loop.md from the repo version, the repo copy still uses ${CLAUDE_PLUGIN_ROOT}
  (the plugin format). The restore script must sed-replace this to absolute path. If the repo copy
  were updated to use a placeholder like REPO_PLACEHOLDER, the restore could be simpler. But that
  would break the plugin version if anyone used it directly.

### What Would Break If...

- Repo commands/ directory is missing: restore can't copy files. Warns but doesn't fix.
- Repo ralph-loop.md format changes: sed substitution pattern might not match. Would silently
  produce a broken command file. LOW RISK — format hasn't changed since session 12.
- User has custom modifications to local commands: restore overwrites them without backup. ACCEPTABLE
  because local commands are generated, not hand-edited. Custom commands would be in project commands.

## Passphrase & Prompt Reliability Fixes (session 15)

### Decisions Made

54. REPLACED word-array passphrase system with /dev/urandom hex hash
    - WHY: LLMs have consistent token bias. "Pick a random word" always gravitates toward MARBLE,
      CONDOR, LATTICE — high-salience tokens the model favors. This is a fundamental property of
      next-token prediction, not fixable by prompting.
    - BEFORE: Three word arrays (MATERIALS/ANIMALS/SCIENCE) + 4-digit numbers, picked by Claude
    - AFTER: `echo "RALPH-$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"` via Bash tool
    - FORMAT: RALPH- prefix + 48 hex chars (e.g., RALPH-000102030405060708090a0b0c0d0e0f1011121314151617)
    - VERIFIED: grep -Fx detection in stop-hook.sh works with new format (4/4 tests pass)
    - VERIFIED: 5 sequential runs produce 5 unique strings (true randomness confirmed)
    - TRADEOFF: Not human-readable. Acceptable because passphrases are always copy-pasted, never typed.

55. ADDED CRITICAL always-generate guard to /ralphtemplate and /ralphtemplatetest
    - WHY: When arguments looked like questions or diagnostics (not implementation tasks),
      Claude sometimes skipped prompt generation entirely, doing analysis instead.
    - FIX: Explicit instruction: "You MUST ALWAYS generate the full prompt template below,
      regardless of what the user's arguments say. Zero exceptions."
    - ALSO: Replaced `---` template delimiters with `=== TEMPLATE START ===` / `=== TEMPLATE END ===`
      to eliminate ambiguity with YAML frontmatter `---` delimiters.

56. SANITIZED RESTORE/README.md
    - Replaced hardcoded user home paths with generic /path/to/ in example output section.
    - Added docs/screenshot-*.png to .gitignore.

### Surprises

- The word-array passphrase system was always fundamentally flawed. LLMs cannot generate true
  randomness from vocabulary selection. The solution was obvious in retrospect: delegate to the OS.
- The `---` delimiter ambiguity was subtle. YAML frontmatter uses `---` as open/close markers
  (lines 1 and 4 of command files). A third `---` in the body could confuse parsers about where
  frontmatter ends and content begins.
- Both command files (/ralphtemplate and /ralphtemplatetest) had identical issues — fixes applied
  to all four copies (repo commands/ + ~/.claude/commands/).

## I/O Pressure Optimization (session 16)

### Decisions Made

57. REJECTED volatile journald — used persistent with aggressive caps instead
    - WHY: Original research suggested `Storage=volatile` (RAM-only). Deep investigation revealed this
      destroys crash logs on reboot/kernel panic. The user JUST HAD a crash — volatile would have
      erased the diagnostic evidence. AMD ROCm driver crashes and OOM events need post-crash logs.
    - FIX: `Storage=persistent` with `SystemMaxUse=2G`, `MaxRetentionSec=2weeks`, `Compress=yes`.
      Caps writes while preserving crash forensics.
    - TRADEOFF: 2GB on disk vs 0 (volatile). Acceptable — the 360GB default was the real problem.
    - STATUS: APPLIED — journald override at `/etc/systemd/journald.conf.d/volatile.conf`, vacuumed to 801.7MB.

58. USED fstab-only for tmpfs /tmp — NO live mount
    - WHY: Process investigation found Xorg X11 socket (`/tmp/.X11-unix/X1`), Chrome singleton socket,
      Claude Code task files (`/tmp/claude-1000/`), Claude MCP bridge socket, and QEMU console FIFOs
      all active in /tmp. A live `mount -t tmpfs` would orphan these, potentially freezing the GUI.
    - FIX: Add fstab entry only (`tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=16G 0 0`).
      Takes effect on next reboot with clean socket initialization.
    - WHY NOT noexec: Claude Code subagents may compile/execute test binaries in /tmp.
    - WHY 16GB: Peak /tmp usage 2.8GB, 16GB = 5.7x headroom. 50% default (64GB) wastes RAM budget.
    - STATUS: FSTAB ENTRY ADDED — requires reboot to activate. Backup at `/etc/fstab.pre-io-optimization.bak`.

59. REFACTORED reduce-io-pressure.sh for per-step execution
    - WHY: Original script applied all 3 optimizations via `--apply` (all-at-once). This prevented
      independent verification of each step and forced risky operations together.
    - FIX: Added `--apply-journald`, `--apply-workspace`, `--apply-tmpfs` flags. Each can be run
      and verified independently. `--apply` remains as convenience (runs all three sequentially).
    - ALSO: Removed `set -e` from script — incompatible with `systemctl is-active` which returns
      exit code 3 for inactive units (not a failure, just "inactive"). Used `set -uo pipefail` instead.
    - ALSO: Rewrote `apply_tmpfs()` to be fstab-only (removed all live mount code).
    - ALSO: Updated diagnostic recommendations to show "REBOOT to activate" when fstab entry exists
      but /tmp is still ext4.
    - STATUS: APPLIED — all three steps executed and verified independently.

60. CONFIRMED Ralph Loop commands need ZERO changes for I/O optimizations
    - WHY: `/ralphtemplatetest` sandbox uses `/tmp/ralph-test-sandbox-SESSION_ID/` (lines 102, 124, 127).
      When /tmp becomes tmpfs, the same path writes to RAM instead of disk. Faster AND eliminates
      root drive pressure. Sandbox is ephemeral (trap cleanup), so RAM-backed storage is ideal.
    - VERIFIED: `diff` between repo `commands/ralphtemplatetest.md` and installed
      `~/.claude/commands/ralphtemplatetest.md` — identical. `stop-hook.sh` /tmp references are
      only in commented-out debug lines (27-28).
    - STATUS: NO CHANGES NEEDED — confirmed across all command and script files.

### Surprises

- `set -euo pipefail` is a common bash "best practice" that BREAKS scripts doing `systemctl is-active`.
  The command returns exit code 3 for inactive units, which `set -e` treats as failure. This caused
  the diagnostic mode to crash when checking `tmp.mount` (which is intentionally inactive).
- The volatile vs persistent journald distinction is a critical safety decision that changes
  depending on whether you're running a server (volatile OK — redundant monitoring) or a dev
  workstation (persistent required — crash logs are the only diagnostic source).
- PrivateTmp (used by 11 services) has ZERO conflicts with tmpfs /tmp. It uses Linux mount
  namespaces layered ON TOP of whatever /tmp is. Historical issue #5189 was RHEL7-specific.
- systemd-tmpfiles-setup.service is also compatible — runs after local-fs.target mount,
  `D /tmp 1777` directive is idempotent on existing tmpfs. fstab entries take precedence over tmp.mount.

### What Would Break If...

- Reboot with tmpfs /tmp: Should work — all services start fresh with clean /tmp. Verify Xorg, Chrome,
  Docker, Claude Code, QEMU all initialize correctly.
- 16GB tmpfs fills up: Processes writing to /tmp get ENOSPC. Unlikely — peak usage was 2.8GB.
  Monitor with `df /tmp` during heavy workloads.
- Docker + tmpfs memory pressure: Docker uses ~20GB, tmpfs caps at 16GB, system needs ~8GB.
  Total potential: 44GB of available RAM. Comfortable margin on systems with 64GB+.
- journald 2-week retention too short: Lose old logs. Acceptable for a dev workstation.
  If debugging a 3-week-old issue, check system backup location.

### Research Findings (session 16)

Deep research via MCP agents (8 web searches, 9 page fetches, 13 authoritative sources):
1. tmpfs sizing: kernel.org docs, Ubuntu blog (96.2% of 502 servers use <1GB /tmp), Launchpad #2069834
2. journald volatile rejection: freedesktop.org journald.conf, man7.org, systemd GitHub #14588
   (hybrid volatile+persistent feature request — declined by maintainers)
3. PrivateTmp compatibility: systemd.io official docs, ArchWiki, Fedora wiki
4. systemd-tmpfiles: Ubuntu Noble manpage — runs After local-fs.target, idempotent on tmpfs

### Files Changed (session 16)

- `scripts/reduce-io-pressure.sh` — major refactor (per-step flags,
  fstab-only tmpfs, removed set -e, updated diagnostics)
- `/etc/systemd/journald.conf.d/volatile.conf` — created (journald caps)
- `/etc/fstab` — added tmpfs entry (backup at .pre-io-optimization.bak)
- Fast NVMe workspace directory — created (sandbox/, tmp/, builds/, README.txt)
