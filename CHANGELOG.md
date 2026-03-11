# Changelog

## Session 24 (2026-03-10) — Config Mismatch Fix + Ghost Hook Eradication

### Fixed
- **SessionStart hook error** — Root cause: 10 ghost plugin hooks.json in `~/.claude-planB/plugins/` firing uninstalled CLI commands (semgrep, superpowers .cmd). Disabled all via rename to `.disabled`.
- **Config directory mismatch** — Sessions 12-22 edited `~/.claude/settings.json` while `claudeB` reads `~/.claude-planB/settings.json`. All hooks (SessionStart, Stop, PostToolUse) now in both files.
- **init.sh UI error** — Added `{"suppressOutput": true}` JSON output (GitHub #21643 — non-JSON stdout = error display).
- **CLAUDE_ENV_FILE persistence** — Changed `-w` file check to parent-dir-writable check. Hook creates the file, not appends.
- **Double SSH passphrase prompts** — Removed competing `ssh-agent -s` from `.bashrc` (gcr-ssh-agent via systemd already provides `SSH_AUTH_SOCK`).

### Changed
- `~/.claude-planB/settings.json` — Added hooks section (was minimal 23-line config with no hooks)
- `~/.config/claude-code/init.sh` — CLAUDE_CONFIG_DIR-aware MCP env loading, CLAUDE_ENV_FILE support, JSON stdout
- `~/.bashrc` lines 263-268 — SSH agent section simplified

### Added
- `~/.claude-planB/BACKUP_RESTORE/rollback-session24.sh` — Reverts all session 24 changes
- LEARNINGS.md decisions 86-91
- MIGRATION-DECISIONS.md — 4 new architecture decisions (dual config, aggressive hook disable, JSON output, CLAUDE_ENV_FILE)

### Documentation
- CLAUDE.md — Updated architecture section, known risks, new rules (7 new RULE entries)
- README.md — Stats updated (20→24 sessions, 72→91 decisions)
- MEMORY.md — Session 24 fixes recorded, config mismatch marked as FIXED+VERIFIED

## Session 23 (2026-03-10) — Investigation Session

### Discovered
- Config directory mismatch (`CLAUDE_CONFIG_DIR=~/.claude-planB`)
- Ghost plugin hooks in planB plugins directory
- init.sh export dead code (CLAUDE_ENV_FILE is correct mechanism)
- Double SSH agent root cause (gcr-ssh-agent + .bashrc ssh-agent)
- LEARNINGS.md decisions 75-85

## Sessions 20-22 (2026-03-09 to 2026-03-10) — Hook Fix Saga

### Fixed
- Session 20: SessionStart bg process FD leak, sandbox path migration to nvme-fast
- Session 21: PostToolUse hooks rewrote for stdin JSON (env vars don't exist)
- Session 22: Ghost hooks in 3 plugin directories (marketplace, cache, local)

## Sessions 17-19 (2026-03-08 to 2026-03-09) — v2 Templates + Passphrase v3

### Added
- v2 template system (EVALUATOR, DOCUMENTOR, dynamic iterations, test preservation)
- v3 passphrase format (epoch-hex + random)

## Session 16 (2026-03-07) — I/O Pressure Optimization

### Added
- `scripts/reduce-io-pressure.sh` — journald caps, dedicated workspace, tmpfs fstab

## Session 14-15 (2026-03-06) — Recovery + Passphrase Fix

### Added
- RESTORE/restore-hybrid.sh — idempotent health check + fix
- /dev/urandom hex passphrase (replaced LLM word arrays with token bias)

## Session 12-13 (2026-03-05) — Hybrid Migration + Diagrams

### Changed
- Migrated from marketplace plugin to local commands + settings.json hooks
- 4 HTML architecture diagrams in docs/

## Sessions 1-11 (2026-02-28 to 2026-03-04) — Foundation

### Built
- Ralph Loop core: stop-hook.sh, setup-ralph-loop.sh, state file management
- 4 template variants (/ralphtemplate, /ralphtemplatetest, v2 variants)
- 5 adversarial roles (Builder, Challenger, Proxy, Researcher, Tester)
- 137 tests across 10 test suites
- Promise detection, session ID strategy, multi-terminal support
