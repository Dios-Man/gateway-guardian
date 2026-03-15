# Changelog

All notable changes to gateway-guardian are documented here.

## [1.4.0] - 2026-03-15

### Added

- **Maintenance mode** (`touch ~/.openclaw/.guardian-maintenance`)
  - Pauses config monitoring during planned operations (upgrades, config edits)
  - Guardian sends a Feishu/Telegram/Discord notification when maintenance mode turns on/off
  - Monitoring resumes automatically when the file is deleted
  - Startup validation is also skipped while maintenance mode is active

- **Upgrade-aware notifications**
  - New managed restart flag type `upgrade` (write `echo "upgrade" > /tmp/guardian-managed-restart` before upgrading)
  - When gateway recovers after an upgrade, notification reads "OpenClaw upgrade detected — gateway restarted automatically" instead of the generic restart message
  - Distinguishes planned upgrade restarts from crash recovery and manual restarts

- **Maintenance mode language strings** (zh + en)
  - `_MSG_MAINTENANCE_ON` / `_MSG_MAINTENANCE_OFF` / `_MSG_MAINTENANCE_SKIPPED`
  - `_MSG_UPGRADE_DETECTED`

### Motivation

Discovered during a live OpenClaw upgrade (2026-03-15): guardian could not be stopped via
`pkill` because systemd auto-restarted it immediately. The only workaround was
`systemctl --user stop openclaw-config-watcher.service`, which required remembering the exact
service name. The maintenance flag provides a simpler, script-friendly alternative.

Also observed that guardian's gateway-restart notification used the generic "restart complete"
message even when triggered by an upgrade — making it hard to tell in chat history whether
the restart was intentional.

---

## [1.3.0] - 2026-03-08

### Added
- Dynamic session detection: finds the most recently active direct session at runtime
- `guardian.conf` fallback when session detection fails
- Bilingual support (zh/en): all notifications and log messages in both languages
- `LOCALE` setting in `guardian.conf` (auto-detected from user's conversation language)

### Changed
- Notifications now use `openclaw message send` instead of hardcoded curl calls
- SKILL.md includes `LOCALE` configuration instructions

---

## [1.2.0] - 2026-03-05

### Added
- `gateway-recovery.sh`: systemd OnFailure handler for crash recovery
- `pre-stop.sh`: ExecStopPost hook — sends "gateway restarting" notification before clean stops
- Background monitor in `config-watcher.sh`: detects gateway down→up transitions
- `MANAGED_RESTART_FLAG` coordination to avoid duplicate notifications across scripts

### Changed
- Three-layer architecture: config watcher + crash recovery + pre-stop hook

---

## [1.1.0] - 2026-03-02

### Added
- Timestamp-based config backups (`~/.openclaw/config-backups/`)
- Multi-source rollback: timestamp backups → openclaw native backups
- Lock file (`/tmp/openclaw-config.lock`) prevents concurrent config writes

---

## [1.0.0] - 2026-02-28

### Initial release
- `config-watcher.sh`: inotifywait-based config file monitor
- Auto-rollback on invalid config (JSON syntax + openclaw schema validation)
- Feishu notification on rollback success/failure
- systemd user service (`openclaw-config-watcher.service`)
