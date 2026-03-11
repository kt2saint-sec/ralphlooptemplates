---
description: "Cancel active Anvil Loop"
allowed-tools:
  [
    "Bash(ls .claude/anvil-loop.*.local.md:*)",
    "Bash(rm .claude/anvil-loop.*.local.md:*)",
    "Bash(rm .claude/anvil-learnings.*.md:*)",
    "Read(.claude/anvil-loop.*.local.md)",
  ]
hide-from-slash-command-tool: "true"
---

# Cancel Anvil

SAFETY: Anvil loop files use specific naming patterns. ONLY delete files matching these EXACT patterns:

- State files: `.claude/anvil-loop.{SESSION_ID}.local.md`
- Learnings files: `.claude/anvil-learnings.{SESSION_ID}.md`

NEVER delete CLAUDE.md, LEARNINGS.md, README.md, or any other project files.

To cancel the Anvil loop:

1. List matching state files using Bash: `ls .claude/anvil-loop.*.local.md 2>/dev/null`

2. **If no files found**: Say "No active Anvil loop found."

3. **If ONE file found**:
   - Read it to get the iteration number from `iteration:` and the `session_id:` from frontmatter
   - Delete ONLY that specific state file by its full name (not a glob)
   - Delete ONLY the matching learnings file: `.claude/anvil-learnings.{SESSION_ID}.md` using the session ID extracted from the state file
   - Report: "Cancelled Anvil loop session {SESSION_ID} (was at iteration N)"

4. **If MULTIPLE files found** (multi-terminal scenario):
   - List all found files with their session IDs and iteration numbers
   - If user passed `--all`: delete ALL state files and their matching learnings files, one by one
   - Otherwise: ask the user which session to cancel by showing the list
   - For each deletion, use the specific filename (not a glob pattern)

CRITICAL: When deleting learnings files, ALWAYS use the specific session ID from the state file. NEVER use `rm .claude/anvil-learnings.*.md` as a glob - this would delete all sessions' learnings.
