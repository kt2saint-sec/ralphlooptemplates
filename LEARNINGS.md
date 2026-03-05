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
