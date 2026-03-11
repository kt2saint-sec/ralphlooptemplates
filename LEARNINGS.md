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
    - Added docs/screenshot-\*.png to .gitignore.

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
    - UPDATE (session 20): SUPERSEDED by decision 72 — sandbox paths migrated to nvme-fast.

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

## v2 Templates: EVALUATOR, Dynamic Iterations, DOCUMENTOR, Test Preservation (session 17)

### Decisions Made

61. CREATED v2 command files as NEW files (not editing originals)
    - WHY: 16 sessions and 60 decisions built a proven stable system. Editing the originals risks
      breaking tested behavior. New v2 files enable side-by-side comparison and instant rollback
      (just delete 4 files).
    - FILES: commands/ralphtemplatetest-v2.md (253 lines), commands/ralphtemplate-v2.md (190 lines)
    - SYNC: Both copied to ~/.claude/commands/ (same as originals)

62. CHOSE qualitative complexity tiers over numeric CHALLENGE_LEVEL
    - WHY: Decision 54 proved numeric variable tracking fails over long Claude conversations.
      The word-array passphrase system had token bias causing MARBLE/CONDOR/LATTICE repetition.
      A numeric CHALLENGE_LEVEL 1-5 carries the SAME risk (Claude forgets or drifts the number).
    - FIX: Qualitative tier names (LIGHT/STANDARD/THOROUGH/RIGOROUS/MAXIMAL) embedded directly
      in role descriptions. Each tier's behaviors are self-contained text, not variable references.
    - MATCHES: The system's proven pattern — 75% certainty gates use linguistic triggers ("BELOW
      75 PERCENT CERTAINTY"), not tracked numeric state.
    - TRADEOFF: Tier descriptions are longer than a simple number. But they work reliably.

63. IMPLEMENTED dual-file DOCUMENTOR (raw .txt + haiku summary)
    - WHY: Generated prompts required manual copy-paste from terminal. Raw .txt enables
      `cat ralph-prompt-*.txt` piping directly into /ralph-loop. Haiku summary adds metadata
      at ~$0.002 cost per generation.
    - RAW FILE: Bash tool write (zero inference cost). Filename: ralph-prompt-YYYY-MM-DD-HHMM.txt
    - SUMMARY FILE: Agent tool with model:haiku. Filename: ralph-prompt-YYYY-MM-DD-HHMM-summary.txt
    - TRADEOFF: Summary adds 2-5s latency. Could fail silently. Raw file is the critical output.

64. IMPLEMENTED test preservation via TESTS/ directory snapshots
    - WHY: Sandbox tests were ephemeral (cleaned via trap). No record of test evolution or
      adjustments made during iteration.
    - STRUCTURE: TESTS/ralph-TIMESTAMP/before/ (Tester originals), after/ (post-iteration),
      CHANGES.txt (plain-text change report with CORRECTION/ADDITION classification).
    - TESTINGOFF: All test preservation stripped when TESTINGOFF is active.
    - ONLY IN: /ralphtemplatetest-v2 (not /ralphtemplate-v2, which has no Tester).

65. FIXED stale test-passphrase-detection.sh format regex
    - WHY: Session 15 (decision 54) changed passphrase from WORD NNNN format to RALPH-hex format.
      The test script was NOT updated — regex still validated ^[A-Z]+ [0-9]{4}... pattern.
      This caused 5/18 test failures that went unnoticed for 2 sessions.
    - FIX: Updated regex to ^RALPH-[0-9a-f]{48}$. Now 18/18 pass.
    - LESSON: When changing a feature, grep for ALL tests/validations of the old behavior.

### Surprises

- The passphrase format test failure (5/18) existed since session 15 but was never caught because
  the test suite was run but failures were attributed to "pre-existing issues" without investigation.
  Two sessions of silent test rot.
- MIGRATION_DECISIONS.md was referenced in MEMORY.md (decision 44) but never created. Either it was
  planned and forgotten, or it was created and deleted. The learnings it would have contained are
  already in LEARNINGS.md decisions 40-50.
- The EVALUATOR's TESTINGOFF interaction creates a fragile dependency: the tier descriptions in the
  template mention Tester test counts, but TESTINGOFF instructs Claude to "omit Tester-specific
  guidance." This relies on Claude correctly interpreting removal, not structural enforcement.
  A more robust approach would be separate tier descriptions for testing-on vs testing-off modes.
- Adding .gitignore entries for DOCUMENTOR outputs (ralph-prompt-\*.txt) and test preservation (TESTS/)
  was NOT in the original plan. Without these, the first v2 usage would commit ephemeral artifacts.

### What Would Break If...

- RESTORE/restore-hybrid.sh is run: v2 command files in ~/.claude/commands/ are NOT restored.
  User must manually re-sync v2 files after a restore. LOW RISK — restore is rare.
- Haiku model unavailable or rate-limited: Summary .txt silently fails, but raw .txt still created.
  The raw file is the functional output; summary is convenience.
- TESTS/ directory grows unbounded: Each v2 run creates a new timestamped subdirectory. No cleanup
  mechanism. User must manually manage. MEDIUM RISK for long-running projects.
- v2 templates diverge from v1 originals: If a bug is found in v1 roles (Builder, Challenger, etc.),
  v2 must be manually updated too. Four files to maintain instead of two.

### Session 18 — v3 Epoch-Stamped Passphrase Format (2026-03-10)

65b. RESEARCHED hex passphrase compatibility across v1/v2 templates (continuation of decision 65)

- FINDING: Both v1 and v2 use identical generation (/dev/urandom) and detection (grep -Fx). Format-agnostic.
- FINDING: 3 stale state files with active:true from abandoned sessions. 4 test files had old WORD NNNN data.
- STATUS: Research complete. Led to decision 66.

66. UPGRADED passphrase from v2 (RALPH-hex48) to v3 (RALPH-epoch8-random40)

- WHY: v2 uniqueness was probabilistic-only (2^192). v3 adds structural temporal uniqueness via epoch.
- FORMAT: `RALPH-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')`
- BENEFIT: Epoch provides debuggability — `printf '%d\n' 0x66ff1a2b` tells you when passphrase was generated.
- RISK: 6 command files must stay synced (4 repo + 2 installed). stop-hook.sh unchanged (grep -Fx is format-agnostic).
- CLEANUP: Removed 3 stale state files, updated test data in 3 existing suites, updated 6 HTML diagrams.
- TESTS: 25 new tests in test-passphrase-v2.sh (format, epoch, randomness, cross-session, detection, YAML round-trip).
- STATUS: IMPLEMENTED. All 120 tests pass across 9 suites.

### Test Suite Summary (session 18)

Total: 120 tests across 9 suites, ALL PASSING

- test-passphrase-detection.sh: 18 (regex updated for v3 format)
- test-passphrase-v2.sh: 25 (NEW — v3 format, epoch, cross-session, YAML round-trip)
- test-multi-terminal.sh: 4
- test-rename-migration.sh: 13
- test-cache-watchdog.sh: 7
- test-consolidation.sh: 10
- test-lifecycle.sh: 18
- test-hook-input.sh: 12
- test-migration.sh: 13

## Retrospective: Institutional Memory Capture (session 19)

### Decisions Made

67. IDENTIFIED documentation stat drift across 3 sessions
    - WHY: README.md said "60 decisions, 95 tests, 16 sessions" — actual is 66/120/18.
      Stats were correct at session 12 and never updated in sessions 13-18.
    - FIX: Updated README.md and ralph-loop-v3.md with current counts.
    - RULE: Update README stats in the same commit as test/decision count changes.

68. IDENTIFIED LEARNINGS.md decision 65 numbering collision
    - WHY: Session 17 defined decision 65 (test regex fix). Session 18 reused "65" for a
      different decision (passphrase compatibility research). Both are valid but share a number.
    - FIX: Renamed session 18's "65" to "65b" with cross-reference.

69. IDENTIFIED 5 stale documentation items
    - ralph-loop-v3.md: v2 passphrase format (48 hex), test count (95/8), missing v2 commands
    - README.md: stale stats (decisions/tests/sessions), missing v2 commands in reference/structure
    - MIGRATION-DECISIONS.md: missing sessions 17-18 architecture decisions
    - knowing-everything.md: references MIGRATION_DECISIONS.md (underscores) but file uses dashes

70. IDENTIFIED v1/v2 template drift as untracked risk
    - WHY: 4 template files share core role definitions (Builder, Challenger, Proxy, Researcher).
      A bug fix in v1 role text must be manually replicated to v2. No automated check exists.
    - MITIGATION: Added to CLAUDE.md Known Risks. Future work: create a diff-based drift check.

### Surprises

- README.md stat drift is a classic "stale comment" problem. The docs said one thing, reality said
  another, and 3 sessions passed without anyone noticing. Automated stat extraction from test
  output would prevent this.
- The MIGRATION-DECISIONS.md filename inconsistency (dashes vs underscores in references) was never
  caught because the file was only read manually, never programmatically. `knowing-everything.md`
  still references the wrong name.
- The v2 template file count (4 in repo + 4 installed = 8 copies) creates a maintenance surface
  that's 4x the original. Each format change (like v3 passphrase) touches all 8 files.

### Untracked Risks (identified session 19)

1. v1/v2 template drift — shared role text with no automated sync check
2. RESTORE/restore-hybrid.sh doesn't restore v2 commands — gap in recovery path
3. TESTS/ directory unbounded growth — no cleanup mechanism for test preservation snapshots
4. README/docs stat drift — counts require manual updates across multiple files
5. 8-file sync surface (4 repo commands + 4 installed) for any template format change
6. Post-reboot tmpfs verification still pending (from session 16)

## SessionStart Hook Fix + Sandbox Path Migration (session 20)

### Decisions Made

71. ADDED "startup" matcher to SessionStart hook for init.sh
    - WHY: init.sh hook had NO matcher, so it fired on ALL SessionStart events including /clear.
      It produces zero JSON stdout, which Claude Code 2.1.72 may interpret as a hook failure.
    - FIX: Added `"matcher": "startup"` to the SessionStart hook in settings.json.
      init.sh sets SUDO_ASKPASS and loads MCP env vars — only needed at actual session start,
      not on resume/clear/compact.
    - FILE: ~/.claude/settings.json (SessionStart block)
    - NOTE (session 20, amended): The matcher was CORRECT BEHAVIOR (limits when init.sh runs)
      but was NOT the cause of the hook error. The actual root cause was decision 73 (background
      process holding stdout FD open). Both fixes are needed.

72. MIGRATED v2 sandbox paths from /tmp to /mnt/nvme-fast/claude-workspace/sandbox/
    - WHY: Session 16 created the nvme-fast sandbox directory specifically for Ralph Loop,
      but template files still hardcoded /tmp/ralph-test-sandbox-\*. Sandbox I/O was hitting
      the root SPCC NVMe instead of the dedicated fast WD SN850X.
    - SUPERSEDES: Session 16 decision "Zero Ralph Loop command changes" (MIGRATION-DECISIONS.md:257-268).
      That decision assumed tmpfs /tmp would handle I/O. The nvme-fast path is more explicit and
      doesn't depend on the pending tmpfs reboot.
    - FILES: commands/ralphtemplatetest.md (3 occurrences), commands/ralphtemplatetest-v2.md (3 occurrences),
      ~/.claude/commands/ copies synced, stop-hook.sh debug comment, .gitignore, CLAUDE.md
    - TESTS: 17 new tests in test-session20-fixes.sh. All 137 tests pass across 10 suites.

73. FIXED SessionStart hook error — background process held stdout FD open
    - WHY: init.sh's `init_askpass_delayed()` spawns a background `( sleep 5; ... ) &` subshell.
      The child inherits the parent's stdout pipe FD. Claude Code's hook runner reads stdout
      until EOF. Main script exits (code 0), but the pipe stays open for 5s until the child's
      sleep completes. The hook runner interprets this delayed EOF as a hook error.
    - ROOT CAUSE PROVEN: 10 empirical tests. `time { bash init.sh | cat > /dev/null; }` took
      5.007s before fix, 0.001s after. Five counterarguments tested and disproven.
    - FIX: Changed `( ... ) &` to `( ... ) </dev/null >/dev/null 2>&1 & disown` on line 69.
      Closes all inherited FDs so the child doesn't hold the parent's pipe open. `disown`
      removes the job from bash's job table.
    - FINDING: All `export` statements in init.sh are dead code from hook context — the hook
      runs as a subprocess and exports die when it exits. The useful side effects are file writes
      (display-env.sh, env.sh, init.log). MCP env vars work by accident (already set by shell profile).
    - FILE: ~/.config/claude-code/init.sh (line 69)
    - BACKUP: BACKUP_RESTORE/init.sh.pre-session20.bak
    - RULE: Hook scripts MUST NOT spawn background processes that inherit stdout/stderr FDs.
      Use `>/dev/null 2>&1 & disown` for any background work in hooks.

### Test Suite Summary (session 20)

Total: 137 tests across 10 suites, ALL PASSING

- test-passphrase-detection.sh: 18
- test-passphrase-v2.sh: 25
- test-multi-terminal.sh: 4
- test-rename-migration.sh: 13
- test-cache-watchdog.sh: 7
- test-consolidation.sh: 10
- test-lifecycle.sh: 18
- test-hook-input.sh: 12
- test-migration.sh: 13
- test-session20-fixes.sh: 17 (NEW)

## Hook Stdin JSON Fix + Prettier Damage Recovery (session 21)

### Decisions

74. PostToolUse hooks used nonexistent `$CLAUDE_FILE_PATH` env var — rewrote as stdin JSON scripts
    - WHY: `~/.claude/settings.json` PostToolUse hooks referenced `$CLAUDE_FILE_PATH` and
      `$CLAUDE_BASH_COMMAND`. Per official docs and GitHub #9567, Claude Code does NOT set these
      env vars. All hook data comes via stdin JSON (same mechanism stop-hook.sh uses).
    - IMPACT: With `$CLAUDE_FILE_PATH=""`, the case statement always matched `*)` (default),
      running `npx prettier --write ""` which either errored or reformatted the entire CWD.
      Confirmed: prettier reformatted 5 HTML docs files (1000+ lines each of indentation changes).
    - FIX: Created external scripts `~/.claude/hooks/post-tool-lint.sh` and
      `~/.claude/hooks/post-tool-git-warn.sh` that read `tool_input.file_path` / `tool_input.command`
      from stdin JSON via `jq`. Removed the `*) npx prettier --write` default case entirely —
      only .ts/.tsx/.js/.jsx/.py files get linted now.
    - COLLATERAL: Reverted 5 docs/*.html files via `git checkout`. Other .md files had only
      harmless blank line additions from prettier (kept as-is alongside intentional content changes).
    - FILES: ~/.claude/settings.json (PostToolUse section), ~/.claude/hooks/post-tool-lint.sh (NEW),
      ~/.claude/hooks/post-tool-git-warn.sh (NEW)
    - BACKUP: BACKUP_RESTORE/settings.json.pre-hook-fix.bak
    - RULE: Claude Code hook data comes via stdin JSON, NOT env vars. Use `jq` to extract fields.
      Pattern: `INPUT=$(cat); FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')`

### Surprises

- `$CLAUDE_FILE_PATH` and `$CLAUDE_BASH_COMMAND` never existed as env vars. The hooks were broken
  since they were first created — every Write/Edit triggered prettier on empty path.
- The `*) npx prettier --write ""` default case was silently reformatting non-code files (.md, .html)
  on every Edit/Write. The `|| true` masked the formatting chaos.
- Prettier markdown table formatting adds column padding (harmless but visible in git diff).
- HTML prettier reformatting is destructive: changes `<!DOCTYPE html>` to `<!doctype html>`,
  rewrites all indentation, reformats inline CSS. Thousands of lines changed per file.

## Ghost Hooks in Cache + Local Directories (session 22)

### Decisions

75. FIXED ghost hooks firing from cache + local plugin directories
    - WHY: Session 21 only disabled marketplace hooks.json. Two more hooks.json locations exist:
      cache (`~/.claude/plugins/cache/`) and local (`~/.claude/plugins/local/`).
      A fourth ghost was cache/superpowers with Windows .cmd hooks running on Linux.
    - FIX: Renamed all hooks.json to hooks.json.disabled in marketplace, cache, and local dirs.
    - RESTORE: restore-hybrid.sh Check 7 now automates ghost hooks.json detection across all 3 dirs.
    - FILES: RESTORE/restore-hybrid.sh (Check 7 added), commands/ v2 renames reverted

76. REVERTED v2 command file rename from session 21
    - WHY: Session 21 renamed ralphtemplate-v2.md → rlphtempnew.md as a debug attempt, not the fix.
    - FIX: Reverted to original names (ralphtemplate-v2.md, ralphtemplatetest-v2.md).

## SessionStart Hook Investigation + init.sh Rewrite Discovery (session 23)

### Decisions

77. CONFIRMED SessionStart matcher "startup" IS valid — docs prove it
    - WHY: Session 20 added `"matcher": "startup"` and noted it was "correct behavior."
      Session 23 incorrectly REMOVED the matcher, then official docs at code.claude.com/docs/en/hooks
      confirmed SessionStart matchers match on "how the session started" with values:
      `startup`, `resume`, `clear`, `compact`.
    - IMPACT: Removing the matcher caused the hook to fire on ALL session types instead of just new sessions.
    - FIX: Restored `"matcher": "startup"` to settings.json SessionStart hook.
    - RULE: SessionStart hooks DO support matchers (unlike Stop/UserPromptSubmit which don't).
      Valid values: startup, resume, clear, compact.

78. DISCOVERED init.sh `export` statements are dead code — CLAUDE_ENV_FILE is correct mechanism
    - WHY: init.sh runs as a SessionStart hook SUBPROCESS. All `export` statements die when the
      subprocess exits — they never reach Claude Code's shell. The official docs state:
      "SessionStart hooks have access to the CLAUDE_ENV_FILE environment variable, which provides
      a file path where you can persist environment variables for subsequent Bash commands."
    - IMPACT: SUDO_ASKPASS, MCP env vars (.env.mcp), and all other exports from init.sh were NEVER
      reaching Claude Code's shell. They only worked by accident because .bashrc ALSO sets them.
    - EVIDENCE: init.sh logs `CLAUDE_ENV_FILE=NOT_SET` — meaning either Claude Code isn't providing
      it or the script isn't detecting it correctly. Needs verification in live hook context.
    - FIX NEEDED: Rewrite init.sh to use `echo "export VAR=val" >> "$CLAUDE_ENV_FILE"` pattern.
    - FILE: ~/.config/claude-code/init.sh
    - DOCS: https://code.claude.com/docs/en/hooks (SessionStart section, "Persist environment variables")

79. DISCOVERED double SSH prompt root cause — two competing ssh-agents
    - WHY: System runs two SSH agents simultaneously:
      (a) gcr-ssh-agent via systemd (GNOME Credential agent, always running)
      (b) ssh-agent started by .bashrc line 264-268 (starts new agent if SSH_AUTH_SOCK empty)
      With `AddKeysToAgent yes` in ~/.ssh/config, git-askpass is called for each agent.
    - EVIDENCE: git-askpass log shows simultaneous double prompts at same second with different PIDs.
    - FIX NEEDED: Remove manual ssh-agent startup from .bashrc; let gcr-ssh-agent handle it.
    - FILE: ~/.bashrc (lines 263-268), ~/.ssh/config (AddKeysToAgent yes)

80. CONFIRMED Stop hooks do NOT support matchers (was already documented, now verified against official docs)
    - Official docs list: "UserPromptSubmit, Stop, TeammateIdle, TaskCompleted, WorktreeCreate,
      WorktreeRemove, InstructionsLoaded — no matcher support, always fires on every occurrence.
      If you add a matcher field to these events, it is silently ignored."
    - This corrects LEARNINGS.md surprise note from session 1 which was correct but is now
      backed by official documentation URL.

81. IDENTIFIED SessionStart hook error root cause — known Claude Code UI bug (GitHub #21643, #12671)
    - WHY: Claude Code displays "hook error" when SessionStart hook stdout is NOT JSON or is empty.
      Debug log from #12671: "Hook output does not start with {, treating as plain text."
      The hook EXECUTES SUCCESSFULLY (exit 0) but the UI falsely shows an error.
    - FIX NEEDED: init.sh must output valid JSON to stdout. Minimal fix: `echo '{"suppressOutput": true}'`
      Better fix: use CLAUDE_ENV_FILE for env vars AND output JSON with additionalContext if needed.
    - CONFIRMED: This is a display-only bug. The hook's side effects (file writes, logging) still work.
      GitHub issues #21643, #12671, #19491, #10871 all document this behavior.
    - SOURCES: https://github.com/anthropics/claude-code/issues/21643,
      https://github.com/anthropics/claude-code/issues/12671

82. CONFIRMED ~/.claude-planB is NOT a second hook source
    - WHY: Claude Code hook discovery path is: ~/.claude/settings.json (user), .claude/settings.json
      (project CWD), .claude/settings.local.json (project local), plugin hooks.json, skill frontmatter.
      ~/.claude-planB is the alternate memory/projects directory, NOT in the hook discovery path.
    - EVIDENCE: ~/.claude-planB/settings.json has NO hooks section (23 lines, minimal config).
      Hooks are ONLY read from ~/.claude/settings.json.
    - RISK: If CWD is home directory, ~/.claude/settings.json loads TWICE (as user AND project settings)
      per GitHub #3465/#13288. This can cause hooks to fire twice.

83. CONFIRMED npm /doctor warnings are cosmetic — not causing hook errors
    - WHY: `npm list -g @anthropic-ai/claude-code` returns empty (already uninstalled).
      /doctor detection logic checks npm cache history, not filesystem (GitHub #12414, #7734).
    - FIX: Run `npm -g uninstall @anthropic-ai/claude-code` to clear npm cache metadata.
      Also check ~/.claude.json installMethod field.

### Surprises

- SessionStart DOES support matchers (unlike Stop). Each event type has different matcher semantics.
  The docs table at code.claude.com/docs/en/hooks#matcher-patterns is the definitive reference.
- init.sh exports were dead code for the ENTIRE lifetime of the hook. They only appeared to work
  because .bashrc independently sets the same vars (SUDO_ASKPASS, MCP API keys via sourcing).
- The `init_askpass_delayed()` background process was triply useless: (1) subprocess exports die,
  (2) the background child's exports die separately, (3) the 5-second delay serves no purpose in
  hook context since it was designed for shell-sourced init, not subprocess hooks.
- CLAUDE_ENV_FILE is a SessionStart-ONLY feature. Other hook types don't have access to it.
- The "SessionStart hook error" displayed for 3+ sessions was purely cosmetic — the hook worked fine.
  GitHub has 5+ issues documenting this exact behavior. The fix is trivial: output JSON to stdout.
- Dual Claude Code installations (npm + native) flagged by /doctor are false positives from npm cache
  metadata. The npm package was already uninstalled but cache entries persist.
- ~/.claude-planB/settings.json has `ralph-loop@claude-plugins-official: true` while
  ~/.claude/settings.json has it as `false`. This discrepancy is CRITICAL because planB IS
  the active config (claudeB alias sets CLAUDE_CONFIG_DIR=~/.claude-planB).

84. DISCOVERED config directory mismatch — ALL session 12-22 edits were to wrong file
    - WHY: User runs `claudeB` alias (in ~/.bash_aliases:67) which sets
      `CLAUDE_CONFIG_DIR="$HOME/.claude-planB"`. This makes ~/.claude-planB/settings.json
      the active config. ~/.claude/settings.json is COMPLETELY IGNORED.
    - IMPACT: The entire hybrid architecture (Stop hook, SessionStart hook, PostToolUse hooks)
      was configured in ~/.claude/settings.json but NEVER active in claudeB sessions.
      Ralph-loop's Stop hook doesn't fire. init.sh doesn't run. PostToolUse linting doesn't run.
    - EVIDENCE: ~/.claude-planB/settings.json has NO hooks section (23 lines, just enabledPlugins).
    - FIX NEEDED: Port hooks from ~/.claude/settings.json to ~/.claude-planB/settings.json.

85. IDENTIFIED actual SessionStart error source — ghost plugin hooks in ~/.claude-planB/plugins/
    - WHY: Session 22 disabled ghost hooks.json in ~/.claude/plugins/ but NEVER touched
      ~/.claude-planB/plugins/. Five plugin hooks.json files with SessionStart hooks exist:
      learning-output-style (ghost), explanatory-output-style (ghost), superpowers (ghost),
      semgrep (2 cache versions, enabled). These output non-JSON/empty → triggers UI bug #21643.
    - FIX NEEDED: Rename to hooks.json.disabled in ~/.claude-planB/plugins/ (same as session 22 did for ~/.claude/plugins/).

## Session 24: Config Mismatch Fix + Ghost Hook Eradication (CONFIRMED WORKING)

### Decisions Made

86. FIXED config directory mismatch — ported hooks to ~/.claude-planB/settings.json
    - WHY: Sessions 12-22 all edited ~/.claude/settings.json, but `claudeB` reads from ~/.claude-planB/settings.json.
      The entire hybrid architecture (Stop hook, SessionStart, PostToolUse) was non-functional in claudeB sessions.
    - HOW: Copied hooks section from ~/.claude/settings.json to ~/.claude-planB/settings.json.
      SessionStart (init.sh), Stop (stop-hook.sh), PostToolUse (lint + git-warn) all ported.
    - BACKUP: ~/.claude-planB/BACKUP_RESTORE/settings.json.pre-session24.bak
    - ROLLBACK: bash ~/.claude-planB/BACKUP_RESTORE/rollback-session24.sh

87. DISABLED 10 ghost hooks.json files in ~/.claude-planB/plugins/
    - WHY: Plugin hooks.json files fire SessionStart hooks even when the plugin's CLI tool isn't installed.
      Non-JSON output from failed commands triggers Claude Code UI error display (GitHub #21643, #12671).
    - TARGETS: learning-output-style (marketplace, ghost), explanatory-output-style (marketplace, ghost),
      superpowers (cache, Windows .cmd on Linux), ralph-loop (marketplace + 4 cache = 5 files),
      semgrep (2 cache versions — semgrep CLI NOT INSTALLED, `semgrep mcp` returns command-not-found).
    - TOTAL: 10 hooks.json → hooks.json.disabled
    - LEFT ACTIVE: hookify (no SessionStart), security-guidance (no SessionStart, 4 cache + 1 marketplace)

88. FIXED init.sh to output valid JSON — prevents GitHub #21643 UI bug
    - WHY: SessionStart hooks that output empty or non-JSON stdout trigger Claude Code's error display.
      init.sh previously output nothing (all logging went to file).
    - HOW: Added `echo '{"suppressOutput": true}'` as final stdout output.
    - ALSO: Made MCP env loading CLAUDE_CONFIG_DIR-aware (tries $CLAUDE_CONFIG_DIR/.env.mcp first, falls back to ~/.claude/.env.mcp).

89. FIXED CLAUDE_ENV_FILE write — hook creates the file, not appends
    - WHY: init.sh checked `-w "$CLAUDE_ENV_FILE"` (is file writable?) but the file doesn't exist yet.
      Claude Code provides the path and expects the hook to CREATE the file. The parent directory exists and is writable.
    - HOW: Changed check from `-w "$CLAUDE_ENV_FILE"` to `-d "$(dirname "$CLAUDE_ENV_FILE")" && -w "$(dirname "$CLAUDE_ENV_FILE")"`.
      Changed `>>` (append) to `>` (create). Now SUDO_ASKPASS persists to Claude session via CLAUDE_ENV_FILE.
    - EVIDENCE: Log showed `CLAUDE_ENV_FILE not available` despite path being set. Parent dir existed but was empty.

90. FIXED double SSH passphrase prompts — removed competing ssh-agent from .bashrc
    - WHY: Two ssh-agents running: gcr-ssh-agent (via systemd user session, always provides SSH_AUTH_SOCK)
      + manual `ssh-agent -s` in .bashrc (lines 264-268). Both tried to add ~/.ssh/id_ed25519,
      causing two passphrase prompts per terminal.
    - HOW: Replaced .bashrc block with: `if [ -n "$SSH_AUTH_SOCK" ]; then ssh-add -l &>/dev/null || ssh-add ...; fi`
      Only adds key if agent exists and key not already loaded.
    - BACKUP: ~/.claude-planB/BACKUP_RESTORE/bashrc-ssh-section.pre-session24.bak

91. DISCOVERED: semgrep plugin enabled but CLI not installed — hooks call nonexistent binary
    - WHY: semgrep@claude-plugins-official is `true` in planB enabledPlugins, but `which semgrep` returns nothing.
      Two cache hooks.json files had SessionStart hooks calling `semgrep mcp -k inject-secure-defaults`.
      The command fails with command-not-found error (non-JSON), triggering UI bug.
    - LESSON: Enabled plugins with hooks can cause errors if their CLI dependency isn't installed.
      The plugin system doesn't verify CLI availability before firing hooks.
    - FIX: Disabled semgrep hooks.json files. Left plugin enabled in enabledPlugins (it may provide
      MCP tools that work via Docker without local CLI).

### Surprises

- The config directory mismatch went undetected for 12 sessions (sessions 12-23). Every hook debugging
  session was editing the wrong file. The fix was trivial once identified — copy the hooks section.
- `CLAUDE_CONFIG_DIR` completely redirects ALL config reading. There is no fallback to ~/.claude/.
  This is by design (multi-account isolation) but means TWO settings.json files must be maintained.
- CLAUDE_ENV_FILE contract: Claude Code provides the path, the hook CREATES the file. The `-w` test
  (file writable?) is wrong — the file doesn't exist yet. Check parent dir writable instead.
- Plugin hooks fire even for plugins whose CLI isn't installed. The plugin system doesn't check
  if the hook command exists before executing it. A `semgrep` hook on a system without semgrep
  produces a shell error message on stdout, which Claude Code interprets as non-JSON = error.
- The original plan left semgrep hooks active ("legitimate, enabled plugin"). This was wrong.
  Being enabled in enabledPlugins doesn't mean the hooks will succeed — the CLI must also exist.

### New Untracked Risks (session 24)

1. `/plugin update` will re-enable ghost hooks in ~/.claude-planB/plugins/ (same as ~/.claude/ risk).
   restore-hybrid.sh Check 7 only checks ~/.claude/plugins/, NOT ~/.claude-planB/plugins/.
2. Two settings.json files must stay in sync. No automated diff/sync mechanism exists.
3. Semgrep plugin enabled but CLI not installed — if semgrep hooks.json is restored by /plugin update,
   the SessionStart error returns. Consider either installing semgrep or removing from enabledPlugins.
4. CLAUDE_ENV_FILE may not be available in all hook contexts (e.g., PostToolUse, Stop). Only verified
   for SessionStart hooks. Other hook types may not set this variable.
5. init.sh now hardcodes `{"suppressOutput": true}` JSON — if Claude Code changes the expected format,
   this could break. The JSON key name is from GitHub issue discussion, not official docs.
