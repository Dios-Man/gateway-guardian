#!/bin/bash
# config-watcher.sh — Watch openclaw.json for changes, validate, and rollback if needed
# Managed by systemd. Installed via SKILL.md — do not run manually.
#
# Maintenance mode: touch ~/.openclaw/.guardian-maintenance to pause monitoring
#                   rm  ~/.openclaw/.guardian-maintenance to resume

LOG="/tmp/config-watcher.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

log "=== config-watcher started ==="

# ── Maintenance mode helpers ───────────────────────────────────────────────────
_MAINTENANCE_WAS_ACTIVE=0

check_maintenance() {
    if [ -f "$MAINTENANCE_FLAG" ]; then
        if [ "$_MAINTENANCE_WAS_ACTIVE" = "0" ]; then
            _MAINTENANCE_WAS_ACTIVE=1
            log "⏸️  Maintenance mode active — monitoring paused"
            notify_status "$_MSG_MAINTENANCE_ON"
        fi
        return 0  # maintenance active
    else
        if [ "$_MAINTENANCE_WAS_ACTIVE" = "1" ]; then
            _MAINTENANCE_WAS_ACTIVE=0
            log "▶️  Maintenance mode ended — monitoring resumed"
            notify_status "$_MSG_MAINTENANCE_OFF"
        fi
        return 1  # maintenance not active
    fi
}

# ── Background: monitor gateway recovery (detects down→up transition) ─────────
monitor_gateway_recovery() {
    local was_down=0

    # Delay 10s on startup to give the gateway time to come up (After= doesn't guarantee port readiness)
    sleep 10
    nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null || was_down=1

    while true; do
        sleep 5
        if nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null; then
            if [ "$was_down" = "1" ]; then
                was_down=0
                if [ -f "$MANAGED_RESTART_FLAG" ]; then
                    local flag_type
                    flag_type=$(cat "$MANAGED_RESTART_FLAG" 2>/dev/null)
                    rm -f "$MANAGED_RESTART_FLAG"
                    if [ "$flag_type" = "recovery" ] || [ "$flag_type" = "watcher" ]; then
                        # recovery.sh / config-watcher already sent the notification — skip
                        log "[monitor] Managed restart ($flag_type) — skipping notification"
                    elif [ "$flag_type" = "upgrade" ]; then
                        # Upgrade-triggered restart — send upgrade-specific notification
                        log "[monitor] Gateway restart complete (upgrade)"
                        notify_status "$_MSG_UPGRADE_DETECTED"
                    else
                        # Planned restart complete (initiated by pre-stop.sh)
                        log "[monitor] Gateway restart complete"
                        notify_status "$_MSG_RESTART_DONE"
                    fi
                else
                    # Human-fixed or unknown recovery
                    log "[monitor] Gateway recovered (unmanaged) — sending notification"
                    notify_status "$_MSG_HUMAN_FIXED"
                fi
            fi
        else
            was_down=1
        fi
    done
}

monitor_gateway_recovery &
MONITOR_PID=$!
log "[monitor] Background monitor started (PID: $MONITOR_PID)"

# ── On startup: validate current config under lock ────────────────────────────
if check_maintenance; then
    log "⏸️  Startup validation skipped — maintenance mode active"
else
    (
        flock -w 60 9 || { log "Lock timeout on startup"; exit 1; }
        handle_change
    ) 9>"$LOCK_FILE"
fi

# ── Watch directory in monitor mode (-m), only process openclaw.json changes ──
inotifywait -q -m -e close_write -e moved_to \
    --format '%f' "$BACKUP_DIR" 2>>"$LOG" | \
while IFS= read -r filename; do
    [[ "$filename" == "openclaw.json" ]] || continue
    log "Config change detected"
    if check_maintenance; then
        log "$_MSG_MAINTENANCE_SKIPPED"
        continue
    fi
    (
        flock -w 60 9 || { log "Lock timeout, skipping this change"; exit 1; }
        handle_change
    ) 9>"$LOCK_FILE"
done
