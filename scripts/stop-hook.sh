#!/bin/bash

# Ralph Loop Stop Hook
# Prevents session exit when a ralph-loop is active
# Feeds Claude's output back as input to continue the loop
# Supports per-iteration learnings capture and completion consolidation

set -euo pipefail

# Fast exit: check for state files BEFORE reading stdin to minimize
# latency when no ralph loop is active (Bug 5 fix)
# Two patterns: ralph-loop.local.md (original plugin) and ralph-loop.*.local.md (our version)
# NOTE: ralph-loop.loca[l].md uses a char class so nullglob applies (literal paths bypass nullglob)
shopt -s nullglob
_state_files=(.claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md)
shopt -u nullglob
if [[ ${#_state_files[@]} -eq 0 ]]; then
  exit 0
fi
unset _state_files

# Read hook input from stdin (Stop hook JSON API)
HOOK_INPUT=$(cat)

# DEBUG: Dump raw hook JSON for live field verification (remove after confirming fields)
# Uncomment next 2 lines, sync cache, start NEW session, run /ralph-loop, inspect output
# echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> /tmp/ralph-hook-debug.json
# echo "$HOOK_INPUT" >> /tmp/ralph-hook-debug.json

# Extract fields from hook input JSON
# session_id: definitive session identifier (replaces ls -t heuristic for multi-terminal)
# last_assistant_message: Claude's final response text (replaces transcript parsing)
# stop_hook_active: true when continuing from a prior Stop hook block
# NOTE on stop_hook_active: intentionally NOT used as an exit guard because Ralph Loop
# works by repeatedly blocking stop events. On iteration 2+, stop_hook_active is always
# true — that's expected behavior. Using it as an exit guard would kill the loop.
# RESOLVED: Confirmed correct. Fallback paths handle any future semantic changes.
HOOK_SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
LAST_ASSISTANT_MSG=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')

# --- State file lookup ---
# Primary: direct lookup by hook session_id (O(1), multi-terminal safe)
# Fallback: glob + ls -t (handles first iteration when setup used uuidgen)
# On fallback, rename file to hook session_id for O(1) on subsequent iterations.
RALPH_STATE_FILE=""

if [[ -n "$HOOK_SESSION_ID" ]] && [[ -f ".claude/ralph-loop.${HOOK_SESSION_ID}.local.md" ]]; then
  RALPH_STATE_FILE=".claude/ralph-loop.${HOOK_SESSION_ID}.local.md"
fi

if [[ -z "$RALPH_STATE_FILE" ]]; then
  shopt -s nullglob
  _found_files=(.claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md)
  shopt -u nullglob

  if [[ ${#_found_files[@]} -eq 0 ]]; then
    exit 0
  fi

  if [[ ${#_found_files[@]} -eq 1 ]]; then
    RALPH_STATE_FILE="${_found_files[0]}"
  else
    RALPH_STATE_FILE=$(ls -t .claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md 2>/dev/null | head -1)
  fi
  unset _found_files

  # Rename to hook session_id for O(1) lookup on subsequent iterations
  # Uses flock to prevent race condition when multiple terminals hit glob fallback simultaneously
  if [[ -n "$HOOK_SESSION_ID" ]] && [[ -n "$RALPH_STATE_FILE" ]] && [[ -f "$RALPH_STATE_FILE" ]]; then
    NEW_STATE_FILE=".claude/ralph-loop.${HOOK_SESSION_ID}.local.md"
    if [[ "$RALPH_STATE_FILE" != "$NEW_STATE_FILE" ]]; then
      (
        flock -n 9 || exit 0  # Skip rename if another process holds the lock
        # Re-check file still exists after acquiring lock (another process may have renamed it)
        if [[ -f "$RALPH_STATE_FILE" ]]; then
          OLD_SID=$(basename "$RALPH_STATE_FILE" | sed -E 's/^ralph-loop\.(.+)\.local\.md$/\1/; t; s/^ralph-loop\.local\.md$//')
          mv "$RALPH_STATE_FILE" "$NEW_STATE_FILE"
          # Update frontmatter session_id to match new filename
          TEMP_FILE="${NEW_STATE_FILE}.tmp.$$"
          sed "s/^session_id: \"${OLD_SID}\"/session_id: \"${HOOK_SESSION_ID}\"/" "$NEW_STATE_FILE" > "$TEMP_FILE"
          mv "$TEMP_FILE" "$NEW_STATE_FILE"
          # Rename learnings file if it exists
          if [[ -f ".claude/ralph-learnings.${OLD_SID}.md" ]]; then
            mv ".claude/ralph-learnings.${OLD_SID}.md" ".claude/ralph-learnings.${HOOK_SESSION_ID}.md"
          fi
        fi
      ) 9>.claude/ralph-loop.lock
      # Update RALPH_STATE_FILE if rename succeeded
      if [[ -f "$NEW_STATE_FILE" ]]; then
        RALPH_STATE_FILE="$NEW_STATE_FILE"
      fi
    fi
  fi
fi

if [[ -z "$RALPH_STATE_FILE" ]] || [[ ! -f "$RALPH_STATE_FILE" ]]; then
  exit 0
fi

# Extract session ID from filename for learnings file
SESSION_ID=$(basename "$RALPH_STATE_FILE" | sed -E 's/^ralph-loop\.(.+)\.local\.md$/\1/; t; s/^ralph-loop\.local\.md$//')
LEARNINGS_FILE=".claude/ralph-learnings.${SESSION_ID}.md"

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
# Extract completion_promise and strip surrounding quotes if present
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
# Extract learnings_enabled (default: false if not present)
LEARNINGS_ENABLED=$(echo "$FRONTMATTER" | grep '^learnings_enabled:' | sed 's/learnings_enabled: *//' || echo "false")
if [[ -z "$LEARNINGS_ENABLED" ]]; then
  LEARNINGS_ENABLED="false"
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

After consolidation, output '${COMPLETION_PROMISE}' on its own line to signal final completion."
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

# --- Get last assistant output ---
# Primary: last_assistant_message from hook JSON (no parsing needed)
# Fallback: transcript parsing (for older Claude Code versions)
LAST_OUTPUT=""

if [[ -n "$LAST_ASSISTANT_MSG" ]]; then
  LAST_OUTPUT="$LAST_ASSISTANT_MSG"
else
  # Fallback: parse transcript JSONL
  if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
    if grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
      LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
      if [[ -n "$LAST_LINE" ]]; then
        LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
          .message.content |
          map(select(.type == "text")) |
          map(.text) |
          join("\n")
        ' 2>/dev/null || echo "")
      fi
    fi
  fi
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "⚠️  Ralph loop: No assistant output found (neither hook JSON nor transcript)" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Detection: check if the promise text appears on its own line.
  # Uses plain-text exact-line matching (grep -Fx). XML tags are stripped
  # by Claude Code's rendering pipeline, so only plain text works here.
  if echo "$LAST_OUTPUT" | grep -qFx "$COMPLETION_PROMISE"; then
    emit_consolidation_and_exit "✅ Ralph loop: Completion promise detected: $COMPLETION_PROMISE"
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the SECOND --- line, which closes frontmatter)
# Only skip the first two --- lines; preserve all subsequent --- lines as content
PROMPT_TEXT=$(awk '/^---$/ && fm_count<2 {fm_count++; next} fm_count>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: State file corrupted or incomplete" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     - State file was manually edited" >&2
  echo "     - File was corrupted during writing" >&2
  echo "" >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Prepend minimal learnings preamble on iterations 2+ (if learnings enabled)
if [[ "$LEARNINGS_ENABLED" == "true" ]] && [[ $ITERATION -gt 1 ]]; then
  LEARNINGS_PREAMBLE="[Iteration ${ITERATION}] Append 2-3 lines to ${LEARNINGS_FILE} (what worked/failed, key insight). Then continue:

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
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop: output '$COMPLETION_PROMISE' on its own line (ONLY when genuinely complete)"
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
