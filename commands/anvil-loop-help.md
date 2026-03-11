---
description: "Explain Anvil Loop plugin and available commands"
---

# Anvil Loop Plugin Help

Please explain the following to the user:

## What is Anvil Loop?

Anvil Loop implements the iterative loop technique - an iterative development methodology based on continuous AI loops, pioneered by Geoffrey Huntley.

**Core concept:**

```bash
while :; do
  cat PROMPT.md | claude-code --continue
done
```

The same prompt is fed to Claude repeatedly. The "self-referential" aspect comes from Claude seeing its own previous work in the files and git history, not from feeding output back as input.

**Each iteration:**

1. Claude receives the SAME prompt
2. Works on the task, modifying files
3. Tries to exit
4. Stop hook intercepts and feeds the same prompt again
5. Claude sees its previous work in the files
6. Iteratively improves until completion

The technique is described as "deterministically bad in an undeterministic world" - failures are predictable, enabling systematic improvement through prompt tuning.

## Available Commands

### /anvil-loop <PROMPT> [OPTIONS]

Start a Anvil loop in your current session.

**Usage:**

```
/anvil-loop "Refactor the cache layer" --max-iterations 20
/anvil-loop "Add tests" --completion-promise "TESTS COMPLETE"
```

**Options:**

- `--max-iterations <n>` - Max iterations before auto-stop
- `--completion-promise <text>` - Promise phrase to signal completion

**How it works:**

1. Creates `.claude/anvil-loop.{SESSION_ID}.local.md` state file
2. You work on the task
3. When you try to exit, stop hook intercepts
4. Same prompt fed back
5. You see your previous work
6. Continues until promise detected or max iterations

---

### /cancel-anvil

Cancel an active Anvil loop (removes the loop state file).

**Usage:**

```
/cancel-anvil
```

**How it works:**

- Checks for active loop state file
- Removes `.claude/anvil-loop.{SESSION_ID}.local.md`
- Reports cancellation with iteration count

---

## Key Concepts

### Completion Passphrases

A unique passphrase (ANVIL- prefix + 48 hex chars from /dev/urandom) is auto-generated for every session. If you provide `--completion-promise "DONE"`, the actual completion signal becomes `PASSPHRASE::DONE`. Output the passphrase on its own line when genuinely complete.

The passphrase system prevents false positives from common words appearing in code output. Without `--max-iterations` or `--completion-promise`, Anvil runs infinitely.

### Self-Reference Mechanism

The "loop" doesn't mean Claude talks to itself. It means:

- Same prompt repeated
- Claude's work persists in files
- Each iteration sees previous attempts
- Builds incrementally toward goal

## Example

### Interactive Bug Fix

```
/anvil-loop "Fix the token refresh logic in auth.ts." --completion-promise "ALL TESTS PASSING" --max-iterations 10
```

You'll see Anvil:

- Attempt fixes
- Run tests
- See failures
- Iterate on solution
- In your current session

## When to Use Anvil

**Good for:**

- Well-defined tasks with clear success criteria
- Tasks requiring iteration and refinement
- Iterative development with self-correction
- Greenfield projects

**Not good for:**

- Tasks requiring human judgment or design decisions
- One-shot operations
- Tasks with unclear success criteria
- Debugging production issues (use targeted debugging instead)

## Learn More

- Original technique: https://ghuntley.com/ralph/ (Ralph Wiggum loop by Geoffrey Huntley)
- Original plugin: https://github.com/mikeyobrien/ralph-orchestrator (MIT License)
