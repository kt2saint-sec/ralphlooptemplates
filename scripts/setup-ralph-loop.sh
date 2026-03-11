#!/bin/bash

# Ralph Loop Setup Script
# Creates state file for in-session Ralph loop

set -euo pipefail

# Parse arguments
PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE="null"
LEARNINGS_ENABLED="true"

# Parse options and positional arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Ralph Loop - Interactive self-referential development loop

USAGE:
  /ralph-loop [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Initial prompt to start the loop (can be multiple words without quotes)

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: unlimited)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  --no-learnings                 Disable per-iteration learnings capture
  -h, --help                     Show this help message

DESCRIPTION:
  Starts a Ralph Loop in your CURRENT session. The stop hook prevents
  exit and feeds your output back as input until completion or iteration limit.

  A unique passphrase is auto-generated for completion detection.
  Output the passphrase on its own line when genuinely done.

  Use this for:
  - Interactive iteration where you want to see progress
  - Tasks requiring self-correction and refinement
  - Learning how Ralph works

EXAMPLES:
  /ralph-loop Build a todo API --completion-promise 'DONE' --max-iterations 20
  /ralph-loop --max-iterations 10 Fix the auth bug
  /ralph-loop Refactor cache layer  (runs forever)
  /ralph-loop --completion-promise 'TASK COMPLETE' Create a REST API

STOPPING:
  Only by reaching --max-iterations or detecting --completion-promise
  No manual stop - Ralph runs infinitely by default!

MONITORING:
  # View current iteration:
  grep '^iteration:' .claude/ralph-loop.*.local.md

  # View full state:
  head -10 .claude/ralph-loop.*.local.md
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Error: --max-iterations requires a number argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   You provided: --max-iterations (with no number)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] Error: --max-iterations must be a positive integer or 0, got: $2" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   Invalid: decimals (10.5), negative numbers (-5), text" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Error: --completion-promise requires a text argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --completion-promise 'DONE'" >&2
        echo "     --completion-promise 'TASK COMPLETE'" >&2
        echo "     --completion-promise 'All tests passing'" >&2
        echo "" >&2
        echo "   You provided: --completion-promise (with no text)" >&2
        echo "" >&2
        echo "   Note: Multi-word promises must be quoted!" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --no-learnings)
      LEARNINGS_ENABLED="false"
      shift
      ;;
    *)
      # Non-option argument - collect all as prompt parts
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

# Join all prompt parts with spaces
PROMPT="${PROMPT_PARTS[*]}"

# Validate prompt is non-empty
if [[ -z "$PROMPT" ]]; then
  echo "[ERROR] Error: No prompt provided" >&2
  echo "" >&2
  echo "   Ralph needs a task description to work on." >&2
  echo "" >&2
  echo "   Examples:" >&2
  echo "     /ralph-loop Build a REST API for todos" >&2
  echo "     /ralph-loop Fix the auth bug --max-iterations 20" >&2
  echo "     /ralph-loop --completion-promise 'DONE' Refactor code" >&2
  echo "" >&2
  echo "   For all options: /ralph-loop --help" >&2
  exit 1
fi

# --- Passphrase generation for completion promise ---
# v3: Epoch hex (8 chars) provides structural temporal uniqueness + debuggability.
# Random hex (40 chars) from /dev/urandom provides probabilistic uniqueness (2^160).
# RALPH- prefix prevents false matches against hex strings in code output.
# v2 was RALPH-hex48. v1 was WORD NNNN (deprecated session 15, LLM bias).
generate_passphrase() {
  echo "RALPH-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')"
}

# Generate passphrase and build completion promise
PASSPHRASE=$(generate_passphrase)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # User provided a promise -- prepend passphrase with :: separator
  COMPLETION_PROMISE="${PASSPHRASE}::${COMPLETION_PROMISE}"
else
  # No user promise -- use passphrase alone as the completion signal
  COMPLETION_PROMISE="$PASSPHRASE"
fi

# Create state file for stop hook (markdown with YAML frontmatter)
# Session-scoped to prevent cross-terminal contamination
mkdir -p .claude

# Generate a reliable session ID:
# 1. CLAUDE_SESSION_ID (if Claude Code provides it)
# 2. Fallback: short unique ID from uuidgen or /proc/sys/kernel/random/uuid
# Note: PPID is unreliable because setup and stop-hook run as different processes
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  SESSION_ID="$CLAUDE_SESSION_ID"
else
  SESSION_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-$(date +%s%N)")"
  # Use short form (first 12 chars) to keep filename readable
  SESSION_ID="${SESSION_ID:0:12}"
fi
RALPH_STATE_FILE=".claude/ralph-loop.${SESSION_ID}.local.md"

# Verify session ID is non-empty (defensive)
if [[ -z "$SESSION_ID" ]]; then
  echo "[ERROR] Error: Failed to generate session ID" >&2
  exit 1
fi

# Quote completion promise for YAML if it contains special chars or is not null
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

cat > "$RALPH_STATE_FILE" <<EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
learnings_enabled: $LEARNINGS_ENABLED
session_id: "$SESSION_ID"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

# Output setup message
cat <<EOF
[LOOP] Ralph loop activated in this session!

Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)
Completion passphrase: ${COMPLETION_PROMISE//\"/} (ONLY output when TRUE)
Learnings: $(if [[ "$LEARNINGS_ENABLED" == "true" ]]; then echo "enabled (captures per-iteration retrospectives)"; else echo "disabled"; fi)

The stop hook is now active. When you try to exit, the SAME PROMPT will be
fed back to you. You'll see your previous work in files, creating a
self-referential loop where you iteratively improve on the same task.

Session ID: $SESSION_ID
To monitor: head -10 $RALPH_STATE_FILE

[WARN]  WARNING: This loop continues until the passphrase is output or
    --max-iterations is reached.

[LOOP]
EOF

# Output the initial prompt if provided
if [[ -n "$PROMPT" ]]; then
  echo ""
  echo "$PROMPT"
fi

# Display completion passphrase (always set now due to auto-generation)
if [[ "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "YOUR COMPLETION PASSPHRASE IS"
  echo "  $COMPLETION_PROMISE"
  echo ""
  echo "Output this EXACT text on its own line when the task is genuinely complete."
  echo "Do NOT output it to escape the loop if the task is not done."
fi
