# Changelog

All notable changes to the Anvil Method project.

## [v4.2] - 2026-03-11

### Fixed
- **Stop hook infinite loop bug**: Orphaned state files from abandoned sessions were being adopted by new sessions via glob fallback + rename, causing the stop hook to block every exit indefinitely. Root cause: stale guard threshold was 3600s (1 hour), allowing recent orphaned files to be adopted and renamed to the current session ID. After rename, direct lookup found them on every subsequent invocation with no stale check.
- **Stale guard threshold**: Reduced from 3600s to 120s. Files from different sessions older than 2 minutes are now skipped. Files < 120s old are still adopted (setup script first-iteration rename scenario).
- **Empty session_id bypass**: Files with missing `session_id` field were bypassing the stale guard entirely. Now handled: missing or non-matching session_id both trigger the age check.
- **`set -euo pipefail` incompatibility**: Removed `-e` flag from stop hook (line 8). The `-e` flag caused unexpected exits in code paths with intentional non-zero returns (e.g., `flock -n`, pattern matching). Changed to `set -uo pipefail`.

### Changed
- Updated Known Behaviors in CLAUDE.md to reflect fixes

## [v4.1] - 2026-03-11

### Added
- tmpfs/RAM setup guide
- Trimmed to core plugin files only

## [v4.0] - 2026-03-11

### Changed
- Complete rebrand from Ralph Loop to Anvil Method (71 files changed)
- LICENSE: Karl Toussaint (kt2saint) named copyright holder, Source Available license
- Comprehensive README with architecture docs
- All personal paths sanitized, hooks.json fixed, sandbox paths made generic

## [v3.5] - 2026-03-10

### Fixed
- Config mismatch + ghost hook eradication (sessions 20-24)
