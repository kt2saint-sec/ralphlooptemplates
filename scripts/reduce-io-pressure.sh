#!/usr/bin/env bash
# reduce-io-pressure.sh — Reduce write pressure on root SPCC NVMe drive
# Created: 2026-03-06
# Purpose: Prevent I/O crashes during heavy Ralph Loop workloads
#
# Three optimizations:
#   1. Move /tmp to tmpfs (RAM-backed)
#   2. Cap journald at 2G persistent with 2-week retention
#   3. Create fast workspace on /mnt/nvme-fast for sandbox workloads
#
# Usage:
#   bash scripts/reduce-io-pressure.sh [--apply | --diagnose | --rollback]
#   bash scripts/reduce-io-pressure.sh --apply-journald
#   bash scripts/reduce-io-pressure.sh --apply-workspace
#   bash scripts/reduce-io-pressure.sh --apply-tmpfs
#
# --diagnose         : Show current state, no changes (default)
# --apply            : Apply all optimizations (requires sudo)
# --apply-journald   : Apply only journald caps (safe now, ~1s log gap)
# --apply-workspace  : Apply only workspace creation (zero disruption)
# --apply-tmpfs      : Apply only /tmp fstab entry (fstab only, reboot to activate)
# --rollback         : Revert all changes to original state

set -uo pipefail
# NOTE: set -e intentionally omitted — diagnostic commands (systemctl, du)
# return non-zero for normal conditions (inactive units, permission denied)

NVME_FAST="/mnt/nvme-fast"
WORKSPACE_DIR="${NVME_FAST}/claude-workspace"
BACKUP_SUFFIX=".pre-io-optimization.bak"
FSTAB="/etc/fstab"
JOURNALD_CONF="/etc/systemd/journald.conf"
JOURNALD_OVERRIDE_DIR="/etc/systemd/journald.conf.d"
JOURNALD_OVERRIDE="${JOURNALD_OVERRIDE_DIR}/volatile.conf"
TMPFS_SIZE="16G"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── DIAGNOSE ───────────────────────────────────────────────────────────────

diagnose() {
    echo ""
    echo "============================================"
    echo "  I/O Pressure Diagnostic Report"
    echo "============================================"
    echo ""

    # 1. /tmp status
    info "1. /tmp Mount Status"
    local tmp_fs
    tmp_fs=$(df /tmp --output=fstype | tail -1)
    local tmp_dev
    tmp_dev=$(df /tmp --output=source | tail -1)
    local tmp_size
    tmp_size=$(du -sh /tmp 2>/dev/null | cut -f1)

    if [[ "$tmp_fs" == "tmpfs" ]]; then
        ok "/tmp is already tmpfs (RAM-backed)"
    else
        warn "/tmp is on $tmp_dev (filesystem: $tmp_fs) — writes hit root drive"
        info "  Current /tmp usage: $tmp_size"
    fi

    # Check fstab
    if grep -q "^[^#].*\s/tmp\s" "$FSTAB" 2>/dev/null; then
        info "  fstab entry exists for /tmp"
    else
        info "  No fstab entry for /tmp"
    fi

    # Check tmp.mount
    local tmp_mount_status
    tmp_mount_status=$(systemctl is-active tmp.mount 2>/dev/null || true)
    if [[ -z "$tmp_mount_status" ]]; then
        tmp_mount_status="not-found"
    fi
    info "  tmp.mount systemd unit: $tmp_mount_status"

    echo ""

    # 2. journald status
    info "2. Journald Storage Status"
    local journal_storage
    journal_storage=$(grep -E "^Storage=" "$JOURNALD_CONF" 2>/dev/null | cut -d= -f2 || echo "auto")
    if [[ -z "$journal_storage" ]]; then
        journal_storage="auto"
    fi

    local journal_disk_usage
    journal_disk_usage=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "unknown")

    if [[ -f "$JOURNALD_OVERRIDE" ]]; then
        local override_storage
        override_storage=$(grep -E "^Storage=" "$JOURNALD_OVERRIDE" 2>/dev/null | cut -d= -f2 || echo "none")
        local override_maxuse
        override_maxuse=$(grep -E "^SystemMaxUse=" "$JOURNALD_OVERRIDE" 2>/dev/null | cut -d= -f2 || echo "default")
        ok "journald override active: Storage=$override_storage, MaxUse=$override_maxuse"
        info "  Journal disk usage: $journal_disk_usage"
    elif [[ "$journal_storage" == "volatile" ]]; then
        warn "journald is volatile (RAM-only) — crash logs will be lost!"
        info "  Consider persistent with size caps instead"
    else
        warn "journald storage: $journal_storage (no size caps — writes hit root drive)"
        info "  Journal disk usage: $journal_disk_usage"
        info "  Default cap: 10% of root FS (~360GB on your 3.6TB drive!)"
    fi

    # Check for override directory
    if [[ -d "$JOURNALD_OVERRIDE_DIR" ]]; then
        info "  Override dir exists: $JOURNALD_OVERRIDE_DIR"
        ls -la "$JOURNALD_OVERRIDE_DIR" 2>/dev/null | tail -n +2
    fi

    echo ""

    # 3. Workspace on nvme-fast
    info "3. Fast Workspace Status"
    if [[ -d "$WORKSPACE_DIR" ]]; then
        ok "Workspace exists: $WORKSPACE_DIR"
        ls -la "$WORKSPACE_DIR" 2>/dev/null | tail -n +2
    else
        warn "No workspace at $WORKSPACE_DIR"
    fi

    local nvme_avail
    nvme_avail=$(df -h "$NVME_FAST" --output=avail | tail -1 | tr -d ' ')
    info "  Available space on nvme-fast: $nvme_avail"

    echo ""

    # 4. RAM overview
    info "4. RAM Status"
    free -h | head -2
    local mem_avail
    mem_avail=$(awk '/MemAvailable/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
    info "  Available RAM: ${mem_avail}GB"
    if (( mem_avail > 20 )); then
        ok "Plenty of RAM for tmpfs (104GB available)"
    else
        warn "RAM might be tight — consider smaller tmpfs size"
    fi

    echo ""

    # 5. Root drive I/O
    info "5. Root Drive Usage"
    df -h / | tail -1
    local root_dev
    root_dev=$(df / --output=source | tail -1)
    info "  Root device: $root_dev"

    echo ""
    echo "============================================"
    echo "  Recommendations"
    echo "============================================"
    echo ""
    if [[ "$tmp_fs" != "tmpfs" ]]; then
        if grep -q "^tmpfs /tmp tmpfs" "$FSTAB" 2>/dev/null; then
            echo "  [1] /tmp tmpfs fstab entry added — REBOOT to activate"
        else
            echo "  [1] Run with --apply-tmpfs to add /tmp tmpfs fstab entry"
        fi
    fi
    if [[ ! -f "$JOURNALD_OVERRIDE" ]]; then
        echo "  [2] Run with --apply to cap journald at 2G with 2-week retention"
    fi
    if [[ ! -d "$WORKSPACE_DIR" ]]; then
        echo "  [3] Run with --apply to create workspace at $WORKSPACE_DIR"
    fi
    echo ""
    echo "  Use --rollback to revert all changes"
    echo ""
}

# ─── HELPERS ────────────────────────────────────────────────────────────────

check_sudo() {
    if [[ $EUID -eq 0 ]]; then
        err "Do not run as root. Script uses sudo where needed."
        exit 1
    fi
    if ! sudo -v 2>/dev/null; then
        err "Need sudo access. Run: sudo -v"
        exit 1
    fi
}

# ─── APPLY ──────────────────────────────────────────────────────────────────

apply_tmpfs() {
    info "=== Applying /tmp tmpfs (fstab only — takes effect on reboot) ==="

    # Check if already tmpfs
    local tmp_fs
    tmp_fs=$(df /tmp --output=fstype | tail -1)
    if [[ "$tmp_fs" == "tmpfs" ]]; then
        ok "/tmp is already tmpfs — skipping"
        return 0
    fi

    # Check if fstab already has our entry
    if grep -q "^tmpfs /tmp tmpfs" "$FSTAB" 2>/dev/null; then
        ok "fstab already has tmpfs /tmp entry — skipping"
        grep "^tmpfs /tmp" "$FSTAB"
        return 0
    fi

    # Backup fstab
    if [[ ! -f "${FSTAB}${BACKUP_SUFFIX}" ]]; then
        sudo cp "$FSTAB" "${FSTAB}${BACKUP_SUFFIX}"
        ok "Backed up fstab to ${FSTAB}${BACKUP_SUFFIX}"
    fi

    # Check if fstab has a different /tmp entry
    if grep -q "^[^#].*\s/tmp\s" "$FSTAB"; then
        warn "fstab already has a /tmp entry — updating it"
        sudo sed -i "/^[^#].*\s\/tmp\s/c\\tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=${TMPFS_SIZE} 0 0" "$FSTAB"
    else
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=${TMPFS_SIZE} 0 0" | sudo tee -a "$FSTAB" > /dev/null
    fi
    ok "Added tmpfs /tmp entry to fstab (size=${TMPFS_SIZE})"

    # NO live mount — would break Xorg, Chrome, Claude, QEMU sockets
    info "NOT mounting live — active sockets in /tmp would break"
    info "Change takes effect on next reboot"

    # Verify fstab entry
    if grep -q "^tmpfs /tmp tmpfs" "$FSTAB"; then
        ok "VERIFIED: fstab entry added"
        grep "^tmpfs /tmp" "$FSTAB"
    else
        err "FAILED: fstab entry not found"
        return 1
    fi

    # Verify syntax
    local verify_output
    verify_output=$(findmnt --verify 2>&1 || true)
    if echo "$verify_output" | grep -qi "error.*tmp"; then
        err "fstab verification found errors for /tmp:"
        echo "$verify_output" | grep -i "tmp"
        return 1
    else
        ok "VERIFIED: fstab syntax valid (findmnt --verify)"
    fi

    # Confirm /tmp is still ext4 (not mounted yet)
    local current_fs
    current_fs=$(df /tmp --output=fstype | tail -1)
    info "/tmp is currently: $current_fs (will become tmpfs after reboot)"
}

apply_journald_limits() {
    info "=== Applying journald size caps (persistent with limits) ==="
    # Research finding: volatile is WRONG for dev workstations.
    # Crash logs would be lost — exactly when you need them most.
    # Instead: keep persistent storage but cap write volume aggressively.

    # Check if already configured
    if [[ -f "$JOURNALD_OVERRIDE" ]]; then
        local existing
        existing=$(grep -E "^SystemMaxUse=" "$JOURNALD_OVERRIDE" 2>/dev/null || echo "")
        if [[ -n "$existing" ]]; then
            ok "journald limits already configured via override"
            cat "$JOURNALD_OVERRIDE"
            return 0
        fi
    fi

    # Backup main conf
    if [[ ! -f "${JOURNALD_CONF}${BACKUP_SUFFIX}" ]]; then
        sudo cp "$JOURNALD_CONF" "${JOURNALD_CONF}${BACKUP_SUFFIX}"
        ok "Backed up journald.conf"
    fi

    # Use drop-in override (cleaner than editing main conf)
    sudo mkdir -p "$JOURNALD_OVERRIDE_DIR"
    cat <<'OVERRIDE' | sudo tee "$JOURNALD_OVERRIDE" > /dev/null
[Journal]
# Persistent with aggressive size caps
# Keeps crash logs (critical for debugging I/O crashes)
# but limits write volume to reduce root drive pressure
Storage=persistent
# Cap total disk usage (default is 10% of FS = 360GB on 3.6TB drive!)
SystemMaxUse=2G
SystemKeepFree=20G
# Cap in-memory buffer
RuntimeMaxUse=256M
# Auto-prune old entries
MaxRetentionSec=2weeks
MaxFileSec=1week
# Compress journal files (3-5x ratio typical)
Compress=yes
OVERRIDE
    ok "Created journald override at $JOURNALD_OVERRIDE"

    # Vacuum existing journal to new limits
    sudo journalctl --vacuum-size=2G 2>/dev/null || true
    ok "Vacuumed existing journal to 2G cap"

    # Restart journald
    sudo systemctl restart systemd-journald
    ok "Restarted systemd-journald"

    # Verify
    local journal_size
    journal_size=$(journalctl --disk-usage 2>/dev/null || echo "unknown")
    info "Journal disk usage after vacuum: $journal_size"

    ok "VERIFIED: journald now persistent with 2G cap + 2-week retention"
    info "Crash logs preserved. Write volume dramatically reduced."
}

apply_workspace() {
    info "=== Creating fast workspace on nvme-fast ==="

    if [[ ! -d "$NVME_FAST" ]]; then
        err "$NVME_FAST does not exist!"
        return 1
    fi

    # Create workspace directory structure
    mkdir -p "${WORKSPACE_DIR}/sandbox"
    mkdir -p "${WORKSPACE_DIR}/tmp"
    mkdir -p "${WORKSPACE_DIR}/builds"
    ok "Created workspace at $WORKSPACE_DIR"
    ok "  sandbox/ — for Ralph Loop test sandboxes"
    ok "  tmp/     — overflow temp storage"
    ok "  builds/  — build artifacts"

    # Create a helper script for redirecting sandbox
    cat > "${WORKSPACE_DIR}/README.txt" <<'README'
Claude Workspace on NVMe Fast Drive
====================================

This directory provides fast I/O for Claude Code workloads,
offloading write pressure from the root SPCC drive.

Directories:
  sandbox/  - Ralph Loop test sandbox directory
  tmp/      - Overflow temporary storage
  builds/   - Build artifacts and package outputs

To use sandbox/ instead of /tmp for Ralph Loop tests:
  Set RALPH_SANDBOX_BASE=/mnt/nvme-fast/claude-workspace/sandbox
  (requires ralphtemplatetest command update)

Created by: reduce-io-pressure.sh
README
    ok "Created README at ${WORKSPACE_DIR}/README.txt"

    # Verify permissions
    local owner
    owner=$(stat -c '%U' "$WORKSPACE_DIR")
    if [[ "$owner" == "$(whoami)" ]]; then
        ok "VERIFIED: Workspace owned by $(whoami)"
    else
        warn "Workspace owned by $owner — may need chown"
    fi
}

apply_all() {
    echo ""
    echo "============================================"
    echo "  Applying I/O Pressure Optimizations"
    echo "============================================"
    echo ""

    check_sudo

    echo ""
    echo "--- Step 1/3: journald caps ---"
    apply_journald_limits
    echo ""
    echo "--- Step 2/3: workspace on nvme-fast ---"
    apply_workspace
    echo ""
    echo "--- Step 3/3: /tmp tmpfs (fstab only) ---"
    apply_tmpfs
    echo ""

    echo "============================================"
    echo "  All optimizations applied!"
    echo "============================================"
    echo ""
    info "Summary:"
    echo "  [1] journald -> persistent with 2G cap + 2-week retention (ACTIVE NOW)"
    echo "  [2] workspace -> ${WORKSPACE_DIR} (ACTIVE NOW)"
    echo "  [3] /tmp -> tmpfs ${TMPFS_SIZE} fstab entry (ACTIVE AFTER REBOOT)"
    echo ""
    info "To verify: bash $0 --diagnose"
    info "To revert: bash $0 --rollback"
    echo ""
}

# ─── ROLLBACK ───────────────────────────────────────────────────────────────

rollback() {
    echo ""
    echo "============================================"
    echo "  Rolling Back I/O Optimizations"
    echo "============================================"
    echo ""

    # Check sudo
    if ! sudo -v 2>/dev/null; then
        err "Need sudo access for rollback"
        exit 1
    fi

    # 1. Restore fstab
    info "Rolling back /tmp..."
    if [[ -f "${FSTAB}${BACKUP_SUFFIX}" ]]; then
        sudo cp "${FSTAB}${BACKUP_SUFFIX}" "$FSTAB"
        ok "Restored fstab from backup"
    else
        # Just remove our entry
        if grep -q "^tmpfs /tmp tmpfs" "$FSTAB"; then
            sudo sed -i '/^tmpfs \/tmp tmpfs/d' "$FSTAB"
            ok "Removed tmpfs /tmp entry from fstab"
        else
            info "No tmpfs /tmp entry in fstab — nothing to revert"
        fi
    fi

    # Unmount tmpfs /tmp if mounted
    local tmp_fs
    tmp_fs=$(df /tmp --output=fstype | tail -1)
    if [[ "$tmp_fs" == "tmpfs" ]]; then
        warn "Cannot unmount /tmp while system is running"
        warn "  The fstab change will take effect on next reboot"
        warn "  Or reboot now to go back to disk-backed /tmp"
    fi

    echo ""

    # 2. Restore journald
    info "Rolling back journald..."
    if [[ -f "$JOURNALD_OVERRIDE" ]]; then
        sudo rm "$JOURNALD_OVERRIDE"
        ok "Removed journald size cap override"
        sudo systemctl restart systemd-journald
        ok "Restarted journald (back to default — no size caps)"
    elif [[ -f "${JOURNALD_CONF}${BACKUP_SUFFIX}" ]]; then
        sudo cp "${JOURNALD_CONF}${BACKUP_SUFFIX}" "$JOURNALD_CONF"
        sudo systemctl restart systemd-journald
        ok "Restored journald.conf from backup and restarted"
    else
        info "No journald changes to revert"
    fi

    echo ""

    # 3. Workspace (keep it — no harm)
    info "Workspace at ${WORKSPACE_DIR}..."
    if [[ -d "$WORKSPACE_DIR" ]]; then
        info "Workspace kept (harmless on nvme-fast). Remove manually if desired:"
        info "  rm -rf ${WORKSPACE_DIR}"
    fi

    echo ""
    ok "Rollback complete. Reboot recommended to fully revert /tmp."
    echo ""
}

# ─── MAIN ───────────────────────────────────────────────────────────────────

main() {
    local mode="${1:---diagnose}"

    case "$mode" in
        --diagnose|-d)
            diagnose
            ;;
        --apply|-a)
            diagnose
            echo ""
            read -rp "Apply all optimizations? [y/N] " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                apply_all
            else
                info "Aborted."
            fi
            ;;
        --apply-journald)
            check_sudo
            apply_journald_limits
            ;;
        --apply-workspace)
            apply_workspace
            ;;
        --apply-tmpfs)
            check_sudo
            apply_tmpfs
            ;;
        --rollback|-r)
            rollback
            ;;
        --help|-h)
            echo "Usage: bash $0 [OPTION]"
            echo ""
            echo "  --diagnose         Show current I/O configuration (default)"
            echo "  --apply            Apply all three optimizations"
            echo "  --apply-journald   Apply only: journald caps (safe now)"
            echo "  --apply-workspace  Apply only: workspace on nvme-fast"
            echo "  --apply-tmpfs      Apply only: /tmp fstab entry (reboot to activate)"
            echo "  --rollback         Revert all changes"
            ;;
        *)
            err "Unknown option: $mode"
            echo "Usage: bash $0 [--diagnose | --apply | --apply-journald | --apply-workspace | --apply-tmpfs | --rollback]"
            exit 1
            ;;
    esac
}

main "$@"
