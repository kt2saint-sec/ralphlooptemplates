# Ralph Loop v3

**Self-healing AI development loops for Claude Code.** Describe a goal, walk away, come back to working software with documented decision trails.

Ralph Loop turns Claude Code into a self-correcting build system: a stop hook intercepts every session exit, feeds the same prompt back, and Claude sees its own previous work in files — iterating until the task is genuinely complete.

Built across 24 development sessions, each using the Ralph Loop itself to iteratively build, test, and verify. 91 decisions. 137 tests. 6 adversarial roles.

![Overview — 6 roles, 137 tests, 24 sessions, 91 decisions](docs/overview.png)

![6 Adversarial Roles — Evaluator, Challenger, Tester, Builder, Proxy, Researcher](docs/roles.png)

![Stop Hook Fix — Plugin hooks.json silently drops output, settings.json doesn't](docs/hook-fix.png)

![I/O Fix + Knowledge Cache — Sandbox off /tmp, learnings persist across iterations](docs/io-knowledge.png)

---

## How It Works

### The Loop

```
/ralphtemplatetest [Outputs Antagonistic challenge prompt of task w/ 5 specialized subagents]
    |
    v
/ralph-loop "Build X" --max-iterations 20 --completion-promise "RALPH-1234567890098765432112345678900987654321123456789009876""
    |
    v
CHALLENGER - Reviews all tasks & codebase, gives reasons why it may now work
    |
    v
BUILDER (Presents plan to HITL PROXY) -> PROXY (Makes decisions on task)
    |
    v
(If BUILER or PROXY is under 75% success estimate, passes to RESEARCHER, who then independently mitigates risk and sends it back to subagent) 
Claude tries to exit if PROXY approves plan
    |
    v
Stop hook intercepts:
  - Is the completion passphrase in the output? --> Yes: exit (consolidate learnings first)
  - No: feed the SAME prompt back, increment iteration
    |
    v
Claude sees its previous work in files
    |
    v
Iterates until complete or max iterations reached
```

The "self-referential" part: Claude doesn't talk to itself. The same prompt is repeated, but Claude's work persists in files and git history. Each iteration builds on the last with knowledge caching, improving context per loop.
    |
    v
TESTER is independent. Creates tests in sandbox FIRST, so BUILDER cannot code to "pass the test"
    |
    v
BUILDER develops code in sandbox until all tests pass. Must be able to also explain in natural language why it works.
### The Roles

The `/ralphtemptest` command (recommended) generates modular orchestrator prompts with 6 adversarial roles that prevent the common failure modes of AI coding. The EVALUATOR dynamically scales challenge intensity based on task complexity:

| Role                               | Purpose                                                                                                                                   | Activates                                          |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| **Evaluator** (Complexity Gate)    | Assesses task complexity, assigns tier (LIGHT/STANDARD/THOROUGH/RIGOROUS/MAXIMAL). Governs how hard Challenger and Tester push. Can only escalate, never downgrade. | Phase 0 (first, before all others)                 |
| **Challenger** (Boris Antagonist)  | Raises 3-12+ objections (scaled by Evaluator tier), proposes approaches, reviews after every milestone. Can force redesign.                | Phase 1 (after Evaluator)                          |
| **Tester** (Test-First Gate)       | Creates 3-20+ behavior tests (scaled by tier) BEFORE Builder writes code. Sandbox on dedicated NVMe. Builder can't see test code. Fail = passphrase revoked. | Phase 1.5 (after Challenger, before Builder)       |
| **Builder** (Primary Implementer)  | Writes code against Tester's suite. Logs status, root cause, fix, result per iteration. Paces work within Evaluator's iteration budget.   | Phase 2 (after tests exist)                        |
| **Proxy** (Human Stand-in)         | Answers Challenger's questions by researching codebase and docs. Never says "ask the user." Flags low-confidence decisions as REVIEWABLE.  | When Challenger has questions                      |
| **Researcher** (Fact-Finder)       | Independent knowledge agent. Subagents + web search + MCP servers. Structured reports with sources and confidence.                         | When Builder or Proxy is below 75% certainty       |

### Modular Prompt Development

The template system generates **plain-text orchestrator prompts** — no markdown, no backticks, no formatting that could confuse Claude. Each role's instructions are self-contained text blocks that can be composed modularly:

- `/ralphtemptest` — Full 6-role system (EVALUATOR + Tester + test preservation + DOCUMENTOR)
- `/ralphtemplatetest-v2` — Same as above (alias)
- `/ralphtemplate-v2` — 5 roles (no Tester) with EVALUATOR + DOCUMENTOR
- `/ralphtemplate` — Classic 4 roles (Builder, Challenger, Proxy, Researcher)
- `/ralphtemplatetest` — Classic 5 roles (adds Tester, no EVALUATOR)
- Add `TESTINGOFF` to any test variant to strip Tester role and generate without test-first logic

The EVALUATOR's complexity tiers dynamically scale the entire system:

| Tier | Challenger Objections | Tester Tests | Iteration Budget |
|------|----------------------|--------------|-----------------|
| LIGHT | 3+ | 3-5 | 5 |
| STANDARD | 5+ | 5-10 | 10 |
| THOROUGH | 7+ (per-spec review) | 10-15 | 15 |
| RIGOROUS | 10+ (blocks until resolved) | 15-20 | 20 |
| MAXIMAL | 12+ (proof demanded) | 20+ (security tests) | 30 |

**Why adversarial roles?** Most AI coding failures happen because requirements were ambiguous, not because the code was wrong. The Evaluator scales challenge intensity to match task complexity — a simple CLI tool gets LIGHT review, a production auth system gets MAXIMAL. The Challenger catches ambiguities before code is written. The Tester defines expected behavior before implementation. The Proxy keeps the loop running without human intervention. The Researcher prevents guessing.

### The Passphrase

Every session auto-generates a unique completion passphrase:

```bash
RALPH-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')
# Example: RALPH-66ff1a2b-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e
```

- 8-char epoch hex (structural temporal uniqueness) + 40 hex chars from `/dev/urandom` = true OS randomness, zero LLM token bias
- Epoch is decodable: `printf '%d\n' 0x66ff1a2b` reveals generation timestamp
- Detection uses `grep -Fx` (exact full-line match) — no regex, no partial matches
- Previous `WORD NNNN` format was deprecated: LLMs consistently picked the same words (MARBLE, CONDOR, LATTICE)

---

## Quick Start

### 1. Clone and install commands

```bash
git clone https://github.com/kt2saint-sec/ralphlooptemplates.git
cd ralphlooptemplates
```

```bash
# Copy all commands
mkdir -p ~/.claude/commands
cp commands/*.md ~/.claude/commands/
```

### 2. Install the Stop hook

Run the migration script to set up the hybrid architecture:

```bash
bash scripts/migrate-to-hybrid.sh
```

This does three things:

- Adds a Stop hook to `~/.claude/settings.json` pointing to `scripts/stop-hook.sh`
- Updates local commands with absolute paths to your repo
- Removes any marketplace plugin entry from `enabledPlugins` (prevents double-fire)

### 3. Start a new session and test

```bash
claude
# Then:
/ralph-loop "Say hello world" --max-iterations 3 --completion-promise "HELLO DONE"
```

> **Critical**: Claude Code caches hook script content at session start. After any edit to `scripts/` or `commands/`, you must start a new session.

For the full setup guide with manual installation steps, configuration details, and recovery procedures, see [ralph-loop-v3.md](ralph-loop-v3.md).

---

## Usage

### Simple: Fix a bug

```
/ralph-loop "Fix the auth token expiry bug. Run tests after each attempt." \
  --max-iterations 10 --completion-promise "ALL TESTS PASSING"
```

### Medium: Build a feature with adversarial review

```
/boris-challenge Add rate limiting to the API

# After Challenger approval:
/ralph-loop "Implement rate limiting as approved. Test with load testing." \
  --max-iterations 20 --completion-promise "LOAD TESTS PASSING"
```

### Advanced: Full 6-role orchestrated build (recommended)

```
/ralphtemptest Build a complete user authentication system with JWT,
  refresh tokens, password reset, and email verification

# EVALUATOR assesses complexity → assigns RIGOROUS tier
# Challenger raises 10+ objections → Proxy answers
# Tester creates 15-20 behavior tests in sandbox BEFORE coding
# Builder implements against tests, paced by iteration budget
# DOCUMENTOR saves raw prompt + summary to .txt files
#
# Copy the generated prompt, then:
/ralph-loop "[paste prompt]" \
  --max-iterations 20 --completion-promise "PASSPHRASE"
```

### Advanced: Without test-first (5 roles)

```
/ralphtemptest Build a REST API with pagination TESTINGOFF

# Same EVALUATOR + dynamic challenge, but no Tester or sandbox
```

### Classic: 4-role build (no Evaluator, no Tester)

```
/ralphtemplate Build a simple CLI tool

# Builder, Challenger, Proxy, Researcher — fixed 5 objections
```

### Post-completion review

```
/knowing-everything    # Capture what was learned
/grill-me              # Staff engineer code review
/prove-it              # Demand evidence it works
```

### Token-saving tip

Ralph loop prompts can be long. Write them to a `.txt` file and reference it:

```bash
# Save generated prompt to file (outside project dir)
cat > ~/prompts/auth-build.txt << 'EOF'
[paste /ralphtemplate output here]
EOF

# Feed file into loop
/ralph-loop "$(cat ~/prompts/auth-build.txt)" \
  --max-iterations 30 --completion-promise "AUTH COMPLETE"
```

---

## The `/ralphtemptest` Command (Recommended)

The full 6-role variant with **EVALUATOR** (dynamic complexity scaling), **Tester** (test-first), and **DOCUMENTOR** (auto-saves prompts). This is the recommended command for any non-trivial task. The full command file is at [`commands/ralphtemptest.md`](commands/ralphtemptest.md).

### What it generates

A single plain-text prompt (zero markdown — intentional, prevents Claude from "breaking out" of the instruction space) with:

- **Role 0 (Evaluator)**: Assesses task complexity across 5 dimensions (spec count, scope, risk, dependencies, ambiguity). Assigns a tier that governs ALL other roles' intensity. Can only escalate tier, never downgrade.
- **Role 1 (Builder)**: Implements iteratively against the Tester's suite, paced by Evaluator's iteration budget. Below 75% certainty = delegates to Researcher.
- **Role 2 (Challenger)**: Raises objections scaled by tier (3 for LIGHT, 12+ for MAXIMAL). Per-spec review for THOROUGH+. Reviews after every milestone. Can force redesign.
- **Role 3 (Proxy)**: Answers questions by researching codebase. Never asks the user. Below 75% certainty = delegates to Researcher.
- **Role 4 (Researcher)**: Independent knowledge agent. Subagents + web search + MCP servers. Structured reports with sources and confidence levels.
- **Role 5 (Tester)**: Creates tests scaled by tier (3-5 for LIGHT, 20+ for MAXIMAL) BEFORE Builder writes code. Sandbox on dedicated NVMe. Tests verify behavior, not implementation. Fail on final run = passphrase revoked.
- **DOCUMENTOR** (post-generation): Saves raw prompt to `.txt` file (enables `cat | /ralph-loop` piping) + haiku-generated summary with metadata.

### Execution flow

```
Phase 0:     EVALUATOR assesses complexity --> assigns tier (LIGHT to MAXIMAL)
Phase 1:     Challenger raises tier-scaled objections --> Proxy answers (Researcher if uncertain)
Phase 1.5:   Tester creates tier-scaled test suite in sandbox --> copies to TESTS/before/
Phase 2:     Builder implements against tests --> Evaluator reassesses at milestones (tier only goes UP)
Phase 3:     Builder runs sandbox tests --> Fix implementation (not tests) --> copies to TESTS/after/
Phase 4:     Results in plain language, REVIEWABLE decisions flagged, CHANGES.txt written
Post:        Full test suite re-run --> Sandbox cleaned up --> Prompt saved to .txt files
```

### How to install

1. Copy all commands to `~/.claude/commands/`:

```bash
cp commands/*.md ~/.claude/commands/
```

2. Start a new Claude Code session.

3. Use it:

```bash
/ralphtemptest Build a user dashboard with real-time updates
```

4. The command will:
   - Run EVALUATOR to assess complexity (e.g., THOROUGH tier)
   - Generate a passphrase via `/dev/urandom` (Bash tool)
   - Output a complete plain-text orchestrator prompt with tier-scaled role instructions
   - Save the raw prompt and summary to `.txt` files (DOCUMENTOR)
   - Show the passphrase separately for `--completion-promise`
   - Tell you how to feed it into `/ralph-loop`

### TESTINGOFF toggle

Add `TESTINGOFF` (case-sensitive) anywhere in your arguments to strip the Tester role and generate a 5-role prompt (EVALUATOR + Builder + Challenger + Proxy + Researcher):

```bash
/ralphtemptest Quick refactoring task TESTINGOFF
```

### Test Preservation

When Tester is active, test files are preserved across the build:

```
TESTS/ralph-YYYYMMDD-HHMM/
├── before/     # Tests as originally written (before implementation)
├── after/      # Tests after any corrections during implementation
└── CHANGES.txt # What changed, why, and whether it was a correction or addition
```

---

## v3 Fixes (Hybrid Architecture)

v3 replaced the marketplace plugin with local commands + a `settings.json` Stop hook, and added the EVALUATOR for dynamic complexity scaling. This permanently solves every known issue with the plugin approach.

### Why the plugin was broken

The original Ralph Loop marketplace plugin had 6 critical issues:

1. **Hook output silently dropped** — Plugin `hooks.json` output is not captured ([GH #10875](https://github.com/anthropics/claude-code/issues/10875)). The `settings.json` Stop hook does not have this bug.

2. **`/plugin update` overwrites customizations** — When Claude Code updates a plugin, the cache directory is replaced. All local patches are silently lost. v3 reads directly from the repo — no cache layer at all.

3. **PPID differs between processes** — The original plugin uses PPID for session identification. But the setup script and stop hook run as separate processes with different PPIDs. v3 extracts `session_id` from the hook JSON for O(1) state file lookup.

4. **Plugins re-enable randomly** — [GH #28554](https://github.com/anthropics/claude-code/issues/28554). v3 removes the plugin entry entirely from `enabledPlugins` (not just disables it). No entry = nothing to spontaneously re-enable.

5. **XML tags stripped by renderer** — The original plugin uses `<promise>TEXT</promise>` tags via Perl regex. Claude Code's rendering pipeline strips XML/HTML tags from transcripts. v3 uses plain-text `grep -Fx` detection.

6. **LLM passphrase bias** — The original `WORD NNNN WORD NNNN WORD NNNN` format relied on the LLM to pick random words. LLMs have consistent token bias (MARBLE, CONDOR, LATTICE repeated). v3 uses `/dev/urandom` hex hashes — true OS randomness.

### Additional v3 improvements

- **Session-scoped state files** — Prevents cross-terminal contamination in multi-terminal setups
- **flock-protected rename** — Safe concurrent access when multiple terminals hit glob fallback
- **Frontmatter-safe extraction** — Only skips the first two `---` lines (original skips ALL `---`, corrupting prompts)
- **Learnings consolidation** — On completion, extracts durable patterns into permanent project docs
- **Recovery tooling** — `RESTORE/restore-hybrid.sh` checks and fixes all 6 configuration categories
- **EVALUATOR complexity scaling** — Dynamic tier assignment (LIGHT to MAXIMAL) governs Challenger objection count, Tester test count, and iteration budget
- **DOCUMENTOR auto-save** — Raw prompt to `.txt` + haiku summary with metadata, enables `cat | /ralph-loop` piping
- **Test preservation** — Before/after snapshots in `TESTS/ralph-TIMESTAMP/` with `CHANGES.txt` documenting test evolution
- **137 tests across 10 suites** — Passphrase detection (v1+v2), multi-terminal, lifecycle, hook input validation, migration, session 20 fixes

For the complete v3 setup guide with all configuration details, see [ralph-loop-v3.md](ralph-loop-v3.md).

---

## The CLAUDE.md Pattern

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

Sanitized templates are in `templates/` — copy them to `~/.claude/` and customize.

---

## File Structure

```
ralphlooptemplates/
├── README.md                              # This file
├── CHANGELOG.md                           # Version history and session changes
├── ralph-loop-v3.md                       # Complete v3 setup guide (all fixes, configs)
├── CLAUDE.md                              # Project-specific Claude Code instructions
├── commands/                              # Slash commands (copy to ~/.claude/commands/)
│   ├── ralphtemptest.md                   # 6-role: EVALUATOR + Tester + DOCUMENTOR (recommended)
│   ├── ralphtemplate-v2.md                # 5-role: EVALUATOR + DOCUMENTOR (no Tester)
│   ├── ralphtemplatetest.md               # 5-role: Tester (no EVALUATOR, classic)
│   ├── ralphtemplate.md                   # 4-role: classic orchestrator prompts
│   ├── boris-challenge.md                 # Challenge requirements before coding
│   ├── ralph-loop.md                      # Self-iterating development loop
│   ├── ralph-loop-safe.md                 # Safe loop with git checks
│   ├── prove-it.md                        # Demand evidence of working code
│   ├── grill-me.md                        # Staff engineer code review
│   ├── knowing-everything.md              # Retrospective and knowledge capture
│   ├── scrap-and-redo.md                  # Rebuild with accumulated context
│   ├── cancel-ralph.md                    # Cancel active loop (session-scoped)
│   └── help.md                            # Plugin help and command reference
├── scripts/                               # Ralph Loop engine
│   ├── setup-ralph-loop.sh                # Creates loop state file
│   ├── stop-hook.sh                       # Intercepts exit, feeds prompt back (326 lines)
│   ├── migrate-to-hybrid.sh               # One-command v3 installation
│   ├── rollback-to-plugin.sh              # Revert to plugin approach
│   ├── learnings-preamble.md              # Per-iteration retrospective template
│   └── test-*.sh                          # 10 test suites (137 tests total)
├── RESTORE/                               # Recovery tools
│   ├── restore-hybrid.sh                  # Idempotent health check + fix (6 categories)
│   └── README.md                          # Symptom-to-cause table
├── docs/                                  # Architecture diagrams and images
├── workflow-rules/                        # Development workflow rules
├── examples/                              # Usage examples and patterns
├── prompts/                               # Prompt collections (revenue-first, etc.)
└── templates/                             # Sanitized config templates
    ├── CLAUDE.md.template                 # Global CLAUDE.md with @import pattern
    └── rules/                             # Rule templates (core-behavior, planning, agents)
```

---

## Commands Reference

| Command                 | Roles | Description                                                              |
| ----------------------- | ----- | ------------------------------------------------------------------------ |
| `/ralphtemptest`        | 6     | **Recommended.** EVALUATOR + Tester + DOCUMENTOR + test preservation     |
| `/ralphtemplatetest-v2` | 6     | Same as `/ralphtemptest` (alias)                                         |
| `/ralphtemplate-v2`     | 5     | EVALUATOR + DOCUMENTOR, no Tester                                        |
| `/ralphtemplatetest`    | 5     | Classic: Tester but no EVALUATOR (fixed 5 objections)                    |
| `/ralphtemplate`        | 4     | Classic: Builder, Challenger, Proxy, Researcher                          |
| `/ralph-loop`           | —     | Start a self-iterating development loop                                  |
| `/ralph-loop-safe`      | —     | Same with git safety checks (feature branch required, clean working dir) |
| `/cancel-ralph`         | —     | Cancel active loop (session-scoped, handles multi-terminal)              |
| `/boris-challenge`      | —     | Challenge requirements before coding (identify 5+ ambiguities)           |
| `/grill-me`             | —     | Staff engineer code review (scores 1-5, avg >= 4 required)               |
| `/prove-it`             | —     | Demand evidence that changes work (natural language proof)               |
| `/knowing-everything`   | —     | Retrospective and knowledge capture                                      |
| `/scrap-and-redo`       | —     | Rebuild with full accumulated context                                    |

---

## Credits

- **Geoffrey Huntley** — Pioneered the Ralph Wiggum iterative loop technique ([ghuntley.com/ralph](https://ghuntley.com/ralph/))
- **Boris Cherny** — Inspired the antagonist review pattern for rigorous Claude Code development
- **Ralph Loop Plugin** — Original marketplace plugin that this project patches and extends

## License

MIT
