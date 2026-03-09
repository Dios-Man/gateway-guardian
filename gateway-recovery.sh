#!/bin/bash
# gateway-recovery.sh — Gateway 崩溃恢复脚本
# 由 systemd OnFailure 触发，通过 SKILL.md 安装，不可单独手动执行

LOG="/tmp/gateway-recovery.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

GATEWAY_TIMEOUT=30

log "========================================="
log "🚨 Gateway 多次重启失败，进入恢复流程"

(
    flock -w 60 9 || { log "❌ 获取锁超时，放弃恢复"; exit 1; }

    # [1/3] 验证配置，必要时回滚
    log "--- [1/3] 检查配置 ---"
    ROLLED_BACK=0
    result=$(validate_file "$CONFIG" 2>&1)
    if [ $? -ne 0 ]; then
        log "❌ 配置有问题：$result"
        if rollback; then
            log "✅ 配置已回滚"
            ROLLED_BACK=1
        else
            log "🚨 配置损坏且无合法备份"
            write_to_memory "- 事件：网关崩溃，配置损坏且无合法备份
- 结果：❌ 无法自动恢复，需要人工处理
- 日志：$LOG"
            notify_urgent "🚨 OpenClaw 网关守护 - 需要人工处理" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：网关崩溃，配置文件损坏且无可用备份
❌ 原因：所有备份均无效，无法自动恢复
📝 最近日志：
$(tail_log "$LOG")"
            exit 1
        fi
    else
        log "✅ 配置正常"
    fi

    # [2/3] 重启网关（标记为托管重启，通知由本脚本发出）
    log "--- [2/3] 重启 Gateway ---"
    echo "recovery" > "$MANAGED_RESTART_FLAG"
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null
    systemctl --user restart openclaw-gateway.service

    # [3/3] 等待网关启动（最多 GATEWAY_TIMEOUT 秒）
    log "--- [3/3] 等待网关启动（最多 ${GATEWAY_TIMEOUT}s）---"
    elapsed=0
    while [ $elapsed -lt $GATEWAY_TIMEOUT ]; do
        nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null && {
            log "✅ Gateway 恢复成功"
            # flag 由 monitor 删除，避免 monitor 在此之前轮询时误判为人工修复

            if [ "$ROLLED_BACK" = "1" ]; then
                notify_success "✅ OpenClaw 网关守护" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：网关崩溃，检测到配置损坏，已自动回滚并重启
🔧 回滚至：${ROLLBACK_USED_BACKUP:-最近备份}
✅ 结果：网关已恢复正常运行"
            else
                notify_success "✅ OpenClaw 网关守护" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：网关崩溃（配置正常），已自动重启
🔧 处置：重置失败记录 + 重启网关
✅ 结果：网关已恢复正常运行"
            fi
            exit 0
        }
        sleep 5; elapsed=$((elapsed + 5))
        log "⏳ 等待中... ${elapsed}s/${GATEWAY_TIMEOUT}s"
    done

    rm -f "$MANAGED_RESTART_FLAG"
    log "❌ ${GATEWAY_TIMEOUT}s 内未响应"
    log "$(systemctl --user status openclaw-gateway.service 2>&1 | tail -5)"
    write_to_memory "- 事件：网关崩溃，自动恢复失败
- 结果：❌ ${GATEWAY_TIMEOUT}s 内仍无响应，需要人工处理
- 日志：$LOG"
    notify_urgent "🚨 OpenClaw 网关守护 - 需要人工处理" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：网关崩溃，自动恢复失败
❌ 原因：重启后 ${GATEWAY_TIMEOUT}s 内仍无响应
📝 恢复日志：
$(tail_log "$LOG")
🔍 网关日志：
$(gateway_journal_errors)"
    exit 1

) 9>"$LOCK_FILE"

exit $?
