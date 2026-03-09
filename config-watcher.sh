#!/bin/bash
# config-watcher.sh — 监听 openclaw.json 变化，验证并在必要时回滚
# 由 systemd 服务管理，通过 SKILL.md 安装，不可单独手动执行

LOG="/tmp/config-watcher.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

log "=== config-watcher 启动 ==="

# ── 后台：网关状态监测（检测 down→up 转变）────────────────────
monitor_gateway_recovery() {
    local was_down=0

    # 初始化：延迟 10s 再开始，给 gateway 充分时间响应（After= 不保证端口就绪）
    sleep 10
    nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null || was_down=1

    while true; do
        sleep 5
        if nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null; then
            if [ "$was_down" = "1" ]; then
                was_down=0
                # 检查是否为托管重启
                if [ -f "$MANAGED_RESTART_FLAG" ]; then
                    local flag_type
                    flag_type=$(cat "$MANAGED_RESTART_FLAG" 2>/dev/null)
                    rm -f "$MANAGED_RESTART_FLAG"
                    if [ "$flag_type" = "recovery" ] || [ "$flag_type" = "watcher" ]; then
                        # recovery.sh / config-watcher 负责发通知，monitor 跳过
                        log "[monitor] 托管恢复（${flag_type}），跳过通知"
                    else
                        # 计划重启完成（pre-stop.sh 发起的 managed 重启）
                        log "[monitor] 网关重启完成"
                        notify_status "✅ 网关已恢复正常（重启完成）

如需继续之前的对话，请向我发送任意消息，我将继续完成之前未发出的回复。"
                    fi
                else
                    # 人工修复 / 未知恢复
                    log "[monitor] 网关已恢复（非托管），发送通知"
                    notify_success "✅ OpenClaw 网关守护" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：网关已恢复正常
🔧 处置：检测到网关从离线状态恢复（可能为人工修复）"
                fi
            fi
        else
            was_down=1
        fi
    done
}

monitor_gateway_recovery &
MONITOR_PID=$!
log "[monitor] 后台监测已启动（PID: $MONITOR_PID）"

# ── 启动时持锁检查当前配置 ───────────────────────────────────
(
    flock -w 60 9 || { log "启动时获取锁超时"; exit 1; }
    handle_change
) 9>"$LOCK_FILE"

# ── 监听目录（-m 常驻模式），只处理 openclaw.json 变化 ───────
inotifywait -q -m -e close_write -e moved_to \
    --format '%f' "$BACKUP_DIR" 2>>"$LOG" | \
while IFS= read -r filename; do
    [[ "$filename" == "openclaw.json" ]] || continue
    log "检测到配置变化..."
    (
        flock -w 60 9 || { log "获取锁超时，跳过本次处理"; exit 1; }
        handle_change
    ) 9>"$LOCK_FILE"
done
