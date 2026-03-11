# Anvil Method - Project Instructions

## Architecture

Settings.json Stop hook → `scripts/stop-hook-anvil.sh` → `.claude/anvil-loop.{SESSION_ID}.local.md`

- Stop hook: `~/.claude/settings.json` → `bash $REPO/scripts/stop-hook-anvil.sh`
- If using dual config (`CLAUDE_CONFIG_DIR`), add the hook to BOTH settings.json files
- SessionStart hook: (optional) Your init script at `${HOME}/.config/claude-code/init.sh`
- Commands: `commands/` in this repo, installed to `~/.claude/commands/`
- Source of truth: This repo

CRITICAL: `claudeB` uses `~/.claude-planB/settings.json` (via `CLAUDE_CONFIG_DIR`). Plain `claude` uses `~/.claude/settings.json`. BOTH must have hooks.

RULE: `CLAUDE_CONFIG_DIR` determines which settings.json is active. Always check `echo $CLAUDE_CONFIG_DIR` before editing.

## Hook Rules

- Hook changes require a NEW session. Claude Code caches hook script content at session start.
- Hook data arrives via stdin JSON. Use `INPUT=$(cat); jq -r '.field'` — NOT environment variables.
- Hook scripts MUST NOT spawn background processes that inherit stdout/stderr FDs. Use `>/dev/null 2>&1 & disown`.
- SessionStart hooks MUST output valid JSON to stdout (`{"suppressOutput": true}`).
- SessionStart hooks support matchers: `startup`, `resume`, `clear`, `compact`. Stop hooks do NOT support matchers.
- Plugin hooks.json fires even if the plugin's CLI tool isn't installed. Non-JSON output triggers UI error.

## Stop Hook Input JSON

Common fields (all hooks):
- `session_id` — current session identifier
- `transcript_path` — path to conversation JSONL
- `cwd` — current working directory
- `hook_event_name` — "Stop" for stop hooks

Stop-specific fields:
- `stop_hook_active` — true when continuing from a prior Stop hook (loop detection)
- `last_assistant_message` — text of Claude's final response

## State Files

- State: `.claude/anvil-loop.{SESSION_ID}.local.md` (gitignored via `*.local.md`)
- Learnings: `.claude/anvil-learnings.{SESSION_ID}.md` (temporary, deleted on consolidation)
- Fast-exit guard checks for state files BEFORE reading stdin
- First iteration: setup uses uuidgen ID, stop hook renames to hook session_id for O(1) lookup

## Passphrase System

- Format: `ANVIL-[8-char epoch hex]-[40 hex chars from /dev/urandom]`
- Generation: `echo "ANVIL-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')"`
- Epoch hex decodable for audit: `printf '%d\n' 0xEPOCH`
- User-provided promises get prefixed: `PASSPHRASE::USER_PROMISE`
- Detection uses `grep -qF` (substring match). The ANVIL- prefix + 48 hex chars prevents false positives.

## Transcript Format

- XML/HTML tags are STRIPPED by Claude Code's rendering pipeline before transcript files
- Promise detection MUST use plain-text matching (`grep -F`), never XML tag parsing
- Transcript is JSONL format: one JSON object per line, `.message.content[].text` for text blocks

## Anvil Loop Best Practices

- ALWAYS set `--completion-promise` to avoid infinite loops with no exit signal
- ALWAYS set `--max-iterations` as a safety bound (10-30 typical)
- `completion_promise: null` means loop runs until max_iterations — no early exit possible
- Hook changes require a NEW session to take effect
- Run `/cancel-anvil` BEFORE starting a new loop if any prior loop was abandoned. Multiple state files cause the glob fallback to pick the wrong one, making passphrase detection fail.
- NEVER run `stop-hook-anvil.sh` manually with simulated stdin in the live project directory. The rename logic will corrupt real state files. Test hooks in a copy or sandbox only.

## Commands

| Command | Description |
|---------|-------------|
| `/anviltemplate` | Generate a full 6-role orchestrated prompt with EVALUATOR scaling |
| `/anvil-loop` | Start a self-iterating development loop |
| `/anvil-loop-safe` | Same with git safety checks (feature branch required) |
| `/cancel-anvil` | Cancel an active loop |
| `/anvil-loop-help` | Full documentation of loop behavior and flags |
| `/boris-challenge` | Challenge requirements before coding (Challenger role standalone) |

Add `TESTINGOFF` to `/anviltemplate` arguments for a 5-role prompt without the Tester.

## 6-Role System

| Role | Knows | Does | Cannot | Stake |
|------|-------|------|--------|-------|
| EVALUATOR | Task complexity only | Scores difficulty, sets tier, permanently exits | Implement, challenge, decide, reactivate | None |
| CHALLENGER | Goal + Builder's approach | Adversarial stress-testing, gates Builder, escalates tier | Approve, decide, or implement | None |
| PROXY | Goal + codebase + docs | Answers as human stand-in, judgment calls | See tests, write code, override Challenger | Has stake |
| RESEARCHER | Only the question asked | Finds facts with citations | Make decisions | None |
| TESTER | Goals document only | Writes behavior tests in sandbox BEFORE implementation | See Builder's code, communicate with any role, see Challenger objections | None |
| BUILDER | Goal + approach + test results (pass/fail only) | Implements in isolation, iterates against expected behavior | See test source, renegotiate goal, communicate with Tester | Has stake |

## Complexity Tiers

| Tier | Challenger | Tester | Budget |
|------|-----------|--------|--------|
| LIGHT | 3+ objections | 3-5 tests | 5 |
| STANDARD | 5+ objections | 5-10 tests | 10 |
| THOROUGH | 7+ per-spec, proof required | 10-15 tests | 15 |
| RIGOROUS | 10+ blocking, proof required | 15-20 tests | 20 |
| MAXIMAL | 12+ with proof | 20+ security tests | 30 |

## Template Versions

| Template | Roles | EVALUATOR | Isolation Rules | Stake Labels |
|----------|-------|-----------|-----------------|--------------|
| `anviltemplate.md` | 6 (full) | ONE-SHOT | Full matrix | All roles |
| `anviltemplate-v2.md` | 5 (no Tester) | ONE-SHOT | Full matrix (no Tester channels) | All roles |

RULE: When modifying role isolation rules, update ALL template versions simultaneously. HTML diagrams in `docs/` require manual follow-up.

## Known Behaviors

- `nullglob` only applies to glob patterns. Literal paths bypass it. Use char-class trick: `anvil-loop.loca[l].md`.
- `set -e` incompatible with `systemctl is-active` (exit code 3 for inactive). Use `set -uo pipefail` (no `-e`).
- `CLAUDE_ENV_FILE`: hook script CREATES this file. Check `[[ -d "$(dirname "$CLAUDE_ENV_FILE")" ]]`, not `[[ -w "$CLAUDE_ENV_FILE" ]]`.
- Stop hook exit paths output to stderr only. Stdout is reserved for JSON decision blocks (`jq -n`).
- ANSI escape codes are stripped from `last_assistant_message` before passphrase matching.
- Stale state files (>1 hour, different session) are skipped on glob fallback to prevent cross-session hijacking.
- EVALUATOR is one-shot (Phase 0 only). Tier escalation during Phase 2 is handled by the Challenger.
- TESTER clean room: receives ONLY the task description. Does NOT receive Challenger objections or Proxy decisions.
- HTML diagrams (`docs/*.html`) are NOT auto-updated when template text changes. They must be manually updated.
- Bash variable expansion is single-pass: `"$VAR"` does NOT re-evaluate `$()`, `` `cmd` ``, or `$var` inside the variable's value. The stop hook and setup script are safe from command injection via prompt text.
- Multiple state files from abandoned loops cause glob fallback to pick the wrong file (wrong passphrase). The setup script has NO guard against this — it creates a new file unconditionally. The stale guard (120s threshold) now prevents adoption of orphaned files from different sessions, but `/cancel-anvil` is still recommended before starting a new loop.
- `scripts/hooks.json` references `${CLAUDE_PLUGIN_ROOT}/scripts/stop-hook-anvil.sh`. Verify this path matches the actual script location.
- The stop hook uses `set -uo pipefail` (line 8). Previously used `set -euo pipefail` which was incompatible; fixed in v4.2.
- `.txt` prompt files (`anvil-prompt-*.txt`) accumulate in the project root. They are gitignored but not auto-cleaned. Future: add `--source-file` flag to setup script for auto-cleanup on loop completion.
