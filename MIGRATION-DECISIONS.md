# Ralph Loop Templates - Migration & Architecture Decisions

## Plugin Loading Architecture

### Decision: Target marketplaces/ as PRIMARY sync directory

**Context**: An early attempt to solve plugin cache overwrites by pointing `installPath` in
`installed_plugins.json` to a local directory (`~/.claude/plugins/local/ralph-loop/`).

**Discovery**: Claude Code loads plugins from `~/.claude/plugins/marketplaces/` (a git checkout),
completely ignoring `installPath`. The local install approach was non-functional.

**Architecture**: cache-sync.sh now syncs to all three directories:

1. `marketplaces/` (PRIMARY - what Claude Code actually loads)
2. `cache/` (secondary - unclear if used, kept for safety)
3. `local/` (reference copy - not functional but kept)

**Tradeoff**: `/plugin update` does `git pull` on marketplaces/, overwriting patches.
No way to prevent this. Mitigation: re-run cache-sync.sh after updates.

**Alternative rejected**: Forking the plugin repo. Too much overhead for a single-user project.

## Hook Script Caching

### Decision: Accept "sync then new session" workflow

**Context**: Discovered Claude Code caches hook script CONTENT at session start. File edits
during a session have zero effect on running hooks.

**Impact**: Debug logging during a session is impossible. Testing requires: edit -> sync -> exit -> restart.

**Tradeoff**: Slower development cycle but no workaround exists. This is Claude Code's architecture.

## Promise Detection Format

### Decision: Plain-text `grep -Fx` over XML `<promise>` tags

**Context**: Original plugin uses `<promise>TEXT</promise>` Perl regex detection.
Claude Code's rendering pipeline strips XML tags from output before transcript.

**Architecture**: Passphrase system (`RALPH-` prefix + 48 hex chars from `/dev/urandom`) with `grep -Fx` exact line match.
No XML tags at any point in the pipeline.

**Tradeoff**: Incompatible with original plugin's detection format. If reverted to original plugin
(via /plugin update without cache-sync), passphrase detection silently fails.

## Session ID Strategy

### Decision: Hook JSON `session_id` with uuidgen fallback + rename migration

**Context**: `PPID` differs between setup script and stop hook (separate processes).
`CLAUDE_SESSION_ID` env var does not exist.

**Architecture**:

1. Setup: generates uuidgen ID, creates `ralph-loop.{UUID}.local.md`
2. Stop hook iteration 1: reads `session_id` from hook JSON, renames file to `ralph-loop.{SESSION_ID}.local.md`
3. Stop hook iteration 2+: O(1) direct lookup by hook session_id

**Tradeoff**: First iteration uses glob fallback (O(n)). Rename is flock-protected for concurrency.

## State File Compatibility

### Decision: Dual glob pattern with nullglob char-class trick

**Context**: Original plugin creates `ralph-loop.local.md` (no session ID).
Our version creates `ralph-loop.{SESSION_ID}.local.md`. Must support both.

**Architecture**: `(.claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md)`

- `loca[l].md` char class forces nullglob to apply (literal paths bypass nullglob)
- `*.local.md` catches session-scoped files

**Tradeoff**: Slightly obscure bash idiom. Well-documented in code comments and LEARNINGS.md.

## Researcher Role Architecture

### Decision: Add independent Researcher as Role 4 in /ralphtemplate

**Context**: Across multiple development sessions, Builder and Proxy repeatedly made wrong assumptions
on uncertain items, burning multiple iterations before discovering the truth.

**Architecture**: When Builder or Proxy is below 75% certainty, they MUST delegate to the Researcher.
The Researcher is independent and unbiased — it gathers facts, not opinions. It can use subagents
(Explore, general-purpose), web search, MCP servers (context7, brave, fetch, github), and source
code analysis. Reports in structured format: Question, Sources checked, Findings, Confidence, Caveats.

**Tradeoff**: Adds latency when invoked. But prevents multi-iteration dead ends from wrong assumptions.
The 75% threshold is a judgment call — too low and it never fires, too high and every step triggers research.

**MCP dependency**: Researcher effectiveness scales with available MCP servers. In environments with
limited MCP access, it degrades to codebase-only search (still useful, just less powerful).

## Hybrid Migration Architecture (session 12)

### Decision: Replace plugin with local commands + settings.json Stop hook

**Context**: 10 sessions fighting the plugin system (cache-sync, marketplace overwrites, installPath
being ignored). The fundamental problem: Claude Code loads plugins from a git checkout that
`/plugin update` overwrites. No amount of cache-sync tooling can prevent this.

**Architecture**:

1. Plugin `ralph-loop@claude-plugins-official` entry REMOVED from enabledPlugins (not just disabled — prevents GitHub #28554 spontaneous re-enable)
2. Stop hook added to settings.json, pointing to repo's `scripts/stop-hook.sh`
3. Local commands in `~/.claude/commands/`: ralph-loop.md, cancel-ralph.md, ralph-loop-help.md
4. All commands use absolute path to repo (`$REPO/`)

**Why settings.json > plugin hooks.json**: GitHub issue #10875 documents that plugin hooks.json
JSON output is NOT properly captured/parsed by Claude Code. Identical hooks in settings.json
work correctly. The migration is objectively more reliable, not just a workaround.

**Tradeoff**: Absolute paths in local commands are not portable to other users. Acceptable for
single-user project. A setup script could generate user-specific paths if needed.

**Alternative rejected**: Forking the plugin repo (too much overhead) and the cache-sync approach
(too fragile, 10 sessions of evidence).

**Rollback**: `bash scripts/rollback-to-plugin.sh` (single command, tested).

## Testing Subagent Architecture (session 12)

### Decision: Separate /ralphtemplatetest command with TESTINGOFF toggle

**Context**: User requested test-first workflow where tests are created BEFORE implementation,
outside the project directory, to prevent the AI from coding simply to pass tests.

**Architecture**:

- Role 5 (Tester) activates in Phase 1.5 (after Challenger, before Builder)
- Sandbox directory: `/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-SESSION_ID/` (migrated from `/tmp/` in session 20)
- Tests verify expected BEHAVIOR, not implementation details
- Builder implements AGAINST the tests (cannot see test code before starting)
- Post-completion: final test run in sandbox, promise revoked if tests fail
- Sandbox cleanup: `trap "rm -rf /mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-SESSION_ID" EXIT`

**TESTINGOFF toggle**: Detected as standalone word in arguments. Strips all Role 5, sandbox,
and test-first sections from generated prompt. Unusual all-caps compound word avoids false positives.

**Tradeoff**: Two command files to maintain (ralphtemplate.md + ralphtemplatetest.md).
Alternative considered: single file with conditional sections. Rejected because the user
explicitly requested a separate command, and the TESTINGOFF toggle provides clean degradation.

**Why separate sandbox**: Tests outside the project prevent test code from polluting the project tree.
/tmp is ephemeral (appropriate — tests are regenerated each session). Sandbox is session-scoped
to avoid collisions in multi-terminal setups.

## Documentation Architecture (session 13)

### Decision: HTML diagrams with Chrome headless screenshots

**Context**: The project has accumulated 53 decisions across 14 sessions. Visual documentation
makes the system architecture accessible for LinkedIn posts, README, and onboarding.

**Architecture**: 4 HTML files in `docs/` with matching `screenshot-*.png` files:

1. `diagram.html` — Main system architecture (the "hero" diagram)
2. `ralphtemplatetest-diagram.html` — /ralphtemplatetest-specific flow
3. `before-after-diagram.html` — Original plugin vs patched hybrid
4. `system-improvements-diagram.html` — All fixes, stats, test coverage

**Style**: Dark cyberpunk theme (background: #0a0e17), gradient text, color-coded role cards.
Consistent across all 4 files.

**Screenshots**: `google-chrome --headless --disable-gpu --screenshot=output.png --window-size=W,H file://input.html`
Custom heights per page (1200-2600px) to capture full content without cutoff.

**Tradeoff**: Screenshot PNGs are binary assets that bloat git history. Could gitignore them
and regenerate on demand, but having them committed makes sharing (LinkedIn, README) immediate.

### Decision: Double-fire risk — RESOLVED (session 14)

**Context**: GitHub #28554 reports disabled plugins may re-enable on subsequent sessions.
If ralph-loop plugin re-enables while settings.json Stop hook exists, both hooks fire.

**Resolution**: Removed the plugin entry entirely from `enabledPlugins` in settings.json.
No entry = nothing to spontaneously re-enable. The `installed_plugins.json` entry and
`marketplaces/` directory still exist (managed by Claude Code), but without an `enabledPlugins`
entry, the plugin cannot activate.

**Previous risk**: State file processed twice per session end, corrupting iteration count.
**Current risk**: None. Entry removal is strictly more protective than `false`.

## Recovery Architecture (session 14)

### Decision: Idempotent restore script separate from migration

**Context**: The hybrid setup can break in multiple ways — `/plugin update` re-adding entries,
GitHub #28554, manual edits, tools overwriting settings.json. The migration script is designed
for one-time use. The rollback script reverts entirely. Neither handles "fix what's broken,
keep what's working."

**Architecture**: `RESTORE/restore-hybrid.sh` — a standalone script that:

1. Checks 6 categories of potential breakage
2. Fixes only what's wrong (skips what's correct)
3. Reports all findings (WARN/FIX/OK)
4. Supports `--dry-run` (health check only) and `--quiet` (minimal output)

**Script triad**: migrate (one-time setup) / rollback (full revert) / restore (fix broken state).

**Why not a SessionStart hook**: A health check on every session start adds latency for a rare
scenario. The restore script is on-demand — run it when something seems wrong, or periodically
after `/plugin update`.

**Why not merge with migrate-to-hybrid.sh**: The migration script creates backups, handles
first-time setup (mkdir, initial file creation), and removes the cache-watchdog. These are
one-time operations. The restore script assumes migration already happened and only fixes drift.

**Tradeoff**: Local command restore overwrites without backup. Acceptable because local commands
are generated from repo sources, not hand-edited. User custom commands live in project-level
`.claude/commands/`, not `~/.claude/commands/`.

## I/O Pressure Optimization Architecture (session 16)

### Decision: Persistent journald with caps over volatile

**Context**: System crash during heavy Ralph Loop workload. Root cause: journald, /tmp, and
Ralph Loop sandbox all writing to the root NVMe drive simultaneously. Initial research recommended
`Storage=volatile` (RAM-only) to eliminate journal disk writes entirely.

**Discovery**: Volatile journald destroys crash logs on reboot/kernel panic. The user had JUST
experienced a crash — volatile would have erased the diagnostic evidence needed to identify root
cause. AMD ROCm driver crashes and OOM events require persistent logs for post-mortem debugging.
systemd maintainers declined a hybrid volatile+persistent feature (GitHub #14588).

**Architecture**: `Storage=persistent` with aggressive caps:

- `SystemMaxUse=2G` (down from default 10% of root filesystem — can be hundreds of GB on large drives)
- `MaxRetentionSec=2weeks` (auto-prune old entries)
- `MaxFileSec=1week` (rotate weekly)
- `Compress=yes` (reduce write volume)
- Drop-in override at `/etc/systemd/journald.conf.d/volatile.conf`

**Tradeoff**: 2GB on disk vs 0 (volatile). But crash forensics preserved. The real problem was
the 360GB default cap, not the existence of persistent storage.

### Decision: Fstab-only tmpfs — no live mount

**Context**: Moving /tmp to 16GB tmpfs eliminates root drive I/O from temporary files. But a live
`mount -t tmpfs tmpfs /tmp` would orphan active sockets (Xorg, Chrome, Claude Code, QEMU).

**Architecture**: Add fstab entry only. Takes effect on next reboot when all services initialize
with clean /tmp. No live mount code in the script at all (removed, not just skipped).

- Entry: `tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=16G 0 0`
- No `noexec`: Claude Code subagents may compile/execute test binaries in /tmp
- 16GB cap: 5.7x headroom over peak 2.8GB usage. 50% default wastes RAM budget on high-memory systems.

**Tradeoff**: Requires reboot to activate. But zero disruption to running session.

### Decision: Per-step script execution over all-at-once

**Context**: Original `reduce-io-pressure.sh --apply` ran all 3 optimizations sequentially with
no way to verify each independently or skip one that failed.

**Architecture**: Individual flags (`--apply-journald`, `--apply-workspace`, `--apply-tmpfs`).
`--apply` remains as convenience that calls all three. Each step is idempotent (checks if already
applied before acting). Diagnostic mode updated to show context-aware recommendations (e.g.,
"REBOOT to activate" when fstab entry exists but /tmp is still ext4).

**Tradeoff**: More CLI flags to document. But matches the "apply one, verify, then next" workflow
that prevented the crash investigation from being disrupted.

### Decision: Zero Ralph Loop command changes

**SUPERSEDED by session 20 (decision 72)**: Sandbox paths migrated from `/tmp/ralph-test-sandbox-*`
to `/mnt/nvme-fast/claude-workspace/sandbox/ralph-test-sandbox-*`. The nvme-fast path is explicit
and doesn't depend on the pending tmpfs /tmp reboot.

**Original context (session 16)**: Ralph Loop sandbox writes to `/tmp/ralph-test-sandbox-SESSION_ID/`. When /tmp becomes
tmpfs, this path stays identical but writes to RAM instead of disk.

**Original architecture**: No code changes. The sandbox benefits automatically because tmpfs is transparent
to applications. The path `/tmp/...` resolves to whatever filesystem is mounted at /tmp. Ephemeral
sandbox + RAM-backed storage is the ideal combination (fast writes, auto-cleanup).

**Alternative considered (session 16)**: Adding `RALPH_SANDBOX_BASE` env var to redirect sandbox to
a fast secondary NVMe workspace directory. Rejected because tmpfs /tmp already solves the I/O
problem, and adding a configurable base path increases complexity for zero benefit.

**Why superseded (session 20)**: The tmpfs /tmp fstab entry requires a reboot that hasn't happened yet.
Meanwhile, sandbox I/O continued hitting the root SPCC NVMe. Explicit nvme-fast paths provide
immediate benefit and work regardless of /tmp mount status.

## v2 Template Architecture (session 17)

### Decision: New files instead of editing originals

**Context**: 16 sessions and 60 decisions built proven v1 templates. Adding EVALUATOR, dynamic
iterations, and DOCUMENTOR required significant structural changes to the template commands.

**Architecture**: Created 4 new files (2 repo + 2 installed):

- `commands/ralphtemplate-v2.md` (190 lines) — adds EVALUATOR + DOCUMENTOR
- `commands/ralphtemplatetest-v2.md` (253 lines) — adds EVALUATOR + DOCUMENTOR + test preservation
- Both copied to `~/.claude/commands/`

**Why not edit originals**: Editing v1 would risk breaking tested behavior (95 tests at the time).
New files enable side-by-side comparison and instant rollback (delete 4 files). The v1/v2 versions
can be tested independently.

**Tradeoff**: Core roles (Builder, Challenger, Proxy, Researcher) are duplicated across v1/v2.
A bug fix in v1 must be manually applied to v2. No automated drift detection exists.

### Decision: Qualitative complexity tiers over numeric CHALLENGE_LEVEL

**Context**: Decision 54 (session 15) proved LLMs can't reliably track numeric variables across
long conversations. The word-array passphrase had token bias. A numeric CHALLENGE_LEVEL 1-5
carries the same risk.

**Architecture**: EVALUATOR assigns qualitative tiers: LIGHT/STANDARD/THOROUGH/RIGOROUS/MAXIMAL.
Each tier's behaviors are embedded as self-contained text in role descriptions, not variable
references. This matches the 75% certainty gate pattern (linguistic trigger, not tracked state).

**Tradeoff**: Tier descriptions are longer than a simple number. But they work reliably because
each tier is a standalone paragraph, not a number that must be remembered across turns.

### Decision: DOCUMENTOR with dual-file output

**Context**: Generated prompts required manual copy-paste from terminal output.

**Architecture**:

1. Raw .txt file written via Bash tool (zero inference cost). Enables `cat | /ralph-loop` piping.
2. Summary .txt written via Agent tool with model:haiku (~$0.002/generation). Includes metadata,
   tier assessment, role count, and suggested `/ralph-loop` command.

**Tradeoff**: Summary adds 2-5s latency and may fail silently. Raw file is the critical output.

### Decision: Test preservation via TESTS/ directory

**Context**: Sandbox tests were ephemeral (cleaned via trap). No record of test evolution.

**Architecture**: `/ralphtemplatetest-v2` only. Copies sandbox tests to `TESTS/ralph-TIMESTAMP/before/`
and `TESTS/ralph-TIMESTAMP/after/` with `CHANGES.txt`. TESTINGOFF strips all preservation code.

**Tradeoff**: TESTS/ grows unbounded (one directory per run). No cleanup mechanism.
`.gitignore` prevents accidental commits.

## v3 Passphrase Format (session 18)

### Decision: Add epoch timestamp to passphrase

**Context**: v2 passphrase (RALPH- + 48 hex chars) had probabilistic-only uniqueness (2^192).
No way to determine when a passphrase was generated without external records.

**Architecture**: `RALPH-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')`

- First 8 hex chars = epoch timestamp (structural temporal uniqueness)
- Remaining 40 hex chars = /dev/urandom randomness
- Regex updated from `^RALPH-[0-9a-f]{48}$` to `^RALPH-[0-9a-f]{8}-[0-9a-f]{40}$`

**Why epoch**: Decodable (`printf '%d\n' 0xEPOCH`) for debugging stale state files.
Passphrases from different seconds are guaranteed structurally different, even if /dev/urandom
hypothetically returned identical bytes.

**Tradeoff**: 6 command files (4 repo + 2 installed) must be updated atomically. stop-hook.sh
unchanged (grep -Fx is format-agnostic). 25 new tests in test-passphrase-v2.sh.

## Dual Config Directory Architecture (session 24)

### Decision: Maintain hooks in BOTH settings.json files

**Context**: `claudeB` alias sets `CLAUDE_CONFIG_DIR=~/.claude-planB`, completely redirecting all
config reading. Sessions 12-22 edited `~/.claude/settings.json` — which is IGNORED when running
as `claudeB`. The entire hybrid architecture (Stop hook, SessionStart, PostToolUse) was
non-functional for 12 sessions.

**Architecture**: Both config directories now have identical hooks sections:

1. `~/.claude/settings.json` — active when running plain `claude`
2. `~/.claude-planB/settings.json` — active when running `claudeB`
3. Hook commands use absolute paths (not relative to config dir)
4. `~/.claude-planB/commands/` is a symlink to `~/.claude/commands/` — shared commands

**Why not symlink settings.json**: The two files have different `enabledPlugins` sections
(different accounts may want different plugins). Only the hooks section needs to be identical.

**Tradeoff**: Two files to maintain. No automated sync mechanism. If a hook is added to one
settings.json, it must be manually added to the other. This is acceptable because hook changes
are rare (6 changes across 24 sessions).

**Rollback**: `bash ~/.claude-planB/BACKUP_RESTORE/rollback-session24.sh` restores planB
settings.json to its pre-session-24 state (no hooks).

### Decision: Disable ALL plugin hooks.json in planB (aggressive approach)

**Context**: 10 hooks.json files in `~/.claude-planB/plugins/` were causing SessionStart errors.
Initially left semgrep hooks active (enabled plugin, "legitimate"). But semgrep CLI wasn't
installed — hooks calling `semgrep mcp` failed with command-not-found, outputting non-JSON
to stdout, triggering the UI error.

**Architecture**: Renamed ALL non-essential hooks.json to hooks.json.disabled:
- 3 marketplace ghosts (learning-output-style, explanatory-output-style, ralph-loop)
- 5 cache versions (ralph-loop x4, superpowers)
- 2 semgrep cache versions (CLI not installed)
- Left 6 active: hookify (1) + security-guidance (5) — neither has SessionStart hooks

**Why aggressive**: Plugin hooks are an unreliable delivery mechanism (GitHub #10875, #21643).
Settings.json hooks are strictly more reliable. Disabling ALL plugin hooks that have SessionStart
events eliminates the class of error entirely. Any necessary hook behavior should be in settings.json.

**Tradeoff**: `/plugin update` runs `git pull` on marketplace, restoring disabled hooks.json files.
Must re-disable after every `/plugin update`. Cache hooks persist until version change.

### Decision: init.sh outputs JSON to prevent UI bug

**Context**: GitHub #21643 and #12671 document that SessionStart hooks outputting non-JSON or
empty stdout trigger Claude Code's error display in the UI. The hook executes correctly — the
error is purely cosmetic. But it's confusing and masks real errors.

**Architecture**: `echo '{"suppressOutput": true}'` as the final line of init.sh.
All other output goes to the log file (`~/.cache/claude-code/init.log`).

**Why suppressOutput**: This key is mentioned in GitHub issue discussions as the way to signal
"hook ran successfully, nothing to display." Not in official docs — convention from community.

**Tradeoff**: If Claude Code changes the expected JSON format, this could break. Low risk —
the key is ignored if unrecognized (hooks are best-effort).

### Decision: CLAUDE_ENV_FILE for env var persistence

**Context**: init.sh `export SUDO_ASKPASS=...` is dead code — hooks run as subprocesses,
exports die when the process exits. CLAUDE_ENV_FILE is the official mechanism for SessionStart
hooks to persist environment variables to the Claude Code session.

**Architecture**:
1. Claude Code sets `CLAUDE_ENV_FILE=/path/to/session-env/UUID/sessionstart-hook-N.sh`
2. The parent directory exists and is writable; the file does NOT exist yet
3. Hook creates the file with `KEY=VALUE` pairs (no `export` prefix)
4. Claude Code reads the file after hook exits and sets the env vars in the session

**Why not `-w` check**: The file doesn't exist when the hook runs. `-w` tests if a file is
writable, returning false for nonexistent files. Check parent dir writable instead:
`[[ -d "$(dirname "$CLAUDE_ENV_FILE")" && -w "$(dirname "$CLAUDE_ENV_FILE")" ]]`

**Tradeoff**: CLAUDE_ENV_FILE availability is only confirmed for SessionStart hooks.
Other hook types (Stop, PostToolUse) may not set this variable.
