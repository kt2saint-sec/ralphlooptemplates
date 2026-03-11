#!/bin/bash
# restore-hybrid.sh — Restore Ralph Loop hybrid architecture to correct state
#
# Fixes all known issues that can break the hybrid setup:
#   1. Plugin re-enabled by GitHub #28554 or /plugin update
#   2. Stop hook missing or corrupted in settings.json
#   3. Local commands missing or overwritten
#   4. Cache-watchdog hook re-added (unnecessary after migration)
#
# Safe to run repeatedly (idempotent). Does NOT require a new session
# for detection, but a new session IS required for fixes to take effect.
#
# Usage: bash RESTORE/restore-hybrid.sh [--dry-run] [--quiet]

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
COMMANDS_DIR="$HOME/.claude/commands"
DRY_RUN=false
QUIET=false
FIXES=0
WARNINGS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --quiet) QUIET=true ;;
  esac
done

log() { $QUIET || echo "$1"; }
warn() { echo "  WARN: $1"; WARNINGS=$((WARNINGS + 1)); }
fix() { echo "  FIX:  $1"; FIXES=$((FIXES + 1)); }
ok() { $QUIET || echo "  OK:   $1"; }

# Pre-flight checks
if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required. Install: sudo apt install jq" >&2
  exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "ERROR: $SETTINGS not found." >&2
  exit 1
fi

log "Ralph Loop Hybrid Restore"
log "  Repo: $REPO"
log "  Settings: $SETTINGS"
$DRY_RUN && log "  Mode: DRY RUN (no changes)"
log ""

# --- Check 1: Plugin entry in enabledPlugins ---
log "Check 1: Plugin entry in enabledPlugins"
PLUGIN_STATE=$(jq -r '.enabledPlugins["ralph-loop@claude-plugins-official"] // "missing"' "$SETTINGS")
if [[ "$PLUGIN_STATE" == "missing" ]]; then
  ok "No ralph-loop entry in enabledPlugins"
else
  warn "ralph-loop entry found in enabledPlugins (value: $PLUGIN_STATE)"
  if ! $DRY_RUN; then
    TEMP=$(mktemp)
    jq 'del(.enabledPlugins["ralph-loop@claude-plugins-official"])' "$SETTINGS" > "$TEMP"
    mv "$TEMP" "$SETTINGS"
    fix "Removed ralph-loop from enabledPlugins"
  fi
fi

# --- Check 2: Stop hook exists and points to repo ---
log ""
log "Check 2: Stop hook in settings.json"
HAS_STOP=$(jq 'has("hooks") and (.hooks | has("Stop"))' "$SETTINGS")
if [[ "$HAS_STOP" == "true" ]]; then
  STOP_CMD=$(jq -r '.hooks.Stop[0].hooks[0].command // ""' "$SETTINGS")
  if echo "$STOP_CMD" | grep -q "$REPO/scripts/stop-hook.sh"; then
    ok "Stop hook points to $REPO/scripts/stop-hook.sh"
  else
    warn "Stop hook exists but points elsewhere: $STOP_CMD"
    if ! $DRY_RUN; then
      TEMP=$(mktemp)
      jq --arg cmd "bash $REPO/scripts/stop-hook.sh" \
        '.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd, "timeout": 60}]}]' \
        "$SETTINGS" > "$TEMP"
      mv "$TEMP" "$SETTINGS"
      fix "Updated Stop hook to point to $REPO/scripts/stop-hook.sh"
    fi
  fi
else
  warn "No Stop hook found in settings.json"
  if ! $DRY_RUN; then
    TEMP=$(mktemp)
    jq --arg cmd "bash $REPO/scripts/stop-hook.sh" \
      '.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd, "timeout": 60}]}]' \
      "$SETTINGS" > "$TEMP"
    mv "$TEMP" "$SETTINGS"
    fix "Added Stop hook pointing to $REPO/scripts/stop-hook.sh"
  fi
fi

# --- Check 3: Stop hook timeout ---
log ""
log "Check 3: Stop hook timeout"
if [[ "$HAS_STOP" == "true" ]]; then
  TIMEOUT=$(jq -r '.hooks.Stop[0].hooks[0].timeout // 0' "$SETTINGS")
  if [[ "$TIMEOUT" -ge 60 ]]; then
    ok "Stop hook timeout: ${TIMEOUT}s"
  else
    warn "Stop hook timeout too low: ${TIMEOUT}s (need >= 60)"
    if ! $DRY_RUN; then
      TEMP=$(mktemp)
      jq '.hooks.Stop[0].hooks[0].timeout = 60' "$SETTINGS" > "$TEMP"
      mv "$TEMP" "$SETTINGS"
      fix "Set Stop hook timeout to 60s"
    fi
  fi
fi

# --- Check 4: Cache-watchdog hook (should NOT exist after migration) ---
log ""
log "Check 4: Cache-watchdog SessionStart hook (should be absent)"
WATCHDOG_COUNT=$(jq '[.hooks.SessionStart // [] | .[] | select(.hooks[].command | contains("cache-watchdog"))] | length' "$SETTINGS")
if [[ "$WATCHDOG_COUNT" == "0" ]]; then
  ok "No cache-watchdog hook (correct for hybrid)"
else
  warn "Cache-watchdog hook found ($WATCHDOG_COUNT instance(s)) — unnecessary after migration"
  if ! $DRY_RUN; then
    TEMP=$(mktemp)
    jq '.hooks.SessionStart = [.hooks.SessionStart[] | select(.hooks[].command | contains("cache-watchdog") | not)]' "$SETTINGS" > "$TEMP"
    mv "$TEMP" "$SETTINGS"
    fix "Removed cache-watchdog SessionStart hook"
  fi
fi

# --- Check 5: Local commands exist with absolute paths ---
log ""
log "Check 5: Local commands"

COMMAND_FILES=("ralph-loop.md" "cancel-ralph.md" "ralph-loop-help.md" "ralphtemplate.md" "ralphtemplatetest.md")
REPO_SOURCES=("ralph-loop.md" "cancel-ralph.md" "help.md" "ralphtemplate.md" "ralphtemplatetest.md")

for i in "${!COMMAND_FILES[@]}"; do
  CMD="${COMMAND_FILES[$i]}"
  SRC="${REPO_SOURCES[$i]}"
  TARGET="$COMMANDS_DIR/$CMD"

  if [[ ! -f "$TARGET" ]]; then
    warn "Missing: $TARGET"
    if ! $DRY_RUN && [[ -f "$REPO/commands/$SRC" ]]; then
      cp "$REPO/commands/$SRC" "$TARGET"
      # ralph-loop.md needs absolute path substitution
      if [[ "$CMD" == "ralph-loop.md" ]]; then
        sed -i "s|\${CLAUDE_PLUGIN_ROOT}|$REPO|g" "$TARGET"
        sed -i '/^hide-from-slash-command-tool/d' "$TARGET"
      fi
      fix "Restored $TARGET from repo"
    fi
  else
    # Check ralph-loop.md specifically for CLAUDE_PLUGIN_ROOT (plugin version leaked in)
    if [[ "$CMD" == "ralph-loop.md" ]]; then
      if grep -q 'CLAUDE_PLUGIN_ROOT' "$TARGET" 2>/dev/null; then
        warn "$TARGET uses CLAUDE_PLUGIN_ROOT (plugin version, not hybrid)"
        if ! $DRY_RUN; then
          cp "$REPO/commands/$SRC" "$TARGET"
          sed -i "s|\${CLAUDE_PLUGIN_ROOT}|$REPO|g" "$TARGET"
          sed -i '/^hide-from-slash-command-tool/d' "$TARGET"
          fix "Replaced $TARGET with hybrid version (absolute paths)"
        fi
      else
        ok "$CMD present with absolute paths"
      fi
    else
      ok "$CMD present"
    fi
  fi
done

# --- Check 6: stop-hook.sh exists in repo ---
log ""
log "Check 6: Repo script integrity"
if [[ -x "$REPO/scripts/stop-hook.sh" ]] || [[ -f "$REPO/scripts/stop-hook.sh" ]]; then
  ok "stop-hook.sh exists in $REPO/scripts/"
else
  warn "stop-hook.sh MISSING from $REPO/scripts/ — Stop hook will fail!"
fi

if [[ -x "$REPO/scripts/setup-ralph-loop.sh" ]] || [[ -f "$REPO/scripts/setup-ralph-loop.sh" ]]; then
  ok "setup-ralph-loop.sh exists in $REPO/scripts/"
else
  warn "setup-ralph-loop.sh MISSING from $REPO/scripts/ — /ralph-loop command will fail!"
fi

# --- Check 7: Ghost marketplace/cache/local plugin hooks ---
log ""
log "Check 7: Ghost plugin hooks.json files"
GHOST_HOOKS=0
# Check all three plugin directories: marketplace, cache, local
for PLUGIN_BASE in \
  "$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins" \
  "$HOME/.claude/plugins/cache/claude-plugins-official" \
  "$HOME/.claude/plugins/local"; do
  [[ -d "$PLUGIN_BASE" ]] || continue
  while IFS= read -r -d '' HOOK_FILE; do
    # Skip hooks for plugins that are enabled AND functional (currently only none qualify)
    PLUGIN_DIR=$(dirname "$(dirname "$HOOK_FILE")")
    PLUGIN_NAME=$(basename "$PLUGIN_DIR")
    # ralph-loop hooks in any location are always ghost hooks (we use settings.json Stop hook)
    # Other plugins with ${CLAUDE_PLUGIN_ROOT} in their commands are broken
    if [[ "$PLUGIN_NAME" == "ralph-loop" ]] || grep -q 'CLAUDE_PLUGIN_ROOT' "$HOOK_FILE" 2>/dev/null; then
      GHOST_HOOKS=$((GHOST_HOOKS + 1))
      warn "Ghost hooks.json: $HOOK_FILE"
      if ! $DRY_RUN; then
        mv "$HOOK_FILE" "${HOOK_FILE}.disabled"
        fix "Disabled: $HOOK_FILE"
      fi
    fi
  done < <(find "$PLUGIN_BASE" -name "hooks.json" -not -name "*.disabled" -print0 2>/dev/null)
done
if [[ "$GHOST_HOOKS" -eq 0 ]]; then
  ok "No ghost plugin hooks.json files found"
fi

# --- Summary ---
log ""
log "================================"
if $DRY_RUN; then
  echo "DRY RUN: $WARNINGS issue(s) detected, 0 fixed"
  if [[ $WARNINGS -gt 0 ]]; then
    echo "Run without --dry-run to apply fixes."
  fi
else
  echo "Result: $WARNINGS issue(s) found, $FIXES fixed"
fi

if [[ $FIXES -gt 0 ]]; then
  echo ""
  echo "IMPORTANT: Start a NEW Claude Code session for changes to take effect."
  echo "  (Claude Code caches hook content at session start)"
fi

if [[ $WARNINGS -eq 0 ]] && [[ $FIXES -eq 0 ]]; then
  echo "Everything looks good. No fixes needed."
fi

exit 0
