# Gateway Guardian

> 一个给 OpenClaw 用户的网关守护 Skill。  
> 让你再也不用因为配置写错、网关崩溃而手忙脚乱地登录服务器。

---

## 它解决什么问题？

OpenClaw 的 AI 能力完全依赖网关（Gateway）。网关一旦挂掉，你就联系不上 AI 了。

常见的"网关挂掉"原因有两种：

**1. 配置文件被写坏**  
AI 在修改配置（比如加 API Key、改模型）的时候，可能因为格式错误、字段缺失，让 `openclaw.json` 变成一个无效文件。下次网关重启时，直接起不来。

**2. 网关进程意外崩溃**  
内存问题、系统资源紧张、偶发性 bug，都可能让网关在运行中突然挂掉。

Gateway Guardian 会自动处理这两种情况，并在第一时间通知你。

---

## 它做了什么？

**配置写入时：**  
每次 `openclaw.json` 发生变化，Guardian 会在毫秒内完成三关验证。验证失败就立刻回滚到上一个合法备份，整个过程你完全感知不到。

**验证三关：**
1. JSON 语法是否正确
2. 关键字段是否存在（`gateway.port` 必须有）
3. OpenClaw 自身的 schema 校验

**网关崩溃时：**  
如果网关连续崩溃 3 次（60 秒内），Guardian 会接管：检查配置是否有问题（有的话先回滚），然后重启网关，等待确认恢复。

**通知你：**  
无论是自动修复成功还是需要你手动处理，Guardian 都会第一时间推送通知到你的消息渠道（飞书/Telegram/Discord 等）。

---

## 你会收到什么通知？

**配置被自动修复（不用你操作）：**

```
✅ OpenClaw 网关守护

⏰ 时间：2026-03-09 22:10
📋 事件：配置文件损坏，已自动回滚并恢复
🔧 回滚至：openclaw.json.20260309-221005
📝 关键日志：
[22:10:03] ❌ 配置无效：missing gateway.port
[22:10:04] ✅ 已回滚到时间戳备份
[22:10:04] ✅ 网关运行正常

💬 如果此次告警是由我的操作引起的，请将这条消息
直接转发给我，无需添加任何说明，我会自动了解
情况并继续处理。
```

**需要你介入（无法自动修复）：**

```
🚨 OpenClaw 网关守护 - 需要人工处理

⏰ 时间：2026-03-09 22:10
📋 事件：网关崩溃，自动恢复失败
❌ 原因：重启后 30s 内仍无响应
📝 恢复日志：
[22:10:03] 🚨 Gateway 多次重启失败，进入恢复流程
[22:10:06] ✅ 配置正常
[22:10:06] --- 重启 Gateway ---
[22:10:36] ❌ 30s 内未响应
🔍 网关日志：
Mar 09 22:10:06 node[xxx]: Error: EADDRINUSE: port 18789 already in use

请登录服务器手动处理。
```

**网关主动重启时：**

```
⚙️ 网关正在重启中，请稍候...
```

```
✅ 网关已恢复正常（重启完成）

如需继续之前的对话，请向我发送任意消息，
我将继续完成之前未发出的回复。
```

> **关于"请将消息转发给我"：**  
> 网关重启会中断 OpenClaw 与模型 API 之间的通信，正在进行的任务因此中止。如果之前是 AI 在帮你做某件事时发生了重启，把这条通知转发给 AI，它就能立刻知道刚才发生了什么，继续完成未完成的任务。不转发也没关系，直接告诉 AI"刚才网关重启了"效果一样。

---

## 安装

只需要告诉你的 OpenClaw：

```
https://github.com/Dios-Man/gateway-guardian/blob/main/SKILL.md  帮我安装
```

OpenClaw 会自动检测你的消息渠道和用户 ID，完成全部配置。

**前置条件：**
- Linux 系统，systemd --user 可用
- inotify-tools（安装时自动检测并安装，或手动：`sudo apt-get install -y inotify-tools`）
- OpenClaw Gateway 正在运行

**安装时会做什么：**
1. 备份当前配置文件（作为安装前快照）
2. 创建 config-watcher 后台服务（常驻监听配置文件）
3. 创建 gateway-recovery 服务（网关崩溃时 OnFailure 触发）
4. 为网关服务添加 ExecStopPost 钩子（停止前发送通知）
5. 生成 `guardian.conf`（保存你的通知渠道兜底配置）

---

## 卸载

告诉 OpenClaw："卸载 gateway-guardian"

或者手动执行：

```bash
systemctl --user stop openclaw-config-watcher.service
systemctl --user disable openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-config-watcher.service
rm -f ~/.config/systemd/user/openclaw-recovery.service
rm -f ~/.config/systemd/user/openclaw-gateway.service.d/recovery.conf
systemctl --user daemon-reload
systemctl --user reset-failed openclaw-gateway.service 2>/dev/null
```

卸载不会删除已有的配置备份（`~/.openclaw/config-backups/`）。

---

## 日志查看

```bash
tail -f /tmp/config-watcher.log    # 配置监听 + 通知日志
tail -f /tmp/gateway-recovery.log  # 崩溃恢复日志
ls -lt ~/.openclaw/config-backups/ # 时间戳备份列表
```

---

## 常见问题

**Q：Guardian 会影响 OpenClaw 的正常运行吗？**  
不会。config-watcher 使用 inotifywait 常驻监听，平时接近零 CPU 占用，只在配置变化时短暂运行。

**Q：通知发不出去怎么办？**  
检查 `guardian.conf` 里的 FALLBACK_CHANNEL 和 FALLBACK_TARGET 是否正确，或者重新安装 Skill 让 OpenClaw 重新检测。

**Q：通知会发到哪里？**  
Guardian 使用动态会话检测——每次发通知前，会查询最近活跃的对话，优先发到私信。如果检测失败，则兜底使用安装时记录的渠道和用户 ID（保存在 `guardian.conf`）。

**Q：我手动改了配置，Guardian 会把我的改动回滚掉吗？**  
不会——只要你的改动是合法的（JSON 格式正确且包含必要字段），Guardian 会把它存为新备份。只有无效的配置才会被回滚。

**Q：`guardian.conf` 里的内容安全吗？**  
`guardian.conf` 只保存消息渠道和用户 ID（兜底配置），不含 API Key 或密码。该文件不会被上传到 GitHub。

---

## 技术架构

```
openclaw.json 发生变化
    ↓
config-watcher（inotifywait 常驻）
    ├─ 验证通过 → 保存时间戳备份
    └─ 验证失败 → 回滚 → 通知用户

网关进程崩溃
    ↓
systemd Restart=always（自动重启，最多3次/60s）
    ↓
StartLimitBurst 触发 OnFailure
    ↓
gateway-recovery
    ├─ 检查配置（有问题先回滚）
    ├─ 重启网关
    ├─ 等待 30s 确认
    ├─ 恢复成功 → 通知用户
    └─ 恢复失败 → 紧急通知（含错误日志）

网关主动重启
    ↓
ExecStopPost（pre-stop.sh）
    └─ 发送"重启中"通知
    ↓
config-watcher 后台监测（每5s探测）
    └─ 检测到恢复 → 发送"重启完成"通知
```

---

## License

MIT
