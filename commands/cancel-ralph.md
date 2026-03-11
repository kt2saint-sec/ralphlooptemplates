---
description: "Cancel active Ralph Loop"
allowed-tools:
  [
    "Bash(ls .claude/ralph-loop.*.local.md:*)",
    "Bash(rm .claude/ralph-loop.*.local.md:*)",
    "Bash(rm .claude/ralph-learnings.*.md:*)",
    "Read(.claude/ralph-loop.*.local.md)",
  ]
hide-from-slash-command-tool: "true"
---

# Cancel Ralph

SAFETY: Ralph loop files use specific naming patterns. ONLY delete files matching these EXACT patterns:

- State files: `.claude/ralph-loop.{SESSION_ID}.local.md`
- Learnings files: `.claude/ralph-learnings.{SESSION_ID}.md`

NEVER delete CLAUDE.md, LEARNINGS.md, README.md, or any other project files.

To cancel the Ralph loop:

1. List matching state files using Bash: `ls .claude/ralph-loop.*.local.md 2>/dev/null`

2. **If no files found**: Say "No active Ralph loop found."

3. **If ONE file found**:
   - Read it to get the iteration number from `iteration:` and the `session_id:` from frontmatter
   - Delete ONLY that specific state file by its full name (not a glob)
   - Delete ONLY the matching learnings file: `.claude/ralph-learnings.{SESSION_ID}.md` using the session ID extracted from the state file
   - Report: "Cancelled Ralph loop session {SESSION_ID} (was at iteration N)"

4. **If MULTIPLE files found** (multi-terminal scenario):
   - List all found files with their session IDs and iteration numbers
   - If user passed `--all`: delete ALL state files and their matching learnings files, one by one
   - Otherwise: ask the user which session to cancel by showing the list
   - For each deletion, use the specific filename (not a glob pattern)

CRITICAL: When deleting learnings files, ALWAYS use the specific session ID from the state file. NEVER use `rm .claude/ralph-learnings.*.md` as a glob - this would delete all sessions' learnings.
