# Ralph Loop v3

**Self-healing AI development loops for Claude Code.** Describe a goal, walk away, come back to working software with documented decision trails.

Ralph Loop turns Claude Code into a self-correcting build system: a stop hook intercepts every session exit, feeds the same prompt back, and Claude sees its own previous work in files — iterating until the task is genuinely complete.

Built across 24 development sessions, each using the Ralph Loop itself to iteratively build, test, and verify. 91 decisions. 137 tests. 5 adversarial roles.

![Overview — 5 roles, 137 tests, 24 sessions, 91 decisions](docs/overview.png)

![5 Adversarial Roles — Challenger, Tester, Builder, Proxy, Researcher](docs/roles.png)

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

The `/ralphtemplate` and `/ralphtemplatetest` commands generate orchestrator prompts with adversarial roles that prevent the common failure modes of AI coding:

| Role                              | Purpose                                                                                                                                   | Activates                                          |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| **Challenger** (Boris Antagonist) | Raises 5+ ambiguities, proposes 2-3 approaches, reviews after every milestone. Can force redesign.                                        | Before any code is written, after every major step |
| **Builder** (Primary Implementer) | Writes code, runs tests, iterates. Logs status, root cause, fix, result per iteration.                                                    | Phase 2 (after Challenger/Proxy negotiate)         |
| **Proxy** (Human Stand-in)        | Answers Challenger's questions by researching codebase and docs. Never says "ask the user." Flags low-confidence decisions as REVIEWABLE. | When Challenger has questions                      |
| **Researcher** (Fact-Finder)      | Independent knowledge agent. Subagents + web search + MCP servers. Structured reports with sources and confidence.                        | When Builder or Proxy is below 75% certainty       |
| **Tester** (Test-First Gate)      | Creates tests BEFORE Builder writes code. Sandbox on dedicated NVMe. Builder can't see test code. Fail = passphrase revoked.              | Phase 1.5 (`/ralphtemplatetest` only)              |

**Why adversarial roles?** Most AI coding failures happen because requirements were ambiguous, not because the code was wrong. The Challenger catches these before a single line is written. The Proxy keeps the loop running without human intervention. The Researcher prevents guessing.

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

### Advanced: Full orchestrated build (4 roles)

```
/ralphtemplate Build a complete user authentication system with JWT,
  refresh tokens, password reset, and email verification

# Copy the generated prompt, then:
/ralph-loop "[paste prompt]" \
  --max-iterations 30 --completion-promise "AUTH SYSTEM COMPLETE"
```

### Advanced: Test-first orchestrated build (5 roles)

```
/ralphtemplatetest Build a REST API with auth, pagination, and rate limiting

# The Tester creates tests BEFORE the Builder writes code
# Tests run in a sandbox directory, isolated from the project
# Copy the generated prompt, then:
/ralph-loop "[paste prompt]" \
  --max-iterations 30 --completion-promise "API COMPLETE"
```

Add `TESTINGOFF` to the arguments to disable the Tester role and generate a 4-role prompt instead:

```
/ralphtemplatetest Build a simple CLI tool TESTINGOFF
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

## The `/ralphtemplatetest` Command

This is the 5-role variant that adds a **Tester** (Role 5) for test-first development. The full command file is included in this repo at [`commands/ralphtemplatetest.md`](commands/ralphtemplatetest.md).

### What it generates

A single plain-text prompt (zero markdown — intentional, prevents Claude from "breaking out" of the instruction space) with:

- **Role 1 (Builder)**: Implements iteratively against the Tester's suite. Below 75% certainty = delegates to Researcher.
- **Role 2 (Challenger)**: Identifies 5+ ambiguities before any code. Reviews after every milestone. Can force redesign.
- **Role 3 (Proxy)**: Answers questions by researching codebase. Never asks the user. Below 75% certainty = delegates to Researcher.
- **Role 4 (Researcher)**: Independent knowledge agent. Subagents + web search + MCP servers. Structured reports with sources and confidence levels.
- **Role 5 (Tester)**: Creates tests BEFORE Builder writes code. Sandbox on dedicated storage. Tests verify behavior, not implementation. Fail on final run = passphrase revoked.

### Execution flow

```
Phase 1:     Challenger raises objections --> Proxy answers (Researcher consulted if uncertain)
Phase 1.5:   Tester creates test suite in sandbox --> Challenger reviews edge case coverage
Phase 2:     Builder implements against tests (cannot see test code first)
Phase 3:     Builder runs sandbox tests --> Fix implementation (not tests) if failures
Phase 4:     Results in plain language, REVIEWABLE decisions flagged
Post:        Full test suite re-run --> Sandbox cleaned up
```

### How to create the plugin

1. Copy `commands/ralphtemplatetest.md` to `~/.claude/commands/`:

```bash
cp commands/ralphtemplatetest.md ~/.claude/commands/
```

2. Start a new Claude Code session.

3. Use it:

```bash
/ralphtemplatetest Build a user dashboard with real-time updates
```

4. The command will:
   - Generate a passphrase via `/dev/urandom` (Bash tool)
   - Output a complete plain-text orchestrator prompt
   - Show the passphrase separately for `--completion-promise`
   - Tell you how to feed it into `/ralph-loop`

### TESTINGOFF toggle

Add `TESTINGOFF` (case-sensitive) anywhere in your arguments to strip all testing sections and generate a 4-role prompt identical to `/ralphtemplate`:

```bash
/ralphtemplatetest Quick refactoring task TESTINGOFF
```

---

## v3 Fixes (Hybrid Architecture)

v3 replaced the marketplace plugin with local commands + a `settings.json` Stop hook. This permanently solves every known issue with the plugin approach.

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
├── ralph-loop-v3.md                       # Complete v3 setup guide (all fixes, configs)
├── CLAUDE.md                              # Project-specific Claude Code instructions
├── commands/                              # Slash commands (copy to ~/.claude/commands/)
│   ├── ralphtemplate.md                   # Generate 4-role orchestrator prompts
│   ├── ralphtemplatetest.md               # Generate 5-role prompts (adds Tester)
│   ├── ralphtemplate-v2.md                # v2: adds EVALUATOR, dynamic iterations, DOCUMENTOR
│   ├── ralphtemplatetest-v2.md            # v2: EVALUATOR + Tester + DOCUMENTOR + test preservation
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

| Command                 | Description                                                              |
| ----------------------- | ------------------------------------------------------------------------ |
| `/ralph-loop`           | Start a self-iterating development loop                                  |
| `/ralph-loop-safe`      | Same with git safety checks (feature branch required, clean working dir) |
| `/cancel-ralph`         | Cancel active loop (session-scoped, handles multi-terminal)              |
| `/ralphtemplate`        | Generate 4-role orchestrator prompt                                      |
| `/ralphtemplatetest`    | Generate 5-role prompt with test-first Tester                            |
| `/ralphtemplate-v2`     | v2: adds EVALUATOR complexity tiers, dynamic iterations, DOCUMENTOR      |
| `/ralphtemplatetest-v2` | v2: EVALUATOR + Tester + DOCUMENTOR + test preservation                  |
| `/boris-challenge`      | Challenge requirements before coding (identify 5+ ambiguities)           |
| `/grill-me`             | Staff engineer code review (scores 1-5, avg >= 4 required)               |
| `/prove-it`             | Demand evidence that changes work (natural language proof)               |
| `/knowing-everything`   | Retrospective and knowledge capture                                      |
| `/scrap-and-redo`       | Rebuild with full accumulated context                                    |

---

## Credits

- **Geoffrey Huntley** — Pioneered the Ralph Wiggum iterative loop technique ([ghuntley.com/ralph](https://ghuntley.com/ralph/))
- **Boris Cherny** — Inspired the antagonist review pattern for rigorous Claude Code development
- **Ralph Loop Plugin** — Original marketplace plugin that this project patches and extends

## License

MIT
