#!/bin/bash
# pre-stop.sh — Gateway 停止时的 ExecStopPost 钩子
# 由 systemd ExecStopPost 触发，通过 SKILL.md 安装，不可单独手动执行
# 环境变量 SERVICE_RESULT / EXIT_CODE 由 systemd 注入

LOG="/tmp/config-watcher.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

# SERVICE_RESULT 可能值：
#   success / signal → 正常停止（systemctl stop / restart）
#   exit-code / core-dump / watchdog / ... → 崩溃
# 崩溃场景由 recovery.sh（OnFailure）处理，此处跳过，避免重复通知
case "${SERVICE_RESULT:-}" in
    success|signal)
        # 若 recovery.sh 已经设置了 flag，说明是它发起的重启，跳过避免覆盖
        if [ "$(cat "$MANAGED_RESTART_FLAG" 2>/dev/null)" = "recovery" ]; then
            log "[pre-stop] 检测到 recovery.sh 托管重启，跳过通知"
        else
            log "[pre-stop] 网关正常停止，发送重启通知"
            echo "managed" > "$MANAGED_RESTART_FLAG"
            notify_status "⚙️ 网关正在重启中，请稍候..."
        fi
        ;;
    *)
        log "[pre-stop] 网关异常退出（SERVICE_RESULT=${SERVICE_RESULT}），跳过（由 recovery.sh 处理）"
        ;;
esac
