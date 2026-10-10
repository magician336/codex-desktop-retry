# Codex Desktop 自动重试监控器

Windows 上运行的 Codex Desktop 本地自动重试工具。它持续读取 Codex Desktop 写入的 rollout JSONL 日志，在识别到“模型容量不足”类错误后，定位原会话并调用已验证的 **Retry / Try again / 重试** 控件。

推荐从本地 Web UI 启动：UI 负责启动和管理监控器，展示会话统计、事件时间线和失败原因；真正的日志解析、重试判断和 Windows UI Automation 仍由 PowerShell 监控器完成。所有数据默认只在本机处理，不上传 rollout 内容。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 适用环境

- Windows 10/11
- 已启动并登录的 Codex Desktop（或暴露兼容 UI 的 ChatGPT Desktop）
- Windows PowerShell 5.1 或 PowerShell 7
- 若启用“原生鼠标回退”，必须有可交互的前台桌面；锁屏或断开的远程桌面可能无法点击

## 推荐启动方式：本地 Web UI

1. 启动并登录 Codex Desktop。
2. 在本仓库目录打开 PowerShell，执行：

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\codex-desktop-retry-ui.ps1
   ```

3. 脚本会监听 `http://127.0.0.1:8765/`、自动打开浏览器，并自动启动后台监控器。若浏览器没有自动打开，手动访问该地址即可。
4. 在“监控概览”确认状态为“运行中”，再继续使用 Codex Desktop。需要停止时关闭控制台窗口；也可以在 UI 中暂停监控。

控制台只绑定回环地址 `127.0.0.1`，默认不会暴露到局域网。端口被占用时可换端口：

```powershell
.\codex-desktop-retry-ui.ps1 -Port 8766
```

不希望自动打开浏览器时使用 `-NoBrowser`：

```powershell
.\codex-desktop-retry-ui.ps1 -NoBrowser
```

### UI 中可以做什么

- **概览**：查看监控进程、容量错误、尝试次数、确认成功和失败总数。
- **监听会话**：按 Codex 会话查看错误、尝试、成功、失败及最后事件。
- **活动记录**：查看最近保留的状态事件。
- **设置**：修改日志目录、冷却时间、确认超时、最大重试次数、退避序列和进程名。
- **开机启动**：可选“登录时自动启动控制台”，使用当前用户的任务计划，不需要管理员权限。
- **允许原生鼠标回退**：只应在 UI Automation 无法点击且确实有前台桌面时开启。

保存设置会重启后台监控器，使新参数立即生效。暂停只暂停检测和自动重试，监控进程仍在运行，历史状态不会被清除；恢复后继续工作。

## 工作原理

```text
Codex Desktop
    │ 写入 rollout-*.jsonl
    ▼
日志监听与增量解析
    │ 识别容量错误，按 session_id 建立独立状态
    ▼
会话定位与 UI Automation
    │ 校验当前会话、查找可见且启用的 Retry 控件
    ▼
Retry / Try again
    │ 已验证点击即记为一次成功
    ▼
retry-clicked / retry-failed
    │
本地状态 JSONL → Web UI 统计与时间线
```

实现分为四层：

1. **日志层**使用 `FileSystemWatcher` 监听新增和变更文件，并按增量偏移读取 JSONL；同时按 `-RescanSeconds` 做低频兜底扫描。只处理 `rollout-*.jsonl`，不会把 `session_index.jsonl` 当作重试事件。
2. **状态机**以 `session_id` 隔离冷却时间、退避序列、重试次数和待处理请求。一个会话的重试额度不会被另一个会话消耗。启动时已存在的历史错误会被跳过，避免首次运行重放旧事件。
3. **UI 层**优先使用 Windows UI Automation。它会验证会话标识、必要时搜索会话、滚动内容区域，再检查 Retry 控件名称、可见性和启用状态。只有找到目标会话中的控件才会点击；原生鼠标是显式开启的最后回退。
4. **结果层**只对 UI 自动化负责：在目标会话中验证并点击 Retry 后，立即写入 `retry-clicked`，控制台将其计为一次成功。点击后服务端再次返回容量错误时，按新的容量事件单独排队，不把它归因于本次点击失败。

状态和 UI 诊断默认写入仓库目录：`retry-state.json`（含轮转副本）和 `ui-controls.log`。控制台使用这些保留文件生成统计，因此 UI 展示的是“当前文件及轮转副本”范围内的历史，不是永久数据库。

## 日常使用与参数

大多数用户只需使用 UI 设置页。需要脚本化或调试时，可直接运行监控器：

```powershell
.\codex-desktop-retry.ps1
```

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-LogRoot` | `$HOME\.codex` | rollout/log 目录，可重复传入 |
| `-ProcessName` | `ChatGPT,Codex,OpenAI.Codex` | 要查找的桌面进程名 |
| `-MaxRetries` | `0` | 每个会话的最大重试次数；`0` 表示不限制 |
| `-BackoffSeconds` | `0` | 退避序列，例如 `30,60,120` |
| `-CooldownSeconds` | `20` | 同一会话两次尝试之间的冷却时间 |
| `-RetryUiWaitSeconds` | `90` | 等待 UI 控件出现的时间 |
| `-RetryConfirmSeconds` | `30` | 兼容旧配置保留；当前不等待恢复事件 |
| `-UiLeaseSeconds` | `5` | 多会话共享桌面 UI 时的单次租约 |
| `-RescanSeconds` | `60` | 兜底重扫间隔，至少 10 秒 |
| `-AllowNativeClick` | 关闭 | 允许前台桌面鼠标回退 |

例如，指定日志目录并设置退避：

```powershell
.\codex-desktop-retry.ps1 `
  -LogRoot "$env:USERPROFILE\.codex", "$env:LOCALAPPDATA\Packages" `
  -BackoffSeconds 30,60,120 `
  -MaxRetries 5
```

仓库中的 `releases\2026-10-09\codex-desktop-retry.ps1` 是由 `scripts\build-stable.ps1` 生成的冻结版。日常开发和修复请使用根目录启动器；冻结版用于需要固定脚本内容的场景。

## 注意事项与排查

- **先启动 Codex Desktop 并登录**：工具不会启动、登录或修改 Codex 账户、模型和认证配置。
- **保持前台桌面可用**：UI Automation 通常不需要鼠标前台操作，但窗口更新、搜索和原生回退仍可能受锁屏、最小化或远程桌面断开影响。
- **不要把普通失败当容量错误**：只有匹配容量分类器的 turn 错误才会触发 Retry；其他错误会留在 Codex 原有流程中。
- **看不到会话或按钮时**：先确认当前窗口是目标 Codex Desktop，再查看 `ui-controls.log`。工具找不到已验证的会话或 Retry 控件时会记录 `retry-failed`，不会结束 Codex 进程，也不会点击未经确认的控件。
- **查看当前 UI Automation 树**：

  ```powershell
  .\tests\check-desktop.ps1
  ```

  该命令只读检查，不会点击控件。
- **日志不在默认目录**：在 UI“设置”修改日志目录，或通过 `-LogRoot` 显式指定；目录必须已经存在并能读取 rollout 文件。
- **数据边界**：`retry-state.json` 会按大小轮转，UI 只能统计当前文件和轮转副本中的事件。不要手动编辑这些状态文件来“补成功”。
- **重复启动**：UI 已经启动监控器时，不要再启动第二个同配置的根目录监控器，否则两个进程可能竞争同一桌面 UI。
- **社区项目**：本项目与 OpenAI、Codex Desktop 或 ChatGPT 官方无隶属关系。Codex Desktop UI、rollout 格式或按钮名称变化时，现有匹配逻辑可能需要更新。

## 项目结构

```text
codex-desktop-retry-ui.ps1   # 推荐入口：本地 Web 控制台与监控器生命周期
codex-desktop-retry.ps1      # 直接运行监控器的参数入口
web/                          # HTML、CSS、JavaScript 前端
retry/Retry.Logs.ps1          # 日志发现与增量 JSONL 解析
retry/Retry.State.ps1         # 会话状态与有界状态日志
retry/Retry.Monitor.ps1       # 容量错误、确认与状态机
retry/Retry.Ui.ps1            # 会话定位、导航与 Retry 控件调用
retry/Retry.Status.ps1        # UI 统计索引
retry/Retry.Rollouts.ps1      # UI 侧实时会话索引
tests/                        # 验证、启动和桌面检查脚本
scripts/build-stable.ps1      # 生成冻结版启动器
releases/                     # 已验证的冻结版
RETRY_SPEC.md                 # 设计边界和可验证行为
CONTEXT.md                    # 控制台术语与用户可见不变量
```

## 验证

在 Windows PowerShell 7 中运行：

```powershell
.\tests\validate-retry.ps1
.\tests\validate-rollout-index.ps1
.\tests\validate-status-index.ps1
.\tests\smoke-start.ps1
.\tests\smoke-stable.ps1
```

`check-desktop.ps1` 只读取当前 UI Automation 树；真实点击仍取决于当前桌面版本、窗口可见性和交互式 Windows 会话。

## 许可证

本项目采用 [MIT License](LICENSE)。
