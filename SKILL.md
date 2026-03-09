---
name: gateway-guardian
description: >
  Protect and auto-recover the OpenClaw gateway from config corruption and crashes.
  Provides real-time config monitoring (3-layer validation + auto-rollback),
  systemd OnFailure crash recovery, and instant notifications via Feishu/Telegram/Discord.
  Use when: (1) user sends a GitHub link and says "帮我安装" / "install this" to install the skill,
  (2) user asks to check status: "gateway-guardian 状态" / "guardian 运行正常吗",
  (3) user asks to uninstall: "卸载 gateway-guardian" / "uninstall gateway-guardian".
---

# Gateway Guardian Skill

## 触发条件
用户发送 GitHub 链接并说"帮我安装"、"安装这个 skill"、"install this" 等。

---

## 安装流程（AI 执行）

### 前置检查
1. 确认系统为 Linux，且 systemd --user 可用
2. 检测 inotify-tools 是否已安装，**未安装则自动安装**：
   ```bash
   if ! which inotifywait > /dev/null 2>&1; then
       sudo apt-get install -y inotify-tools
   fi
   ```
3. 确认 openclaw 已安装且 Gateway 正在运行

### 确定通知兜底配置
从当前消息元数据中读取：
- `channel`：消息渠道（feishu / telegram / discord 等）
- `chat_type`：对话类型（direct / group）
- `sender_id`

确定 `FALLBACK_TARGET`（动态检测失败时使用）：
- **Feishu**：`user:{sender_id}`（无论私聊还是群聊，均发私信）
- **Telegram**：`chat_id`（私聊直接用；群聊则询问用户 Telegram 数字 ID）
- **Discord**：询问用户 DM channel ID

### 执行安装步骤

**Step 1：备份当前配置文件（安装前保护）**
```bash
TIMESTAMP_DIR="$HOME/.openclaw/config-backups"
mkdir -p "$TIMESTAMP_DIR"
cp "$HOME/.openclaw/openclaw.json" \
   "$TIMESTAMP_DIR/openclaw.json.$(date +%Y%m%d-%H%M%S).preinstall"
echo "备份完成：$(ls -t $TIMESTAMP_DIR | head -1)"
```

**Step 2：下载文件**
```bash
SKILL_DIR="$HOME/.openclaw/workspace/skills/gateway-guardian"
mkdir -p "$SKILL_DIR"
BASE_URL="https://raw.githubusercontent.com/Dios-Man/gateway-guardian/main"
for f in config-lib.sh config-watcher.sh gateway-recovery.sh pre-stop.sh SKILL.md; do
    curl -fsSL "$BASE_URL/$f" -o "$SKILL_DIR/$f"
done
```

**Step 3：生成 guardian.conf（兜底通知配置）**
```bash
cat > "$SKILL_DIR/guardian.conf" << EOF
FALLBACK_CHANNEL={检测到的 channel}
FALLBACK_TARGET={确定的 fallback target}
EOF
```

**Step 4：赋予执行权限**
```bash
chmod +x "$SKILL_DIR/config-watcher.sh"
chmod +x "$SKILL_DIR/gateway-recovery.sh"
chmod +x "$SKILL_DIR/pre-stop.sh"
```

**Step 5：注册 config-watcher systemd 服务**
```bash
SKILL_DIR="$HOME/.openclaw/workspace/skills/gateway-guardian"
cat > ~/.config/systemd/user/openclaw-config-watcher.service << EOF
[Unit]
Description=OpenClaw Gateway Guardian - File Watcher
After=openclaw-gateway.service

[Service]
Type=simple
ExecStart=/bin/bash $SKILL_DIR/config-watcher.sh
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
```

**Step 6：注册 gateway-recovery systemd 服务**
```bash
SKILL_DIR="$HOME/.openclaw/workspace/skills/gateway-guardian"
cat > ~/.config/systemd/user/openclaw-recovery.service << EOF
[Unit]
Description=OpenClaw Gateway Guardian - Gateway Recovery
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SKILL_DIR/gateway-recovery.sh
EOF
```

**Step 7：注册 OnFailure drop-in + ExecStopPost 钩子**
```bash
SKILL_DIR="$HOME/.openclaw/workspace/skills/gateway-guardian"
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d/
cat > ~/.config/systemd/user/openclaw-gateway.service.d/recovery.conf << EOF
[Unit]
OnFailure=openclaw-recovery.service

[Service]
StartLimitBurst=3
StartLimitIntervalSec=60
ExecStopPost=/bin/bash $SKILL_DIR/pre-stop.sh
EOF
```

**Step 8：启动服务**
```bash
systemctl --user daemon-reload
systemctl --user enable openclaw-config-watcher.service
systemctl --user start openclaw-config-watcher.service
```

**Step 9：验证安装**
```bash
systemctl --user status openclaw-config-watcher.service
cat ~/.config/systemd/user/openclaw-gateway.service.d/recovery.conf
tail -5 /tmp/config-watcher.log
```

**Step 10：回复用户安装结果**，格式如下：

---
✅ **Gateway Guardian 安装完成**

🔔 通知渠道：{channel}（兜底目标：{FALLBACK_TARGET}）
📋 服务状态：{systemctl status 输出中的 Active 行}
📝 日志路径：`/tmp/config-watcher.log`

**如果安装后出现异常，一键还原：**
```bash
# 卸载 Gateway Guardian（完整移除所有服务和钩子）
systemctl --user stop openclaw-config-watcher.service
systemctl --user disable openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-recovery.service
rm -f ~/.config/systemd/user/openclaw-gateway.service.d/recovery.conf
systemctl --user daemon-reload
systemctl --user reset-failed openclaw-gateway.service 2>/dev/null
```

或者直接告诉我："卸载 gateway-guardian"，我会自动执行。
---

---

## 状态检查（AI 执行）

用户说"检查 gateway-guardian 状态"、"guardian 运行正常吗"等：

```bash
systemctl --user status openclaw-config-watcher.service
tail -10 /tmp/config-watcher.log
ls -lt ~/.openclaw/config-backups/ | head -5
```

汇报：服务状态、最近日志、备份数量。

---

## 卸载流程（AI 执行）

用户说"卸载 gateway-guardian"、"uninstall gateway-guardian"等：

```bash
systemctl --user stop openclaw-config-watcher.service
systemctl --user disable openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-gateway.service.d/recovery.conf
rm -f ~/.config/systemd/user/openclaw-recovery.service
systemctl --user daemon-reload
systemctl --user reset-failed openclaw-gateway.service 2>/dev/null
# 可选：保留备份文件，或询问用户是否删除
# rm -rf ~/.openclaw/config-backups/
```

---

## 注意事项
- 本 skill 只能通过 OpenClaw 安装，不提供手动安装脚本
- 安装时必须有消息上下文（不支持控制台安装）
- guardian.conf 包含兜底通知配置，属于用户私有数据，不上传 GitHub
- .bak* 文件由 OpenClaw 原生管理，本 skill 只读不写
- 通知渠道动态检测：每次通知时自动查询最近活跃 session，无需手动绑定
