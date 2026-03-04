#!/bin/bash

# Ralph Loop Stop Hook
# Prevents session exit when a ralph-loop is active
# Feeds Claude's output back as input to continue the loop
# Supports per-iteration learnings capture and completion consolidation

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Session-scoped state file to prevent cross-terminal contamination
# Uses CLAUDE_SESSION_ID if available, falls back to PPID
SESSION_ID="${CLAUDE_SESSION_ID:-$PPID}"
RALPH_STATE_FILE=".claude/ralph-loop.${SESSION_ID}.local.md"
LEARNINGS_FILE=".claude/ralph-learnings.${SESSION_ID}.md"

# Also check legacy non-scoped file and skip it (belongs to another session)
if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # No active loop for THIS session - allow exit
  exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
# Extract completion_promise and strip surrounding quotes if present
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
# Extract learnings_enabled (default: true if not present)
LEARNINGS_ENABLED=$(echo "$FRONTMATTER" | grep '^learnings_enabled:' | sed 's/learnings_enabled: *//' || echo "true")
if [[ -z "$LEARNINGS_ENABLED" ]]; then
  LEARNINGS_ENABLED="true"
fi

# Validate numeric fields before arithmetic operations
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# --- Completion consolidation helper ---
# When the loop is done (promise met or max iterations), instead of silently
# exiting, inject a final "consolidate learnings" prompt if learnings were enabled.
emit_consolidation_and_exit() {
  local EXIT_REASON="$1"

  # If learnings disabled or no learnings file exists, just clean up and exit
  if [[ "$LEARNINGS_ENABLED" != "true" ]] || [[ ! -f "$LEARNINGS_FILE" ]]; then
    echo "$EXIT_REASON"
    rm -f "$RALPH_STATE_FILE"
    exit 0
  fi

  # Build consolidation prompt
  local CONSOLIDATION_PROMPT
  CONSOLIDATION_PROMPT=$(cat <<'CONSOLIDATE_EOF'
RALPH LOOP COMPLETE - Final consolidation step:

You have accumulated iteration learnings during this ralph loop session.
Perform these consolidation steps before finishing:

1. Read the learnings file at LEARNINGS_FILE_PLACEHOLDER
2. Extract DURABLE patterns (not session-specific noise) — things that would help future sessions
3. If the project has a LEARNINGS.md, APPEND any genuinely useful findings (do NOT delete or overwrite existing content)
4. Update your auto-memory MEMORY.md with key architectural or workflow findings
5. If any findings warrant CLAUDE.md updates (new commands, gotchas, patterns), add them concisely — one line per concept
6. Delete ONLY the temporary learnings file: LEARNINGS_FILE_PLACEHOLDER
   - Do NOT delete LEARNINGS.md (permanent project docs)
   - Do NOT delete CLAUDE.md (permanent project context)
7. Then output your completion summary
CONSOLIDATE_EOF
)
  # Replace placeholder with actual learnings file path
  CONSOLIDATION_PROMPT="${CONSOLIDATION_PROMPT//LEARNINGS_FILE_PLACEHOLDER/$LEARNINGS_FILE}"

  # If there was a completion promise, include it in the consolidation prompt
  # so Claude can re-emit it after consolidation and the next hook check exits cleanly
  if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
    CONSOLIDATION_PROMPT="${CONSOLIDATION_PROMPT}

After consolidation, output <promise>${COMPLETION_PROMISE}</promise> to signal final completion."
  fi

  # Mark state as consolidating so the NEXT stop-hook invocation knows to exit
  local TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
  if grep -q '^consolidating:' "$RALPH_STATE_FILE"; then
    # Already consolidating — this is the second pass, exit cleanly
    echo "$EXIT_REASON"
    rm -f "$RALPH_STATE_FILE"
    rm -f "$LEARNINGS_FILE"  # Clean up if Claude didn't
    exit 0
  fi

  # Add consolidating flag to frontmatter
  sed "s/^active: true/active: true\nconsolidating: true/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$RALPH_STATE_FILE"

  echo "$EXIT_REASON (consolidating learnings...)" >&2

  # Block exit and inject consolidation prompt
  jq -n \
    --arg prompt "$CONSOLIDATION_PROMPT" \
    --arg msg "📝 Ralph loop: Consolidating learnings before exit" \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'
  exit 0
}

# Check if we're in consolidation mode (second pass after consolidation prompt)
CONSOLIDATING=$(echo "$FRONTMATTER" | grep '^consolidating:' | sed 's/consolidating: *//' || echo "false")
if [[ "$CONSOLIDATING" == "true" ]]; then
  echo "✅ Ralph loop: Consolidation complete. Exiting."
  rm -f "$RALPH_STATE_FILE"
  rm -f "$LEARNINGS_FILE"  # Clean up if Claude didn't
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  emit_consolidation_and_exit "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Ralph loop: Transcript file not found" >&2
  echo "   Expected: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a Claude Code internal issue." >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Read last assistant message from transcript (JSONL format - one JSON per line)
# First check if there are any assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  Ralph loop: No assistant messages found in transcript" >&2
  echo "   Transcript: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Extract last assistant message with explicit error handling
LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
if [[ -z "$LAST_LINE" ]]; then
  echo "⚠️  Ralph loop: Failed to extract last assistant message" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Parse JSON with error handling
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
  .message.content |
  map(select(.type == "text")) |
  map(.text) |
  join("\n")
' 2>&1)

# Check if jq succeeded
if [[ $? -ne 0 ]]; then
  echo "⚠️  Ralph loop: Failed to parse assistant message JSON" >&2
  echo "   Error: $LAST_OUTPUT" >&2
  echo "   This may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "⚠️  Ralph loop: Assistant message contained no text content" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Extract text from <promise> tags using Perl for multiline support
  # -0777 slurps entire input, s flag makes . match newlines
  # .*? is non-greedy (takes FIRST tag), whitespace normalized
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  # Use = for literal string comparison (not pattern matching)
  # == in [[ ]] does glob pattern matching which breaks with *, ?, [ characters
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    emit_consolidation_and_exit "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
# Skip first --- line, skip until second --- line, then print everything after
# Use i>=2 instead of i==2 to handle --- in prompt content
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: State file corrupted or incomplete" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     • State file was manually edited" >&2
  echo "     • File was corrupted during writing" >&2
  echo "" >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Prepend learnings preamble on iterations 2+ (if learnings enabled)
if [[ "$LEARNINGS_ENABLED" == "true" ]] && [[ $ITERATION -gt 1 ]]; then
  LEARNINGS_PREAMBLE="BEFORE continuing your task, perform a 30-second retrospective:

1. Read ${LEARNINGS_FILE} (create if missing)
2. Append a brief entry for iteration ${ITERATION}:
   - What was attempted
   - What worked / what failed
   - Key gotcha or pattern discovered (if any)
   - What to do differently next iteration
3. Keep each entry to 3-5 lines max. Do NOT rewrite previous entries.
4. Then continue with your task below.

---

"
  PROMPT_TEXT="${LEARNINGS_PREAMBLE}${PROMPT_TEXT}"
fi

# Update iteration in frontmatter (portable across macOS and Linux)
# Create temp file, then atomically replace
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message with iteration count and completion promise info
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when statement is TRUE - do not lie to exit!)"
else
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Add learnings reminder to system message
if [[ "$LEARNINGS_ENABLED" == "true" ]]; then
  SYSTEM_MSG="${SYSTEM_MSG} | 📝 Learnings: ${LEARNINGS_FILE}"
fi

# Output JSON to block the stop and feed prompt back
# The "reason" field contains the prompt that will be sent back to Claude
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

# Exit 0 for successful hook execution
exit 0
