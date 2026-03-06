# Ralph Loop Templates

A Claude Code workflow system combining **antagonistic review**, **proxy decision-making**, and **self-iterating development loops** to build software with minimal human intervention while maintaining quality.

## What This Is

This repo contains the complete prompt engineering system behind the **Ralph Loop** — a self-referential development methodology for Claude Code where:

1. A **Challenger** (Boris Antagonist) interrogates requirements before any code is written
2. A **Proxy** researches answers instead of asking the human, keeping the loop running
3. A **Builder** implements iteratively, with each iteration capturing learnings
4. A **stop hook** prevents session exit, feeding output back as input to create a self-improving loop

The result: you describe a goal, walk away, and come back to working software with documented decision trails.

## Architecture

```
User
  |
  v
/ralphtemplate "Build [your-goal]"
  |
  v
+--------------------------------------------------+
|  ORCHESTRATOR (delegates, never codes)            |
|                                                   |
|  Phase 1: CHALLENGER <---> PROXY                  |
|    |  Identifies 5+ ambiguities     Researches    |
|    |  Proposes 2-3 approaches       codebase,     |
|    |  Raises objections             docs, and     |
|    |  Asks hard questions           conventions   |
|    |                                to answer     |
|    |                                questions     |
|    |                                (never asks   |
|    v                                the user)     |
|                                                   |
|  Phase 2: BUILDER (Ralph Loop)                    |
|    |  Implements solution                         |
|    |  Tests each iteration                        |
|    |  Logs: what failed, root cause, fix, result  |
|    |  CHALLENGER reviews after each milestone     |
|    v                                              |
|                                                   |
|  Phase 3: VERIFICATION                            |
|    |  All tests pass                              |
|    |  CHALLENGER does final review                |
|    |  Unknown impacts disclosed                   |
|    v                                              |
|                                                   |
|  Phase 4: COMPLETION                              |
|    |  Results in plain language                    |
|    |  REVIEWABLE decisions flagged                 |
|    |  Learnings consolidated -> permanent docs     |
|    |  Temp files deleted                          |
|    v                                              |
|  PASSPHRASE (auto-generated, on its own line)     |
+--------------------------------------------------+
```

## The Three Patterns

### 1. Boris Antagonist Method

**What**: Challenge every requirement before writing code. Named after Boris Cherny's approach to rigorous software development.

**Why**: Most AI coding failures happen because requirements were ambiguous, not because the code was wrong. The Challenger catches these before a single line is written.

**Commands**:
- `/boris-challenge` — Identify 5+ ambiguities, propose 2-3 approaches, wait for approval
- `/grill-me` — Staff engineer code review after implementation (scores answers 1-5, requires avg >= 4)
- `/prove-it` — Demand evidence that changes work (no code review, natural language proof)

### 2. Proxy Human-in-the-Loop

**What**: Instead of asking the user questions (which breaks the loop), a Proxy subagent researches the codebase, reads CLAUDE.md/LEARNINGS.md, and makes informed decisions.

**Why**: Traditional human-in-the-loop stops the automation. The Proxy keeps things moving while flagging low-confidence decisions (below 70%) as `REVIEWABLE` for the user to check later.

**How it works**:
1. Challenger raises a question (e.g., "Should auth use JWT or sessions?")
2. Proxy reads project docs, existing patterns, and conventions
3. Proxy responds with best judgment + confidence level
4. If confidence < 70%: decision is marked `REVIEWABLE`
5. Builder proceeds either way — never blocks on human input

### 3. The Ralph Loop

**What**: A self-referential development loop powered by a stop hook. When Claude tries to exit, the hook feeds the same prompt back as input, creating an iterative improvement cycle.

**Why**: Complex tasks need multiple passes. The Ralph Loop automates the "try, fail, learn, retry" cycle with structured learnings capture at each iteration.

**How the stop hook works**:
1. `/ralph-loop` creates a state file (`.claude/ralph-loop.{session}.local.md`)
2. When Claude finishes and tries to exit, the stop hook intercepts
3. Hook reads the last assistant message from the transcript
4. If the completion promise text is found as an exact standalone line in the output (`grep -Fx`), the loop ends
5. Otherwise, the same prompt is fed back with an incremented iteration counter
6. On iterations 2+, Claude is asked to write a brief retrospective before continuing
7. On completion, a consolidation phase extracts durable learnings into permanent docs

**Commands**:
- `/ralph-loop` — Start a loop (max 10 iterations default)
- `/ralph-loop-safe` — Same but with git safety checks (must be on feature branch, clean working dir)

## The `/ralphtemplate` Command

Generates a complete orchestrator prompt combining all three patterns. You provide a task description, and it outputs a plain-text prompt you can paste into any Claude Code session.

**Why plain text?** The generated prompt intentionally uses zero markdown formatting — no triple backticks, no `##` headers, no `**bold**`, no `{curly braces}`, no `(parentheses)` in structural positions. This is critical because markdown characters can cause Claude to "break out" of the Boris antagonist loop by interpreting formatting as code boundaries, section endings, or structural delimiters. By using ALL CAPS for emphasis and plain numbered lists instead, the entire prompt stays in a single continuous instruction space that Claude processes as one coherent directive.

The generated prompt includes:
- **Role 1 (Builder)**: Implements using ralph-loop iteration methodology
- **Role 2 (Challenger)**: Interrogates before and after every major step
- **Role 3 (Proxy)**: Answers questions by researching, never asks the user
- **Role 4 (Researcher)**: Independent knowledge agent — activates when Builder or Proxy is below 75% certainty. Delegates subagents, web search, and MCP servers to find verified information before the team proceeds.
- **Execution flow**: Challenger/Proxy negotiate → Builder implements (Researcher consulted when uncertain) → Challenger reviews → repeat
- **Completion checklist**: 4 honest questions before declaring done

Usage:
```
/ralphtemplate Build a REST API with auth, tests, and deployment
```

### Token-Saving Tip: Write Prompts to .txt Files

Ralph loop prompts can get long — especially with Boris rules embedded. Instead of pasting the entire prompt inline (which burns prompt tokens every iteration), write it to a `.txt` file **outside your project directory** and reference it:

```bash
# 1. Generate the prompt with /ralphtemplate, then save the output to a file
#    Store it OUTSIDE your project dir so it doesn't pollute your repo
cat > ~/prompts/auth-system-build.txt << 'EOF'
[paste the /ralphtemplate output here]
EOF

# 2. Use the .txt content inside the ralph-loop quotes
/ralph-loop "$(cat ~/prompts/auth-system-build.txt)" \
  --max-iterations 30 --completion-promise "ALL TESTS PASSING"
# Note: A unique passphrase (RALPH- prefix + hex hash) is auto-prepended
# to your promise. The actual completion signal becomes: PASSPHRASE::ALL TESTS PASSING
```

**Why outside your project?** Keeping prompt files in `~/prompts/` or similar avoids cluttering your git repo, prevents accidental commits of task-specific prompts, and keeps them reusable across projects.

### Automate Prompt Generation with Haiku

For even more efficiency, use a lightweight Haiku agent to generate and write the `.txt` prompt files for you. This keeps the expensive model (Opus/Sonnet) focused on building while Haiku handles prompt authoring at a fraction of the cost:

```bash
# In your Claude Code session, spawn a Haiku agent to write the prompt file:
```

```
Use the Agent tool with model: "haiku" to generate a ralph-loop prompt.

Example agent call:
  subagent_type: "general-purpose"
  model: "haiku"
  prompt: |
    Generate a ralph-loop orchestrator prompt for this task: [your-task].
    Use the /ralphtemplate format: 3 roles (Builder, Challenger, Proxy),
    plain text only (NO markdown: no ```, ##, **, {}, or () in structure),
    ALL CAPS for emphasis, numbered lists only.
    Write the output to ~/prompts/[descriptive-name].txt
```

Then feed the generated file into your loop:
```bash
/ralph-loop "$(cat ~/prompts/[descriptive-name].txt)" \
  --max-iterations 30 --completion-promise "ALL TESTS PASSING"
```

This pattern means:
- **Haiku** writes the prompt (~$0.001) instead of Opus composing it inline (~$0.05+)
- The prompt lives in a reusable `.txt` file you can tweak and re-run
- Your main session's context window stays clean — no giant prompt strings eating tokens on every iteration

## The Hierarchical CLAUDE.md Setup

This system uses `@import` directives to create a layered configuration:

```
~/.claude/CLAUDE.md (Global)
  |
  +-- @~/.claude/rules/core-behavior.md    (P1-P6 priority rules)
  +-- @~/.claude/rules/planning.md         (Success probability format)
  +-- @~/.claude/rules/agents.md           (Specialized agent registry)
  +-- @~/.claude/rules/session-management.md (Thinking triggers, CLI flags)
  +-- @~/.claude/rules/mcp-servers.md      (MCP server catalog)
  +-- @~/.claude/rules/system-info.md      (Hardware/OS details)
  |
  +-- Active Projects section              (Project-specific context)
  +-- Quality Standards                    (Universal coding rules)

project/CLAUDE.md (Per-Project)
  |
  +-- Inherits everything from global
  +-- Adds project-specific rules, paths, conventions
```

**Why this matters**: Claude Code reads CLAUDE.md at session start. By using `@import`, you keep the always-loaded context small (~120 lines) while having detailed rules available when needed. The priority system (P1-P6) ensures Claude follows the most important rules even under context pressure.

Sanitized templates are in `templates/` — copy them to `~/.claude/` and customize.

## Installation

### Quick Start (Commands Only)

Copy the command files to your Claude Code commands directory:

```bash
mkdir -p ~/.claude/commands
cp commands/*.md ~/.claude/commands/
```

Now you can use `/boris-challenge`, `/ralph-loop`, `/ralphtemplate`, etc. in any Claude Code session.

### Full Setup (Commands + Rules + Loop Engine)

1. **Copy commands**:
```bash
cp commands/*.md ~/.claude/commands/
```

2. **Set up rules** (customize from templates):
```bash
mkdir -p ~/.claude/rules
cp templates/rules/*.template ~/.claude/rules/
# Rename .template files and customize for your setup
for f in ~/.claude/rules/*.template; do mv "$f" "${f%.template}"; done
```

3. **Set up global CLAUDE.md**:
```bash
cp templates/CLAUDE.md.template ~/.claude/CLAUDE.md
# Edit to add your projects, paths, and preferences
```

4. **Install Ralph Loop stop hook** (for the self-referential loop engine):

Run the migration script to set up the hybrid architecture (local commands + settings.json Stop hook):
```bash
bash scripts/migrate-to-hybrid.sh
```

This does three things:
- Adds a Stop hook to `~/.claude/settings.json` pointing to `scripts/stop-hook.sh`
- Copies local commands to `~/.claude/commands/` with absolute paths
- Removes any marketplace plugin entry from `enabledPlugins` (prevents double-fire)

> **Critical**: Claude Code caches hook script **content** at session start. After any edit to scripts/ or commands/, you **must** start a new Claude Code session for changes to take effect.

**Recovery**: If the setup breaks, run `bash RESTORE/restore-hybrid.sh` to check and fix all 6 configuration categories. Use `--dry-run` for a health check without changes.

**Rollback**: To revert to the plugin approach: `bash scripts/rollback-to-plugin.sh`

5. **Verify installation**:
```bash
# Check commands are available
ls ~/.claude/commands/

# Check rules are in place
ls ~/.claude/rules/

# Test a command
claude
# Then type: /boris-challenge
```

## File Structure

```
ralphlooptemplates/
├── README.md                          # This file
├── CLAUDE.md                          # Project-specific Claude Code instructions
├── PLUGIN-SYNC-GUIDE.txt              # How to keep patched plugin working (legacy)
├── commands/                          # Slash commands (copy to ~/.claude/commands/)
│   ├── ralphtemplate.md               # Generate 4-role orchestrator prompts
│   ├── ralphtemplatetest.md           # Generate 5-role prompts (adds Tester)
│   ├── boris-challenge.md             # Challenge requirements before coding
│   ├── ralph-loop.md                  # Self-iterating development loop
│   ├── ralph-loop-safe.md             # Safe loop with git checks
│   ├── prove-it.md                    # Demand evidence of working code
│   ├── grill-me.md                    # Staff engineer code review
│   ├── knowing-everything.md          # Retrospective and knowledge capture
│   ├── scrap-and-redo.md              # Rebuild with accumulated context
│   ├── cancel-ralph.md               # Cancel active loop (session-scoped)
│   └── help.md                        # Plugin help and command reference
├── scripts/                           # Ralph Loop engine
│   ├── setup-ralph-loop.sh            # Creates loop state file
│   ├── stop-hook.sh                   # Intercepts exit, feeds prompt back
│   ├── migrate-to-hybrid.sh           # Migrate plugin to hybrid architecture
│   ├── rollback-to-plugin.sh          # Revert to plugin approach
│   ├── hooks.json                     # Hook configuration (legacy)
│   ├── cache-sync.sh                  # Syncs repo files to plugin cache (legacy)
│   ├── cache-watchdog.sh              # SessionStart hook: detects cache mismatches (legacy)
│   ├── learnings-preamble.md          # Per-iteration retrospective prompt template
│   ├── test-passphrase-detection.sh   # Tests: passphrase format + false positives (18 tests)
│   ├── test-multi-terminal.sh         # Tests: ls -t heuristic behavior (4 tests)
│   ├── test-rename-migration.sh       # Tests: state file rename path (13 tests)
│   ├── test-cache-watchdog.sh         # Tests: actual watchdog script invocation (7 tests)
│   ├── test-consolidation.sh          # Tests: consolidation exit path (10 tests)
│   ├── test-lifecycle.sh              # Tests: full loop lifecycle + glob patterns (18 tests)
│   ├── test-hook-input.sh            # Tests: malformed/empty/valid hook JSON (12 tests)
│   └── test-migration.sh             # Tests: hybrid migration + rollback (13 tests)
├── RESTORE/                           # Recovery tools
│   ├── restore-hybrid.sh             # Idempotent health check + fix
│   └── README.md                      # Symptom-to-cause table
├── docs/                              # Architecture diagrams (HTML)
│   ├── diagram.html                   # v2 system architecture
│   ├── ralphtemplatetest-diagram.html # 5-role system with Tester
│   ├── before-after-diagram.html      # Original vs patched comparison
│   └── system-improvements-diagram.html # Stats and fix history
├── workflow-rules/                    # Development workflow rules
│   └── development-workflow-rules.txt # 5 rules for rigorous development
├── examples/                          # Usage examples
│   ├── ralph-loop-usage-examples.txt  # Common invocation patterns
│   └── ralph-loop-ci-debugging-example.txt  # CI/CD debugging pattern
├── prompts/                           # Prompt collections
│   └── revenue-first-prompts.txt      # 23 revenue-focused development prompts
└── templates/                         # Sanitized config templates
    ├── CLAUDE.md.template             # Global CLAUDE.md with @import pattern
    └── rules/
        ├── core-behavior.md.template  # P1-P6 priority system
        ├── planning.md.template       # Success probability format
        ├── agents.md.template         # Specialized agent registry
        └── session-management.md.template  # CLI flags and thinking triggers
```

## Example Usage

> **Note on completion promises:** A unique passphrase (`RALPH-` prefix + 48 hex chars from `/dev/urandom`) is auto-generated
> for every ralph-loop session. If you provide `--completion-promise "DONE"`, the actual completion signal
> becomes `PASSPHRASE::DONE`. The passphrase prevents false positives from common words in code output.

### Simple: Fix a bug with proof

```
/ralph-loop "Fix the auth token expiry bug. Run tests after each attempt."
  --max-iterations 10 --completion-promise "ALL TESTS PASSING"
```

### Medium: Build a feature with antagonist review

```
/boris-challenge Add rate limiting to the API

# After approval:
/ralph-loop "Implement rate limiting as approved. Test with load testing."
  --max-iterations 20 --completion-promise "LOAD TESTS PASSING"
```

### Advanced: Full orchestrated build

```
/ralphtemplate Build a complete user authentication system with JWT,
  refresh tokens, password reset, and email verification

# Copy the generated prompt, then:
/ralph-loop-safe "[paste prompt]"
  --max-iterations 30 --completion-promise "AUTH SYSTEM COMPLETE"
```

### Review after completion

```
/knowing-everything    # Capture what was learned
/grill-me              # Challenge the implementation
/prove-it              # Demand evidence it works
```

## The Revenue-First Prompts

The `prompts/revenue-first-prompts.txt` file contains 23 production-ready prompts for building revenue-generating products. These combine Boris Cherny's development methodology with revenue-first thinking:

- **Prompts 1-3**: Project setup (revenue hypothesis, environment, CLAUDE.md)
- **Prompts 4-6**: Revenue validation (feature scoring, $100 test, unit economics)
- **Prompts 7-8**: Slash commands (payment verification, conversion checking)
- **Prompts 9-11**: Subagents (revenue validator, conversion optimizer, analytics checker)
- **Prompts 12-13**: Weekly sprints (Monday planning, Friday retrospective)
- **Prompts 14-15**: Feature development (revenue-first planning, rapid MVP)
- **Prompts 16-17**: Launch & growth (checklist, experiment design)
- **Prompts 18-19**: Analytics (revenue dashboard, cohort analysis)
- **Prompts 20-21**: Customer development (interview guide, feedback analysis)
- **Prompts 22-23**: Specialized (pricing optimization, competitive analysis)

## Changelog

### v3 — Hybrid Architecture + Hex Passphrase (2026-03-06)

**56 decisions across 15 development sessions**, each using the Ralph Loop itself to iteratively build, test, and verify.

**Hybrid migration** — Replaced marketplace plugin with local commands + `settings.json` Stop hook. Eliminates the `/plugin update` overwrite problem permanently. The plugin entry is removed entirely from `enabledPlugins` (not just disabled). See `scripts/migrate-to-hybrid.sh`.

**Hex passphrase** — Replaced `WORD NNNN WORD NNNN WORD NNNN` format with `/dev/urandom` hex hash (`RALPH-` prefix + 48 hex chars). LLMs have consistent token bias that caused the same words (MARBLE, CONDOR, LATTICE) to appear repeatedly. OS randomness eliminates this entirely.

**Prompt reliability** — Added CRITICAL always-generate guard to `/ralphtemplate` and `/ralphtemplatetest`. Replaced ambiguous `---` template delimiters with `=== TEMPLATE START/END ===` markers. Prompts now always generate regardless of argument content.

**Recovery tooling** — `RESTORE/restore-hybrid.sh` provides idempotent health check and fix for all 6 hybrid configuration categories. Supports `--dry-run` and `--quiet` modes.

### v2 — Stop Hook Hardening & Test Suite

#### What Changed

**Passphrase system** — Replaced simple word-based completion promises with auto-generated hex hash passphrases (`RALPH-` prefix + 48 hex chars from `/dev/urandom`). Eliminates false-positive promise detection when common words like "DONE" appear in code output. User-provided promises are prefixed with the passphrase automatically. Previous `WORD NNNN` format deprecated in v3 due to LLM token bias causing repeated word selections.

**Session-scoped state files** — State files now include a session identifier in the filename to prevent cross-terminal contamination. On first iteration, the stop hook renames the file using the hook-provided session ID for O(1) direct lookup on subsequent iterations. The rename is protected by `flock` to handle concurrent terminal scenarios safely.

**Dual glob pattern** — The stop hook now supports both the original plugin's state file format (`ralph-loop.local.md`) and the session-scoped format (`ralph-loop.{SESSION_ID}.local.md`). Uses a `nullglob`-compatible character class trick (`loca[l].md`) to ensure non-existent files are properly excluded from bash arrays.

**Hook JSON field support** — The stop hook now extracts `session_id` and `last_assistant_message` from the hook input JSON (piped via stdin), with fallbacks to glob-based lookup and transcript parsing for backward compatibility.

**Consolidation path** — When a loop completes (via promise or max iterations), if learnings were enabled, the stop hook injects a final "consolidate learnings" prompt before exiting. This extracts durable patterns into permanent project documentation.

**Cache sync tooling** — `cache-sync.sh` copies local script changes to the active plugin cache directory, auto-discovering the correct version folder and handling the `scripts/` → `hooks/` path mapping. `cache-watchdog.sh` can be installed as a SessionStart hook to detect when plugin updates overwrite customizations.

**Cancel command** — `cancel-ralph.md` is now session-scoped, reading the session ID from the state file to delete only the current session's files (not all sessions in multi-terminal setups).

#### Why These Changes

The original plugin uses `<promise>` XML tags for completion detection via Perl regex, and `PPID` for session identification. Through 8 iterative sessions, several issues were discovered:

- **Promise false positives**: Simple words like "DONE" or "COMPLETE" could appear naturally in code output, triggering premature loop exit. The passphrase system eliminates this.
- **Multi-terminal conflicts**: `PPID` differs between the setup script and stop hook processes. The hook JSON `session_id` is consistent across both.
- **Plugin cache overwrites**: When Claude Code updates a plugin, the cache directory is replaced with fresh copies. Without the watchdog/sync tooling, local customizations are silently lost.
- **Frontmatter corruption**: The original `awk` pattern for extracting prompts (`/^---$/{i++; next} i>=2`) skips ALL `---` lines in the document, corrupting markdown prompts that use `---` as content separators. The fix only skips the first two `---` (frontmatter delimiters).

#### Testing

95 tests across 8 test suites, all passing:

| Suite | Tests | Coverage |
|-------|-------|----------|
| `test-passphrase-detection.sh` | 18 | Passphrase format, false positive rejection, edge cases |
| `test-multi-terminal.sh` | 4 | `ls -t` determinism, session ID availability |
| `test-rename-migration.sh` | 13 | State file rename, frontmatter update, flock, content preservation |
| `test-cache-watchdog.sh` | 7 | Actual watchdog script invocation with mock cache directories |
| `test-consolidation.sh` | 10 | Consolidation prompt emission, learnings cleanup, second-pass exit |
| `test-lifecycle.sh` | 18 | Full loop lifecycle: setup → rename → iterate → promise → consolidate → cancel |
| `test-hook-input.sh` | 12 | Empty/malformed/valid/binary/large hook JSON, jq resilience |
| `test-migration.sh` | 13 | Hybrid migration, rollback, idempotency, absolute paths |

Run all tests: `for f in scripts/test-*.sh; do bash "$f"; done`

#### Hook Caching Behavior

Claude Code caches hook script **content** at session start. This means:

- **Editing scripts mid-session has no effect.** The hook that executes is the version loaded when the session started.
- **After any edit to scripts/ or commands/**: start a **new** Claude Code session.
- The hybrid architecture (settings.json Stop hook) reads from the repo directly — no cache-sync needed.

#### Known Differences from Original Plugin

The patched stop hook differs from the marketplace version in several ways. See `CLAUDE.md` for a detailed comparison table. The most significant differences: promise detection uses plain-text `grep -Fx` (not XML tags), session ID uses hook JSON (not PPID), and passphrases use `/dev/urandom` hex hashes (not LLM-picked words).

## Credits

- **Boris Cherny's Method**: The antagonist review pattern is inspired by Boris Cherny's approach to rigorous Claude Code development
- **Ralph Loop Plugin**: Available on the Claude Code plugin marketplace
- **Revenue-First Development**: Combines lean startup methodology with AI-assisted development

## License

MIT
