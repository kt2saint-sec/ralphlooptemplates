# Ralph Loop Templates - Migration & Architecture Decisions

## Plugin Loading Architecture

### Decision: Target marketplaces/ as PRIMARY sync directory

**Context**: An early attempt to solve plugin cache overwrites by pointing `installPath` in
`installed_plugins.json` to a local directory (`~/.claude/plugins/local/ralph-loop/`).

**Discovery**: Claude Code loads plugins from `~/.claude/plugins/marketplaces/` (a git checkout),
completely ignoring `installPath`. The local install approach was non-functional.

**Architecture**: cache-sync.sh now syncs to all three directories:
1. `marketplaces/` (PRIMARY - what Claude Code actually loads)
2. `cache/` (secondary - unclear if used, kept for safety)
3. `local/` (reference copy - not functional but kept)

**Tradeoff**: `/plugin update` does `git pull` on marketplaces/, overwriting patches.
No way to prevent this. Mitigation: re-run cache-sync.sh after updates.

**Alternative rejected**: Forking the plugin repo. Too much overhead for a single-user project.

## Hook Script Caching

### Decision: Accept "sync then new session" workflow

**Context**: Discovered Claude Code caches hook script CONTENT at session start. File edits
during a session have zero effect on running hooks.

**Impact**: Debug logging during a session is impossible. Testing requires: edit -> sync -> exit -> restart.

**Tradeoff**: Slower development cycle but no workaround exists. This is Claude Code's architecture.

## Promise Detection Format

### Decision: Plain-text `grep -Fx` over XML `<promise>` tags

**Context**: Original plugin uses `<promise>TEXT</promise>` Perl regex detection.
Claude Code's rendering pipeline strips XML tags from output before transcript.

**Architecture**: Passphrase system (`WORD NNNN WORD NNNN WORD NNNN`) with `grep -Fx` exact line match.
No XML tags at any point in the pipeline.

**Tradeoff**: Incompatible with original plugin's detection format. If reverted to original plugin
(via /plugin update without cache-sync), passphrase detection silently fails.

## Session ID Strategy

### Decision: Hook JSON `session_id` with uuidgen fallback + rename migration

**Context**: `PPID` differs between setup script and stop hook (separate processes).
`CLAUDE_SESSION_ID` env var does not exist.

**Architecture**:
1. Setup: generates uuidgen ID, creates `ralph-loop.{UUID}.local.md`
2. Stop hook iteration 1: reads `session_id` from hook JSON, renames file to `ralph-loop.{SESSION_ID}.local.md`
3. Stop hook iteration 2+: O(1) direct lookup by hook session_id

**Tradeoff**: First iteration uses glob fallback (O(n)). Rename is flock-protected for concurrency.

## State File Compatibility

### Decision: Dual glob pattern with nullglob char-class trick

**Context**: Original plugin creates `ralph-loop.local.md` (no session ID).
Our version creates `ralph-loop.{SESSION_ID}.local.md`. Must support both.

**Architecture**: `(.claude/ralph-loop.loca[l].md .claude/ralph-loop.*.local.md)`
- `loca[l].md` char class forces nullglob to apply (literal paths bypass nullglob)
- `*.local.md` catches session-scoped files

**Tradeoff**: Slightly obscure bash idiom. Well-documented in code comments and LEARNINGS.md.

## Researcher Role Architecture

### Decision: Add independent Researcher as Role 4 in /ralphtemplate

**Context**: Across multiple development sessions, Builder and Proxy repeatedly made wrong assumptions
on uncertain items, burning multiple iterations before discovering the truth.

**Architecture**: When Builder or Proxy is below 75% certainty, they MUST delegate to the Researcher.
The Researcher is independent and unbiased — it gathers facts, not opinions. It can use subagents
(Explore, general-purpose), web search, MCP servers (context7, brave, fetch, github), and source
code analysis. Reports in structured format: Question, Sources checked, Findings, Confidence, Caveats.

**Tradeoff**: Adds latency when invoked. But prevents multi-iteration dead ends from wrong assumptions.
The 75% threshold is a judgment call — too low and it never fires, too high and every step triggers research.

**MCP dependency**: Researcher effectiveness scales with available MCP servers. In environments with
limited MCP access, it degrades to codebase-only search (still useful, just less powerful).
