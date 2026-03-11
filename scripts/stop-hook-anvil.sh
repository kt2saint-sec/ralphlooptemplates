#!/bin/bash

# Anvil Loop Stop Hook
# Prevents session exit when a anvil-loop is active
# Feeds Claude's output back as input to continue the loop
# Supports per-iteration learnings capture and completion consolidation

set -uo pipefail

# Fast exit: check for state files BEFORE reading stdin to minimize
# latency when no anvil loop is active (Bug 5 fix)
# Two patterns: anvil-loop.local.md (original plugin) and anvil-loop.*.local.md (our version)
# NOTE: anvil-loop.loca[l].md uses a char class so nullglob applies (literal paths bypass nullglob)
shopt -s nullglob
_state_files=(.claude/anvil-loop.loca[l].md .claude/anvil-loop.*.local.md)
shopt -u nullglob
if [[ ${#_state_files[@]} -eq 0 ]]; then
  exit 0
fi
unset _state_files

# Read hook input from stdin (Stop hook JSON API)
HOOK_INPUT=$(cat)

# DEBUG: Dump raw hook JSON for live field verification (remove after confirming fields)
# Uncomment next 2 lines, sync cache, start NEW session, run /anvil-loop, inspect output
# echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> /tmp/anvil-hook-debug.json
# echo "$HOOK_INPUT" >> /tmp/anvil-hook-debug.json

# Extract fields from hook input JSON
# session_id: definitive session identifier (replaces ls -t heuristic for multi-terminal)
# last_assistant_message: Claude's final response text (replaces transcript parsing)
# stop_hook_active: true when continuing from a prior Stop hook block
# NOTE on stop_hook_active: intentionally NOT used as an exit guard because Anvil Loop
# works by repeatedly blocking stop events. On iteration 2+, stop_hook_active is always
# true -- that's expected behavior. Using it as an exit guard would kill the loop.
# RESOLVED: Confirmed correct. Fallback paths handle any future semantic changes.
HOOK_SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
LAST_ASSISTANT_MSG=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')

# --- State file lookup ---
# Primary: direct lookup by hook session_id (O(1), multi-terminal safe)
# Fallback: glob + ls -t (handles first iteration when setup used uuidgen)
# On fallback, rename file to hook session_id for O(1) on subsequent iterations.
ANVIL_STATE_FILE=""

if [[ -n "$HOOK_SESSION_ID" ]] && [[ -f ".claude/anvil-loop.${HOOK_SESSION_ID}.local.md" ]]; then
  ANVIL_STATE_FILE=".claude/anvil-loop.${HOOK_SESSION_ID}.local.md"
fi

if [[ -z "$ANVIL_STATE_FILE" ]]; then
  shopt -s nullglob
  _found_files=(.claude/anvil-loop.loca[l].md .claude/anvil-loop.*.local.md)
  shopt -u nullglob

  if [[ ${#_found_files[@]} -eq 0 ]]; then
    exit 0
  fi

  if [[ ${#_found_files[@]} -eq 1 ]]; then
    ANVIL_STATE_FILE="${_found_files[0]}"
  else
    ANVIL_STATE_FILE=$(ls -t .claude/anvil-loop.loca[l].md .claude/anvil-loop.*.local.md 2>/dev/null | head -1)
  fi
  unset _found_files

  # Guard against cross-session hijacking: if the state file belongs to a
  # different session, only adopt it if it was created very recently (< 120s),
  # which indicates it's from the setup script's first iteration using uuidgen.
  # Files older than 120s from different sessions are orphaned and must be skipped.
  if [[ -n "$HOOK_SESSION_ID" ]] && [[ -n "$ANVIL_STATE_FILE" ]] && [[ -f "$ANVIL_STATE_FILE" ]]; then
    FILE_SID=$(sed -n 's/^session_id: "\(.*\)"/\1/p' "$ANVIL_STATE_FILE")
    FILE_STARTED=$(sed -n 's/^started_at: "\(.*\)"/\1/p' "$ANVIL_STATE_FILE")
    # If session_id is missing or doesn't match, check age before adopting
    if [[ -z "$FILE_SID" ]] || [[ "$FILE_SID" != "$HOOK_SESSION_ID" ]]; then
      FILE_AGE_S=$(date -d "$FILE_STARTED" +%s 2>/dev/null || echo 0)
      FILE_AGE=$(( $(date +%s) - FILE_AGE_S ))
      if [[ $FILE_AGE -gt 120 ]]; then
        echo "[WARN] Orphaned anvil loop state file from a different session (age: ${FILE_AGE}s). Skipping." >&2
        echo "   File: $ANVIL_STATE_FILE" >&2
        echo "   Run /cancel-anvil to clean up, or /anvil-loop to start fresh." >&2
        exit 0
      fi
    fi
  fi

  # Rename to hook session_id for O(1) lookup on subsequent iterations
  # Uses flock to prevent race condition when multiple terminals hit glob fallback simultaneously
  if [[ -n "$HOOK_SESSION_ID" ]] && [[ -n "$ANVIL_STATE_FILE" ]] && [[ -f "$ANVIL_STATE_FILE" ]]; then
    NEW_STATE_FILE=".claude/anvil-loop.${HOOK_SESSION_ID}.local.md"
    if [[ "$ANVIL_STATE_FILE" != "$NEW_STATE_FILE" ]]; then
      (
        flock -n 9 || exit 0  # Skip rename if another process holds the lock
        # Re-check file still exists after acquiring lock (another process may have renamed it)
        if [[ -f "$ANVIL_STATE_FILE" ]]; then
          OLD_SID=$(basename "$ANVIL_STATE_FILE" | sed -E 's/^anvil-loop\.(.+)\.local\.md$/\1/; t; s/^anvil-loop\.local\.md$//')
          mv "$ANVIL_STATE_FILE" "$NEW_STATE_FILE"
          # Update frontmatter session_id to match new filename
          TEMP_FILE="${NEW_STATE_FILE}.tmp.$$"
          sed "s/^session_id: \"${OLD_SID}\"/session_id: \"${HOOK_SESSION_ID}\"/" "$NEW_STATE_FILE" > "$TEMP_FILE"
          mv "$TEMP_FILE" "$NEW_STATE_FILE"
          # Rename learnings file if it exists
          if [[ -f ".claude/anvil-learnings.${OLD_SID}.md" ]]; then
            mv ".claude/anvil-learnings.${OLD_SID}.md" ".claude/anvil-learnings.${HOOK_SESSION_ID}.md"
          fi
        fi
      ) 9>.claude/anvil-loop.lock
      # Update ANVIL_STATE_FILE if rename succeeded
      if [[ -f "$NEW_STATE_FILE" ]]; then
        ANVIL_STATE_FILE="$NEW_STATE_FILE"
      fi
    fi
  fi
fi

if [[ -z "$ANVIL_STATE_FILE" ]] || [[ ! -f "$ANVIL_STATE_FILE" ]]; then
  exit 0
fi

# Extract session ID from filename for learnings file
SESSION_ID=$(basename "$ANVIL_STATE_FILE" | sed -E 's/^anvil-loop\.(.+)\.local\.md$/\1/; t; s/^anvil-loop\.local\.md$//')
LEARNINGS_FILE=".claude/anvil-learnings.${SESSION_ID}.md"

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$ANVIL_STATE_FILE")
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
  echo "[WARN]  Anvil loop: State file corrupted" >&2
  echo "   File: $ANVIL_STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Anvil loop is stopping. Run /anvil-loop again to start fresh." >&2
  rm "$ANVIL_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "[WARN]  Anvil loop: State file corrupted" >&2
  echo "   File: $ANVIL_STATE_FILE" >&2
  echo "   Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Anvil loop is stopping. Run /anvil-loop again to start fresh." >&2
  rm "$ANVIL_STATE_FILE"
  exit 0
fi

# --- Completion consolidation helper ---
# When the loop is done (promise met or max iterations), instead of silently
# exiting, inject a final "consolidate learnings" prompt if learnings were enabled.
emit_consolidation_and_exit() {
  local EXIT_REASON="$1"

  # If learnings disabled or no learnings file exists, just clean up and exit
  if [[ "$LEARNINGS_ENABLED" != "true" ]] || [[ ! -f "$LEARNINGS_FILE" ]]; then
    echo "$EXIT_REASON" >&2
    rm -f "$ANVIL_STATE_FILE"
    exit 0
  fi

  # Build consolidation prompt
  local CONSOLIDATION_PROMPT
  CONSOLIDATION_PROMPT=$(cat <<'CONSOLIDATE_EOF'
ANVIL LOOP COMPLETE - Final consolidation step:

You have accumulated iteration learnings during this anvil loop session.
Perform these consolidation steps before finishing:

1. Read the learnings file at LEARNINGS_FILE_PLACEHOLDER
2. Extract DURABLE patterns (not session-specific noise) -- things that would help future sessions
3. If the project has a LEARNINGS.md, APPEND any genuinely useful findings (do NOT delete or overwrite existing content)
4. Update your auto-memory MEMORY.md with key architectural or workflow findings
5. If any findings warrant CLAUDE.md updates (new commands, gotchas, patterns), add them concisely -- one line per concept
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
  local TEMP_FILE="${ANVIL_STATE_FILE}.tmp.$$"
  if grep -q '^consolidating:' "$ANVIL_STATE_FILE"; then
    # Already consolidating -- this is the second pass, exit cleanly
    echo "$EXIT_REASON" >&2
    rm -f "$ANVIL_STATE_FILE"
    rm -f "$LEARNINGS_FILE"  # Clean up if Claude didn't
    exit 0
  fi

  # Add consolidating flag to frontmatter
  sed "s/^active: true/active: true\nconsolidating: true/" "$ANVIL_STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$ANVIL_STATE_FILE"

  echo "$EXIT_REASON (consolidating learnings...)" >&2

  # Block exit and inject consolidation prompt
  jq -n \
    --arg prompt "$CONSOLIDATION_PROMPT" \
    --arg msg "[NOTE] Anvil loop: Consolidating learnings before exit" \
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
  echo "[OK] Anvil loop: Consolidation complete. Exiting." >&2
  rm -f "$ANVIL_STATE_FILE"
  rm -f "$LEARNINGS_FILE"  # Clean up if Claude didn't
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  emit_consolidation_and_exit "[STOP] Anvil loop: Max iterations ($MAX_ITERATIONS) reached."
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

# Strip ANSI escape codes that could prevent passphrase matching
LAST_OUTPUT=$(echo "$LAST_OUTPUT" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "[WARN]  Anvil loop: No assistant output found (neither hook JSON nor transcript)" >&2
  echo "   Anvil loop is stopping." >&2
  rm "$ANVIL_STATE_FILE"
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Detection: check if the promise text appears anywhere in output.
  # Uses fixed-string substring match (grep -F). The ANVIL- prefix + 48 hex
  # chars makes false positives essentially impossible, so exact-line (-x)
  # matching is unnecessarily strict and fails when passphrase is embedded in text.
  if echo "$LAST_OUTPUT" | grep -qF "$COMPLETION_PROMISE"; then
    emit_consolidation_and_exit "[OK] Anvil loop: Completion promise detected: $COMPLETION_PROMISE"
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the SECOND --- line, which closes frontmatter)
# Only skip the first two --- lines; preserve all subsequent --- lines as content
PROMPT_TEXT=$(awk '/^---$/ && fm_count<2 {fm_count++; next} fm_count>=2' "$ANVIL_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "[WARN]  Anvil loop: State file corrupted or incomplete" >&2
  echo "   File: $ANVIL_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     - State file was manually edited" >&2
  echo "     - File was corrupted during writing" >&2
  echo "" >&2
  echo "   Anvil loop is stopping. Run /anvil-loop again to start fresh." >&2
  rm "$ANVIL_STATE_FILE"
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
TEMP_FILE="${ANVIL_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$ANVIL_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$ANVIL_STATE_FILE"

# Build system message with iteration count and completion promise info
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="[LOOP] Anvil iteration $NEXT_ITERATION | To stop: output '$COMPLETION_PROMISE' on its own line (ONLY when genuinely complete)"
else
  SYSTEM_MSG="[LOOP] Anvil iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Add learnings reminder to system message
if [[ "$LEARNINGS_ENABLED" == "true" ]]; then
  SYSTEM_MSG="${SYSTEM_MSG} | [NOTE] Learnings: ${LEARNINGS_FILE}"
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
