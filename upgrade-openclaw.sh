#!/bin/bash
# upgrade-openclaw.sh — Safe OpenClaw upgrade with automatic maintenance mode
# Usage: bash upgrade-openclaw.sh [version]
#   version: optional npm version tag (default: latest)
#
# This script:
#   1. Enables maintenance mode (pauses guardian monitoring)
#   2. Upgrades OpenClaw via npm
#   3. Validates config
#   4. Disables maintenance mode (triggers upgrade notification)
#   5. On any failure: disables maintenance mode and aborts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

VERSION="${1:-latest}"
MANAGED_RESTART_FLAG="/tmp/guardian-managed-restart"

log "=== OpenClaw upgrade started (target: $VERSION) ==="

# ── Trap: always clean up maintenance mode on exit ────────────────────────────
cleanup() {
    if [ -f "$MAINTENANCE_FLAG" ]; then
        log "⚠️  Cleanup: removing maintenance flag"
        rm -f "$MAINTENANCE_FLAG"
    fi
}
trap cleanup EXIT

# ── Step 1: Enable maintenance mode ──────────────────────────────────────────
log "[1/4] Enabling maintenance mode..."
touch "$MAINTENANCE_FLAG"
# Give guardian time to detect and send the "maintenance ON" notification
sleep 8
log "[1/4] Maintenance mode active"

# ── Step 2: Upgrade OpenClaw ──────────────────────────────────────────────────
log "[2/4] Running: npm install -g openclaw@$VERSION"
if ! npm install -g "openclaw@$VERSION" 2>&1 | tee -a "$LOG"; then
    log "❌ npm upgrade failed — aborting"
    exit 1
fi

NEW_VERSION=$(openclaw --version 2>/dev/null)
log "[2/4] Upgrade complete: $NEW_VERSION"

# ── Step 3: Validate config ───────────────────────────────────────────────────
log "[3/4] Validating config..."
result=$(openclaw config validate 2>&1)
if echo "$result" | grep -qi "error\|invalid\|failed"; then
    log "❌ Config validation failed after upgrade: $result"
    log "⚠️  Attempting rollback..."
    if rollback; then
        log "✅ Config rolled back successfully"
    else
        log "🚨 Rollback failed — manual intervention required"
    fi
    exit 1
fi
log "[3/4] Config valid ✅"

# ── Step 4: Disable maintenance mode → triggers upgrade notification ──────────
log "[4/4] Disabling maintenance mode (upgrade notification will be sent)..."
rm -f "$MAINTENANCE_FLAG"
trap - EXIT  # Cancel cleanup trap (already cleaned up)

log "=== Upgrade complete: $NEW_VERSION ==="
