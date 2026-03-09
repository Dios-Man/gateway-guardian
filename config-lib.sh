#!/bin/bash
# config-lib.sh — OpenClaw Gateway Guardian 共享库
# 不可单独执行，由 config-watcher.sh / gateway-recovery.sh / pre-stop.sh source

# 确保 openclaw CLI 可用（systemd 环境 PATH 不完整）
export PATH="$HOME/.npm-global/bin:/usr/local/bin:$PATH"

# ── 路径常量 ──────────────────────────────────────────────────
CONFIG="$HOME/.openclaw/openclaw.json"
BACKUP_DIR="$HOME/.openclaw"
TIMESTAMP_DIR="$HOME/.openclaw/config-backups"
MEMORY_DIR="$HOME/.openclaw/workspace/memory"
LOCK_FILE="/tmp/openclaw-config.lock"
MANAGED_RESTART_FLAG="/tmp/guardian-managed-restart"
MAX_BACKUPS=10
MAX_BROKEN=5
GATEWAY_PORT=18789

# ── 兜底通知配置（由 install 生成，动态检测失败时使用）──────
_GUARDIAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_GUARDIAN_LIB_DIR/guardian.conf" ] && source "$_GUARDIAN_LIB_DIR/guardian.conf"
# guardian.conf 内容示例：
#   FALLBACK_CHANNEL=feishu
#   FALLBACK_TARGET=user:ou_xxx

# ── 工具函数 ──────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# ── 动态 Session 检测 ─────────────────────────────────────────
# 查询最近活跃的对话 session，优先 direct，兜底 guardian.conf
detect_session() {
    local session_key kind id
    session_key=$(timeout 10 openclaw sessions --json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    sessions = data.get('sessions', [])
    # 排除心跳 session（key 以 :main 结尾）
    real = [s for s in sessions if not s['key'].endswith(':main')]
    # 优先 direct，再 group
    direct = [s for s in real if ':direct:' in s['key']]
    target = direct if direct else real
    target.sort(key=lambda x: x.get('updatedAt', 0), reverse=True)
    if target:
        print(target[0]['key'])
except Exception:
    pass
" 2>/dev/null)

    if [ -z "$session_key" ]; then
        # 兜底：guardian.conf
        DETECTED_CHANNEL="$FALLBACK_CHANNEL"
        DETECTED_TARGET="$FALLBACK_TARGET"
        return
    fi

    # 解析 session key: agent:main:feishu:direct:ou_xxx
    local agent channel kind id
    IFS=':' read -r _ agent channel kind id <<< "$session_key"
    DETECTED_CHANNEL="$channel"
    [ "$kind" = "direct" ] && DETECTED_TARGET="user:$id" || DETECTED_TARGET="chat:$id"
}

# ── 通知函数 ──────────────────────────────────────────────────
# 内部发送（detect_session 须已调用，DETECTED_CHANNEL/TARGET 已设置）
_send_notify() {
    local msg="$1"
    [ -z "$DETECTED_CHANNEL" ] && { log "⚠️  通知未配置，跳过"; return; }
    timeout 30 openclaw message send \
        --channel "$DETECTED_CHANNEL" \
        --target  "$DETECTED_TARGET" \
        --message "$msg" >> "$LOG" 2>&1 || log "⚠️  通知发送失败"
}

# 成功通知（含"转发给我"提示）
notify_success() {
    local title="$1"  # 第一行标题
    local body="$2"   # 中间正文（事件/处置/日志）
    detect_session
    local msg="${title}

${body}

💬 如果此次告警是由我的操作引起的，请将这条消息直接转发给我，无需添加任何说明，我会自动了解情况并继续处理。"
    _send_notify "$msg"
}

# 紧急通知（需人工处理，不含转发提示）
notify_urgent() {
    local title="$1"
    local body="$2"
    detect_session
    local msg="${title}

${body}

请登录服务器手动处理。"
    _send_notify "$msg"
}

# 状态通知（纯消息，无附加提示）
notify_status() {
    detect_session
    _send_notify "$1"
}

# ── 写入今日内存日志 ─────────────────────────────────────────
write_to_memory() {
    local content="$1"
    mkdir -p "$MEMORY_DIR"
    local file="$MEMORY_DIR/$(date +%Y-%m-%d).md"
    echo "" >> "$file"
    echo "## 🚨 网关守护事件 ($(date '+%H:%M'))" >> "$file"
    echo "$content" >> "$file"
}

# 从日志文件中提取最近 N 条结构化日志（过滤插件加载噪音）
tail_log() {
    local logfile="$1" n="${2:-8}"
    grep "^\[20" "$logfile" 2>/dev/null | tail -n "$n"
}

# 从 journalctl 中提取网关错误信息
# 优先：关键词匹配（error/fail/invalid/EADDRINUSE 等）
# 兜底：最后 5 行
gateway_journal_errors() {
    local lines
    lines=$(journalctl --user -u openclaw-gateway.service \
        --no-pager -n 30 --output=short 2>/dev/null)
    local filtered
    filtered=$(echo "$lines" | \
        grep -iE "error|fail|invalid|cannot|eaddrinuse|exit code|exited.*status=[^0]" | \
        tail -5)
    if [ -n "$filtered" ]; then
        echo "$filtered"
    else
        # 无匹配时只取 systemd 服务管理行（避免泄露用户消息内容）
        echo "$lines" | grep -E "systemd\[|Started|Stopped|Failed|Activating|Deactivating|exited|status=" | tail -5
    fi
}

# ── 验证函数（三关）─────────────────────────────────────────
# 用法: validate_file <path>
# 成功返回 0，失败返回 1 并输出原因
validate_file() {
    local file="$1" result exit_code
    local tmp="$CONFIG.validate.tmp"

    # 第一+二关：JSON 语法 + 关键字段（单次 python3 调用）
    result=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert 'gateway' in d and 'port' in d.get('gateway', {}), 'missing gateway.port'
except AssertionError as e:
    print(e); sys.exit(1)
except Exception as e:
    print('JSON error:', e); sys.exit(1)
" "$file" 2>&1) || { echo "$result"; return 1; }

    # 第三关：openclaw schema 验证
    # 若 file 就是 CONFIG 本身，直接验证；否则临时替换
    if [ "$file" = "$CONFIG" ]; then
        result=$(timeout 30 openclaw config validate 2>&1)
        exit_code=$?
    else
        cp "$CONFIG" "$tmp" 2>/dev/null || { echo "cannot read config file"; return 1; }
        if ! cp "$file" "$CONFIG" 2>/dev/null; then
            cp "$tmp" "$CONFIG"; rm -f "$tmp"
            echo "cannot copy file to config"; return 1
        fi
        result=$(timeout 30 openclaw config validate 2>&1)
        exit_code=$?
        cp "$tmp" "$CONFIG" && rm -f "$tmp"
    fi

    if [ $exit_code -ne 0 ] || echo "$result" | grep -qi "error\|invalid\|failed"; then
        echo "$result"; return 1
    fi
    return 0
}

# ── 备份函数 ──────────────────────────────────────────────────
save_backup() {
    local bak count
    mkdir -p "$TIMESTAMP_DIR"
    bak="$TIMESTAMP_DIR/openclaw.json.$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG" "$bak"
    count=$(ls "$TIMESTAMP_DIR/" | wc -l)
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$TIMESTAMP_DIR/" | tail -n +$((MAX_BACKUPS + 1)) | \
            while IFS= read -r f; do rm -f "$TIMESTAMP_DIR/$f"; done
    fi
    log "💾 备份已保存：$(basename "$bak")"
}

cleanup_broken() {
    ls -t "$BACKUP_DIR"/openclaw.json.broken.* 2>/dev/null | \
        tail -n +$((MAX_BROKEN + 1)) | \
        while IFS= read -r f; do rm -f "$f"; done
}

# ── 回滚函数 ──────────────────────────────────────────────────
# 成功回滚后，将实际使用的备份名写入此变量（供 handle_change 显示）
ROLLBACK_USED_BACKUP=""

rollback() {
    local result bak
    ROLLBACK_USED_BACKUP=""

    # 优先：时间戳备份（最新 → 最旧）
    while IFS= read -r f; do
        bak="$TIMESTAMP_DIR/$f"
        result=$(validate_file "$bak" 2>&1)
        if [ $? -eq 0 ]; then
            cp "$CONFIG" "$CONFIG.broken.$(date +%Y%m%d-%H%M%S)"
            cp "$bak" "$CONFIG"
            ROLLBACK_USED_BACKUP="$f"
            log "✅ 已回滚到时间戳备份：$f"
            cleanup_broken; return 0
        fi
        log "⏭️  $f 无效（$result），跳过"
    done < <(ls -t "$TIMESTAMP_DIR/" 2>/dev/null)

    # 兜底：openclaw 原生备份
    for bak in "$BACKUP_DIR/openclaw.json.bak" \
               "$BACKUP_DIR/openclaw.json.bak.1" \
               "$BACKUP_DIR/openclaw.json.bak.2" \
               "$BACKUP_DIR/openclaw.json.bak.3" \
               "$BACKUP_DIR/openclaw.json.bak.4"; do
        [ -f "$bak" ] || continue
        result=$(validate_file "$bak" 2>&1)
        if [ $? -eq 0 ]; then
            cp "$CONFIG" "$CONFIG.broken.$(date +%Y%m%d-%H%M%S)"
            cp "$bak" "$CONFIG"
            ROLLBACK_USED_BACKUP="$(basename "$bak")"
            log "✅ 已回滚到原生备份：$(basename "$bak")"
            cleanup_broken; return 0
        fi
        log "⏭️  $(basename "$bak") 无效（$result），跳过"
    done

    log "❌ 所有备份均无效，无法回滚"
    return 1
}

# ── 核心处理逻辑 ──────────────────────────────────────────────
handle_change() {
    local result rollback_name
    result=$(validate_file "$CONFIG" 2>&1)
    if [ $? -eq 0 ]; then
        log "✅ 配置合法，保存备份"
        save_backup
        return
    fi

    log "❌ 配置无效：$result，开始回滚..."
    if rollback; then
        log "🔄 回滚完成，检查网关状态..."

        # 检查网关是否仍在运行（若宕机则尝试重启）
        if nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null; then
            log "✅ 网关运行正常"
        else
            log "⚠️  网关未响应，尝试重启..."
            # 用 "watcher" 标记，与 pre-stop.sh 的 "managed" 区分
            echo "watcher" > "$MANAGED_RESTART_FLAG"
            systemctl --user restart openclaw-gateway.service 2>/dev/null
            local elapsed=0
            while [ $elapsed -lt 30 ]; do
                sleep 5; elapsed=$((elapsed + 5))
                nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null && break
            done
            if ! nc -z 127.0.0.1 $GATEWAY_PORT 2>/dev/null; then
                rm -f "$MANAGED_RESTART_FLAG"
                log "❌ 网关重启失败"
                notify_urgent "🚨 OpenClaw 网关守护 - 需要人工处理" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：配置文件损坏，已回滚，但网关无法重启
❌ 原因：回滚后网关仍无响应（30s 超时）
📝 最近日志：
$(tail_log "$LOG")"
                return
            fi
            # flag 由 monitor 删除，避免 race condition
        fi

        notify_success "✅ OpenClaw 网关守护" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：配置文件损坏，已自动回滚并恢复
🔧 回滚至：${ROLLBACK_USED_BACKUP:-最近备份}
📝 关键日志：
$(tail_log "$LOG" 5)"

    else
        log "🚨 回滚失败，需要人工处理"
        notify_urgent "🚨 OpenClaw 网关守护 - 需要人工处理" \
"⏰ 时间：$(date '+%Y-%m-%d %H:%M')
📋 事件：配置文件损坏，且所有备份均无效
❌ 原因：无可用备份，无法自动恢复
📝 最近日志：
$(tail_log "$LOG")"
        write_to_memory "- 事件：配置文件损坏，所有备份均无效
- 结果：❌ 无法自动恢复，需要人工处理
- 日志：$LOG"
    fi
}
