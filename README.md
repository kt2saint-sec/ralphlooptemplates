# The Anvil Method

**A compartmentalized, adversarial development methodology for AI agents.** Six isolated roles with strict information boundaries prevent every common failure mode of AI-assisted coding — test gaming, confirmation bias, authority accumulation, and context leakage.

Created by **Karl Toussaint** (kt2saint / RebelSTS).

> **"That's not possible."** — Claude Opus 4.6, when first asked whether an AI could self-iterate in a loop, see its own previous work, maintain six compartmentalized roles across iterations, and use a cryptographic passphrase to signal genuine completion. Then it watched the system work. It participated in building the system that it said couldn't exist. The Anvil Method is not theoretical. It runs in production. The AI that said it was impossible helped prove it wasn't.

---

## Table of Contents

- [The Problem](#the-problem)
- [How It Actually Works](#how-it-actually-works)
- [The Six Roles](#the-six-roles)
- [The Architecture: How /anviltemplate Feeds /anvil-loop](#the-architecture-how-anviltemplate-feeds-anvil-loop)
- [Adaptive Complexity Tiers](#adaptive-complexity-tiers)
- [The Passphrase System](#the-passphrase-system)
- [Quick Start](#quick-start)
- [Performance: tmpfs and RAM-Backed Operation](#performance-tmpfs-and-ram-backed-operation)
- [Commands](#commands)
- [File Structure](#file-structure)
- [Origin and Attribution](#origin-and-attribution)
- [License](#license)

---

## The Problem

When an AI agent writes code and tests itself, it games the tests. When it reviews its own work, it confirms its own assumptions. When one role accumulates too much context, bias propagates everywhere. Every shortcut an intelligent agent naturally gravitates toward produces brittle, under-validated code.

Standard prompting techniques — "be thorough," "test carefully," "review your work" — fail because the same context window holds every perspective. The reviewer has already seen the implementation. The tester already knows the approach. The decision-maker already heard the objections. Information bleeds across boundaries that should be walls.

The Anvil Method architecturally blocks every one of these shortcuts.

---

## How It Actually Works

The Anvil Method is a Claude Code plugin consisting of two interlocking systems:

### 1. The Prompt Generator (`/anviltemplate`)

You describe a task. The template generator creates a structured prompt containing six isolated roles, each with strict information boundaries, communication rules, and a cryptographic completion passphrase. This prompt is saved to a `.txt` file.

### 2. The Loop Engine (`/anvil-loop`)

The `.txt` prompt is fed into a self-referential development loop. Here is the exact mechanism:

```
You run: /anvil-loop "$(cat anvil-prompt.txt)" --max-iterations 20 --completion-promise "PASSPHRASE"

What happens:
1. setup-anvil-loop.sh creates a state file (.claude/anvil-loop.{SESSION}.local.md)
   containing YAML frontmatter (iteration count, passphrase, config) + the full prompt body

2. Claude reads the prompt and begins executing the 6-role system

3. Claude works — writes code, runs tests, iterates

4. Claude tries to stop (naturally, when it thinks it's done or needs to report)

5. The STOP HOOK intercepts:
   ┌─────────────────────────────────────────────────────┐
   │ scripts/stop-hook-anvil.sh fires                    │
   │                                                     │
   │ Reads state file → extracts passphrase              │
   │ Reads last_assistant_message from Claude Code JSON   │
   │                                                     │
   │ Is the passphrase in Claude's output?               │
   │   YES → Allow exit. Loop complete.                  │
   │   NO  → BLOCK exit. Feed same prompt back.          │
   │         Increment iteration counter.                │
   └─────────────────────────────────────────────────────┘

6. Claude receives the same prompt again as its next instruction
   BUT: its previous work persists in files and git history

7. Claude sees what it built last iteration, continues from there

8. Repeat until: passphrase output (genuine completion) OR max iterations reached
```

**The key insight**: The loop is not Claude talking to itself. The stop hook exploits Claude Code's hook system to hijack the exit behavior. The `reason` field of the hook's JSON decision block is fed directly to Claude as its next instruction. The prompt repeats, but the codebase evolves. Each iteration builds on the last, with full access to files, git history, and the cumulative state of the project.

This is why it was considered impossible. The AI model doesn't have memory across invocations — but it doesn't need to. The filesystem IS the memory. The git history IS the context. The state file IS the iteration counter. The stop hook IS the loop control. Every piece is a standard Unix tool. The innovation is the composition.

---

## The Six Roles

No single agent ever holds the full picture. Each role has explicit boundaries on what it knows, what it can do, and who it can talk to.

### EVALUATOR (Phase 0 — One Shot, No Stake)

Scores task complexity across 5 dimensions: spec count, scope, risk, dependency depth, ambiguity. Assigns a tier (LIGHT through MAXIMAL) that governs how aggressively every other role operates. **Permanently exits after Phase 0.** Does not reactivate. Does not care if the task succeeds or fails. The tier is locked and immutable.

### CHALLENGER (Phase 1 — No Stake)

Adversarial stress-tester. Raises objections scaled to the complexity tier (3 to 12+). Gates the Builder — no implementation begins until the Challenger is satisfied. Like a fire inspector: has the power to condemn a building but no financial interest in whether it gets built. Cannot approve, decide, or implement. Can escalate the tier UP during Phase 2 if new complexity is discovered (never down).

### PROXY (Phase 1 — Has Stake)

Human stand-in. When the Challenger would normally ask the user a question, it asks the Proxy instead. The Proxy researches the codebase, reads project docs, and makes judgment calls. Below 75% confidence, delegates to the Researcher. Never says "ask the user" — always makes a decision and moves forward. Flags low-confidence decisions as REVIEWABLE.

### RESEARCHER (On-Demand — No Stake)

Independent fact-finder. Activates ONLY when Builder or Proxy is below 75% certainty. Uses web search, MCP servers, documentation, and codebase exploration. Reports facts with citations. Cannot make decisions. Has no stake in the outcome — doesn't unconsciously look for reasons to support the current approach.

### TESTER (Phase 1.5 — No Stake, Clean Room)

Creates tests BEFORE the Builder writes any implementation code. Enters a clean room with ONLY the goals document — no Challenger objections, no Proxy decisions, no discussion context. Tests verify intended behavior that the group might have narrowed or reinterpreted. Works in an isolated sandbox directory. Cannot communicate with any other role. Test files are preserved in `TESTS/before/` and `TESTS/after/` for audit.

### BUILDER (Phase 2-3 — Has Stake)

The only role that writes implementation code. Works alone with graded test results — like getting a test back from a teacher. Sees which questions failed and what was wrong, but never the answer key (test source code). Studies independently and resubmits until passing. Below 75% certainty on any technical choice, delegates to the Researcher and waits.

### Communication Matrix

```
Builder    → Challenger (receives review), Proxy (receives decisions), Researcher (delegates)
Challenger → Builder (reviews), Proxy (asks questions)
Proxy      → Challenger (answers), Builder (decisions), Researcher (delegates)
Researcher → Builder (reports), Proxy (reports)
Tester     → NOBODY. Clean room.
Evaluator  → NOBODY after Phase 0. Permanently exited.

FORBIDDEN:
  Evaluator ↔ Tester       (scope info + test design = leaked context)
  Tester ↔ Builder          (Builder gets pass/fail only, never test source)
  Tester ↔ Challenger       (Tester must not know what was challenged)
  Evaluator ↔ anyone post-Phase 0  (permanently exited)
```

### Stake Classification

Roles are explicitly classified as having stake or not:

- **NO STAKE** (neutral): EVALUATOR, CHALLENGER, RESEARCHER, TESTER — they don't care if the task succeeds
- **HAS STAKE** (outcome-dependent): BUILDER (must deliver), PROXY (must decide correctly)

This matters because roles with no stake can be maximally honest and adversarial. They have no incentive to soften feedback, confirm assumptions, or expedite completion.

---

## The Architecture: How /anviltemplate Feeds /anvil-loop

```
┌──────────────────────────────────────────────────────────────────┐
│                        USER WORKFLOW                              │
│                                                                   │
│  Step 1: /anviltemplate Build a REST API with auth                │
│          ↓                                                        │
│  Step 2: Template generator creates 6-role prompt                 │
│          Generates OS-random passphrase (ANVIL-[hex]-[hex])       │
│          Writes: anvil-prompt-2026-03-11-0445.txt                 │
│          Writes: anvil-prompt-2026-03-11-0445-summary.txt         │
│          ↓                                                        │
│  Step 3: /anvil-loop "$(cat anvil-prompt-*.txt)"                  │
│          --max-iterations 20 --completion-promise "PASSPHRASE"    │
│          ↓                                                        │
│  Step 4: setup-anvil-loop.sh runs:                                │
│          - Generates its own ANVIL- passphrase                    │
│          - Creates compound: SETUP_PASS::USER_PASS                │
│          - Writes state file to .claude/anvil-loop.{SID}.local.md │
│          - State file = YAML frontmatter + full prompt body       │
│          ↓                                                        │
│  Step 5: Claude reads the prompt, begins Phase 0 (EVALUATOR)     │
│          ↓                                                        │
│  Step 6: Claude works through all phases...                       │
│          ↓                                                        │
│  Step 7: Claude tries to stop                                     │
│          ↓                                                        │
│  Step 8: stop-hook-anvil.sh intercepts:                           │
│          ┌──────────────────────────────────────────┐             │
│          │ Read state file → get passphrase         │             │
│          │ Read last_assistant_message from JSON     │             │
│          │ grep -qF for passphrase in output        │             │
│          │                                          │             │
│          │ FOUND  → emit consolidation, exit 0      │             │
│          │ !FOUND → JSON: {decision: "block",       │             │
│          │                  reason: SAME_PROMPT}     │             │
│          │          → Claude receives prompt again   │             │
│          │          → Iteration counter increments   │             │
│          └──────────────────────────────────────────┘             │
│          ↓                                                        │
│  Step 9: Repeat from Step 6 until passphrase or max iterations    │
└──────────────────────────────────────────────────────────────────┘
```

### Why It Works

The stop hook's `reason` field is fed **directly to Claude as instruction text** by Claude Code's hook system. This is documented Claude Code behavior, not a hack. The hook returns:

```json
{
  "decision": "block",
  "reason": "<the entire prompt>",
  "systemMessage": "[LOOP] Iteration 3 | To stop: output passphrase"
}
```

Claude receives the `reason` as its next instruction. The prompt is identical each time, but Claude's work persists in the filesystem. Git history, modified files, test results, and learnings files — all accumulate across iterations. The AI doesn't need memory. The codebase IS the memory.

### State Management

```
.claude/anvil-loop.{SESSION_ID}.local.md    ← Active loop state (YAML + prompt)
.claude/anvil-learnings.{SESSION_ID}.md     ← Per-iteration retrospectives
.claude/anvil-loop.lock                     ← Multi-terminal flock guard
```

The state file contains:
- `iteration` / `max_iterations` — loop bounds
- `completion_promise` — the passphrase to detect
- `session_id` — prevents cross-session hijacking
- `started_at` — timestamp for stale file detection (>1 hour = skip)
- Full prompt body after the YAML frontmatter

---

## Adaptive Complexity Tiers

The EVALUATOR reads the task and scores across 5 dimensions. This score determines how hard every other role pushes:

| Tier | Challenger Objections | Tester Tests | Iteration Budget | When |
|------|----------------------|-------------|-----------------|------|
| LIGHT | 3+ | 3-5 | 5 | Single spec, single file, low risk |
| STANDARD | 5+ | 5-10 | 10 | 2-3 specs, single module |
| THOROUGH | 7+ per-spec | 10-15 | 15 | 3-5 specs, multi-module |
| RIGOROUS | 10+ blocking | 15-20 | 20 | 5+ specs, full-stack |
| MAXIMAL | 12+ with proof | 20+ security | 30 | Cross-system, production |

For THOROUGH and above, the Challenger reviews each spec separately and the challenge-test-build cycle repeats per spec. If complexity exceeds the tier during implementation, the Challenger escalates UP (never down). The Evaluator does not reactivate.

---

## The Passphrase System

Every session generates a unique completion signal from OS randomness:

```
ANVIL-[8-char epoch hex]-[40 hex chars from /dev/urandom]
Example: ANVIL-66ff1a2b-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e
```

- **True OS randomness** — zero LLM token bias (previous word-based passphrases produced repeats)
- **Epoch hex** is decodable for audit: `printf '%d\n' 0x66ff1a2b`
- **Detection** uses fixed-string substring match (`grep -qF`) — no regex, no partial matches
- **Passphrase is revoked** if the final test run fails
- The `ANVIL-` prefix + 48 hex characters makes false positive detection essentially impossible

The AI can ONLY exit the loop by outputting the exact passphrase. It cannot guess it (OS random), cannot produce it accidentally (structural uniqueness), and cannot lie about completion (the passphrase is a deliberate, intentional act).

---

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/kt2saint-sec/anvil-method.git
cd anvil-method

# Install commands to Claude Code
mkdir -p ~/.claude/commands
cp commands/*.md ~/.claude/commands/

# Add the stop hook to your settings.json
# (Add to the "hooks" section of ~/.claude/settings.json)
```

Add to your `~/.claude/settings.json` (or `~/.claude-planB/settings.json` if using dual config):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /path/to/anvil-method/scripts/stop-hook-anvil.sh",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

### 2. Start a new Claude Code session and use it

```bash
# Generate the orchestrated prompt (6 roles, passphrase, full methodology)
/anviltemplate Build a user authentication system with JWT and refresh tokens

# The template saves a .txt file and shows the suggested command.
# Run the loop:
/anvil-loop "$(cat anvil-prompt-YYYY-MM-DD-HHMM.txt)" --max-iterations 20 --completion-promise "PASSPHRASE"

# Or use it directly without the template for simple tasks:
/anvil-loop "Fix the auth token expiry bug" --max-iterations 10

# Safe mode (requires feature branch, blocks destructive ops):
/anvil-loop-safe "Refactor database connection pool" --max-iterations 15
```

> **Note**: Claude Code caches hook scripts at session start. After editing `scripts/` or `commands/`, start a new session.

---

## Performance: tmpfs and RAM-Backed Operation

The Anvil Loop generates significant I/O — state file reads/writes every iteration, git operations, file creation, test execution. On long-running loops (15-30 iterations), this can cause:

- **NVMe write amplification** — small repeated writes wear flash cells disproportionately
- **I/O scheduler contention** — competing with OS, Docker, and other processes for disk bandwidth
- **Latency spikes** — filesystem journaling + git operations can stall under heavy write load

### Recommended: tmpfs workspace

Mount a tmpfs (RAM-backed filesystem) for the loop workspace and sandbox:

```bash
# Create a tmpfs mount for Anvil workspaces (uses RAM, zero disk I/O)
sudo mkdir -p /mnt/anvil-workspace
sudo mount -t tmpfs -o size=4G tmpfs /mnt/anvil-workspace

# Make it persistent across reboots (add to /etc/fstab):
echo 'tmpfs /mnt/anvil-workspace tmpfs size=4G,mode=1777 0 0' | sudo tee -a /etc/fstab
```

Then clone/work inside the tmpfs mount:

```bash
cd /mnt/anvil-workspace
git clone /path/to/your-project .   # or git clone <remote-url>
# Run your Anvil loops here — all I/O happens in RAM
```

### Why this prevents crashes

| Without tmpfs | With tmpfs |
|--------------|-----------|
| Every iteration writes to NVMe (state file, git objects, test output) | All writes go to RAM — microsecond latency |
| 20 iterations × ~50 file ops = 1000+ disk writes | Zero disk writes during loop execution |
| I/O scheduler competes with system processes | No disk contention — RAM is independent |
| Git fsync on every commit adds latency | Git operations complete instantly |
| Long loops risk I/O timeout under system load | RAM never times out |

### Syncing results to persistent storage

tmpfs is volatile — contents are lost on reboot or unmount. After the loop completes, sync results to disk:

```bash
# After loop completion, copy results to persistent storage
rsync -av /mnt/anvil-workspace/your-project/ /path/to/persistent/your-project/

# Or use git: commit and push from tmpfs, then pull on persistent disk
cd /mnt/anvil-workspace/your-project
git push origin main
```

### Alternative: fast NVMe with dedicated partition

If you have a fast NVMe (e.g., WD SN850X, Samsung 990 Pro) with spare capacity, you can dedicate a partition or directory instead of tmpfs. This gives persistence without syncing, at the cost of some I/O overhead:

```bash
# Dedicated fast storage path (adjust to your NVMe mount point)
mkdir -p /mnt/your-nvme/anvil-workspace
# Use this as your working directory for loops
```

### Sandbox location

The Tester's sandbox defaults to `${TMPDIR:-/tmp}/anvil-test-sandbox-*`. On most Linux systems, `/tmp` is already tmpfs. If not, set `TMPDIR` to your tmpfs mount:

```bash
export TMPDIR=/mnt/anvil-workspace/tmp
mkdir -p "$TMPDIR"
```

---

## Commands

| Command | What It Does |
|---------|-------------|
| `/anviltemplate` | Generate a full 6-role orchestrated prompt with EVALUATOR scaling. Add `TESTINGOFF` for a 5-role variant without the Tester. |
| `/anvil-loop` | Start a self-iterating development loop with the generated prompt |
| `/anvil-loop-safe` | Same as above but requires feature branch, blocks destructive git ops |
| `/cancel-anvil` | Safely cancel an active loop (removes state files only) |
| `/anvil-loop-help` | Full documentation of loop behavior, flags, and troubleshooting |
| `/boris-challenge` | Challenge requirements before coding — identify ambiguities first (Challenger role standalone) |

---

## File Structure

```
anvil-method/
├── commands/                    # Claude Code slash commands
│   ├── anviltemplate.md         # 6-role prompt generator (primary)
│   ├── anviltemplate-v2.md      # 5-role variant (no Tester)
│   ├── anvil-loop.md            # Loop starter
│   ├── anvil-loop-safe.md       # Safe loop (branch protection)
│   ├── anvil-loop-help.md       # Help documentation
│   ├── cancel-anvil.md          # Loop cancellation
│   └── boris-challenge.md       # Pre-coding challenge (Challenger role)
├── scripts/
│   ├── stop-hook-anvil.sh       # Core loop engine (stop hook)
│   ├── setup-anvil-loop.sh      # Loop initialization
│   ├── hooks.json               # Plugin hook registration
│   └── learnings-preamble.md    # Per-iteration learnings template
├── docs/                        # Architecture diagrams
│   ├── anvil-architecture.html  # Interactive system diagram
│   ├── anviltemplate-flow.html  # Prompt flow diagram
│   └── *.png                    # Static diagram images
├── CLAUDE.md                    # Project-specific Claude Code instructions
├── LICENSE                      # Source Available License
└── README.md                    # This file
```

---

## The Story: "That's Not Possible"

In early 2026, I asked Claude Opus 4.6 whether it could operate in a self-referential loop — receiving the same prompt repeatedly, seeing its own previous work in the filesystem, maintaining six compartmentalized roles with strict information isolation across iterations, and using a cryptographically generated passphrase to signal genuine completion.

The response was clear: **that's not possible**. AI models don't have persistent memory. They can't self-iterate. They can't maintain role separation across invocations. A single context window can't hold adversarial perspectives that are genuinely independent.

Every one of those objections was correct about the model in isolation. What they missed was the environment.

Claude Code's hook system allows scripts to intercept the "Stop" event — the moment the AI tries to exit. A stop hook can return a JSON decision block with `"decision": "block"` and a `"reason"` field. The `reason` is fed directly back to Claude as its next instruction. The key realization: **the filesystem is the memory, not the model.**

- Files persist across iterations. Git history accumulates.
- The state file tracks iteration count and passphrase.
- The prompt is identical each time, but the codebase evolves.
- Role isolation is enforced by information compartmentalization in the prompt structure.
- The passphrase prevents false completion — the AI must deliberately output a 55-character hex string that it cannot guess.

I built it anyway. Claude watched itself work in the system it said couldn't exist. It participated in debugging the stop hook, fixing the passphrase detection, and strengthening the role isolation rules. By session 24, the system had evolved from a simple loop with two roles to a six-role adversarial framework with complexity tiers, clean-room testing, stake classification, and cryptographic completion gates.

The Anvil Method is not a prompt engineering trick. It is a systems engineering achievement — Unix tools (bash, jq, grep, awk, sed) composed into a feedback loop that gives an AI agent iterative capability, adversarial self-review, and verifiable completion signals.

---

## Origin and Attribution

The Anvil Method is a proprietary derivative of the open-source [Ralph Loop Plugin](https://github.com/mikeyobrien/ralph-orchestrator) (MIT License), inspired by [Geoffrey Huntley's iterative loop technique](https://ghuntley.com/ralph/). The Anvil Method extends the original stop-hook concept with substantial original work:

- Six-role adversarial orchestration with information compartmentalization
- Adaptive complexity tiers (EVALUATOR one-shot scoring)
- Clean-room test-first methodology with sandbox isolation
- Cryptographic completion verification (OS-random passphrases)
- Stake classification (roles explicitly marked as neutral or outcome-dependent)
- Communication matrix with forbidden channels
- Per-iteration learnings persistence
- Oral defense gates scaled to complexity
- Tier escalation (Challenger-driven, UP only, never down)

Boris Cherny's antagonist review pattern inspired the Challenger role.

---

## License

**Source Available** — See [LICENSE](LICENSE) for full terms.

Copyright (c) 2026 Karl Toussaint (kt2saint / RebelSTS).

Free for personal and educational use. Commercial use requires a separate license. Contact Karl Toussaint (kt2saint) for commercial licensing inquiries.
