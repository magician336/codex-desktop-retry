# Codex Desktop 自动重试包装器（Windows）

这个脚本监控 Codex Desktop 写入的 JSONL/日志文件，发现容量类错误后按退避时间调用桌面界面的 Retry/重试按钮，不结束 Codex 进程。

## 使用

先启动 Codex Desktop，然后在 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\codex-desktop-retry.ps1
```

默认只监控 `$HOME\.codex`，避免递归扫描整个 `%LOCALAPPDATA%\Packages` 造成检测延迟。已发现的日志文件每 250 毫秒检查一次长度变化，文件列表每 2 秒刷新一次。若实际日志目录不同，可传入实际存在的目录：

```powershell
.\codex-desktop-retry.ps1 -LogRoot "$env:USERPROFILE\.codex","$env:LOCALAPPDATA\Packages"
```

默认持续运行且不限制重试次数，检测到错误后立即点击 Retry。成功点击后会重置当前计数。状态追加写入 `retry-state.json`。如果传入 `-MaxRetries N`，达到 N 次后只重置计数并继续监控，不会退出。若需要退避，可传入 `-BackoffSeconds 30,60,120`。

点击后不会立即判定成功。脚本会在同一 session 的 rollout 文件中等待新的正常 turn/输出事件，默认等待 30 秒；没有确认到新活动时记录 `retry-unconfirmed`，避免把“鼠标点到了”误报成“任务已经恢复”。可用 `-RetryConfirmSeconds 60` 调整确认窗口。

多会话运行时，脚本会从出错的 rollout JSONL 提取 `session_id`，再优先从 `$HOME\.codex\session_index.jsonl` 读取该会话在 Sidebar 中的真实 `thread_name`，然后定位会话并点击其中的 Retry。若侧边栏没有暴露对应会话，脚本会记录 `retry-failed` 并拒绝点击当前会话，避免误重试别的任务。

## 重要限制

脚本使用 Windows UI Automation 查找 ChatGPT/Codex 主窗口中名称为 `Retry`、`Try again`、`重试` 或 `再次尝试` 的按钮并调用它。默认会查找 `ChatGPT`、`Codex` 和 `OpenAI.Codex` 进程；也可以手动指定：

如果 ChatGPT 没有暴露 Retry 名称，脚本会在已确认的容量错误会话中寻找输入框右下角的 composer 主按钮（CSS 类包含 `bg-composer-primary`），并调用或点击它。

```powershell
.\codex-desktop-retry.ps1 -ProcessName ChatGPT
```

UI 更新后如果按钮名称变化，脚本会记录 `retry-failed` 并继续监控，不会杀进程。脚本不会修改认证文件，也不会切换模型或账户。

如果仍然提示找不到 Retry，查看同目录的 `ui-controls.log`。它记录了 ChatGPT 暴露给 Windows UI Automation 的控件名称、AutomationId 和控件类型，可用于适配新版界面。
