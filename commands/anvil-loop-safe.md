---
description: "Safe Anvil loop with mandatory safeguards for power-user environments"
argument-hint: "PROMPT --max-iterations N --completion-promise TEXT"
allowed-tools:
  [
    "Bash(git rev-parse --git-dir:*)",
    "Bash(git branch --show-current:*)",
    "Bash(git status --porcelain:*)",
  ]
---

# Safe Anvil Loop

## PRE-FLIGHT SAFETY CHECKS (Mandatory)

Before starting, verify ALL conditions:

### 1. Git Repository Check

```!
git rev-parse --git-dir > /dev/null 2>&1 && echo "GIT_OK" || echo "NOT_GIT_REPO"
```

**If NOT_GIT_REPO:** STOP and say "ERROR: Must run from a git repository for safe Anvil loops"

### 2. Branch Check

```!
git branch --show-current
```

**If result is "main" or "master":** STOP and say "ERROR: Cannot run Anvil loop on protected branch. Create a feature branch first with `git checkout -b feature/your-task-name`"

### 3. Clean Working Directory Check

```!
git status --porcelain
```

**If output is not empty:** WARN user about uncommitted changes before proceeding

### 4. Parameter Validation

- **REQUIRE** `--max-iterations` (reject if missing)
- **REQUIRE** `--completion-promise` (reject if missing)
- **REJECT** if `--max-iterations > 30` without explicit user confirmation

## EXECUTION

If all checks pass, delegate to official anvil-loop:

```
/anvil-loop $ARGUMENTS
```

## SAFETY RULES DURING LOOP

These commands are FORBIDDEN during Anvil loops:

- `rm -rf`, `rm -r`, `rmdir` (destructive file operations)
- `git push --force` (irreversible remote changes)
- `git reset --hard` (data loss)
- `sudo` anything (system damage potential)
- `eval`, `source` on variables (injection risk)

## EXAMPLE USAGE

```bash
# Create feature branch first
git checkout -b feature/refactor-auth

# Run safe anvil
/anvil-loop-safe "Refactor auth module to use JWT. Tests must pass." \
  --max-iterations 20 \
  --completion-promise "AUTH_REFACTORED"

# Review changes after completion
git diff main
```

## CANCELLATION

To cancel an active Anvil loop:

```
/cancel-anvil
```
