# Codex Desktop 自动重试监控器

一个面向 Windows 的 PowerShell 监控器：它读取 Codex Desktop 写入的 JSONL rollout
日志，在检测到模型容量类错误时定位对应会话，并调用桌面中的 **Retry / Try again /
重试** 控件。它不会结束 Codex 进程，也不会修改认证文件、模型或账户配置。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 功能

- 监控 `$HOME\.codex` 下名称符合 `rollout-*.jsonl` 的 rollout 文件，默认不递归扫描整个
  `%LOCALAPPDATA%\Packages`；`session_index.jsonl` 等索引和诊断文件不会触发重试。
- 使用 `FileSystemWatcher` 发现新增和变更文件，并按 `-RescanSeconds` 做低频兜底重扫。
- 按 `session_id` 隔离冷却时间、退避序列、重试次数和待处理队列，多会话之间不会共享计数。
- 只在触发错误的同一个 rollout 中确认恢复；确认需要匹配的 turn 输出或完成事件。
  Retry 创建没有 `parent_turn_id` 的新 turn 时，还必须观察到该 turn 的上下文和自身输出/完成事件。
- 优先使用 Windows UI Automation；原生鼠标点击是需要前台桌面的显式回退，默认关闭。
- 将运行状态和 UI 诊断写成有界 JSONL/日志文件，并使用命名互斥锁串行写入。

## 要求

- Windows 10/11
- 已启动并登录的 Codex Desktop（或暴露兼容 UI 的 ChatGPT Desktop）
- Windows PowerShell 或 PowerShell 7
- 需要使用原生鼠标回退时，必须有可交互的前台桌面；锁屏和断开的远程桌面可能无法点击。

## 快速开始

先启动 Codex Desktop，再在本仓库目录运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\codex-desktop-retry.ps1
```

### 本地 Web 控制台

如果需要可视化操作，运行本地控制台：

```powershell
.\codex-desktop-retry-ui.ps1
```

它会在 `http://127.0.0.1:8765/` 打开苹果风格的毛玻璃页面。控制台可以启动、暂停和恢复监控器，展示总计及每个会话的容量错误、成功、失败和失败原因，并在会话详情中查看事件时间线。页面通过本机 PowerShell API 工作，不上传 rollout 内容。

“设置”页可以配置日志目录、冷却时间、最大重试次数等参数，并通过当前用户任务计划设置登录自启动。暂停只暂停监控检测和自动重试，保留监控进程与历史数据；保存设置会重启监控器以确保参数一致。

统计来自 `retry-state.json` 及其轮转副本，页面会显示这一保留历史边界。控制台运行时生成的 `retry-control.json` 和 `retry-ui-settings.json` 不纳入版本控制。

如果日志不在默认目录，可以显式传入一个或多个现有目录：

```powershell
.\codex-desktop-retry.ps1 `
  -LogRoot "$env:USERPROFILE\.codex", "$env:LOCALAPPDATA\Packages"
```

仓库还保留了一个可先使用的冻结版。它由 `scripts\build-stable.ps1` 从根目录启动器和
`retry\` 模块生成；后续开发默认修改根目录版本：

```powershell
.\releases\2026-10-09\codex-desktop-retry.ps1
```

## 常用参数

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `-LogRoot` | `$HOME\.codex` | rollout/log 文件目录，可重复传入 |
| `-ProcessName` | `ChatGPT`, `Codex`, `OpenAI.Codex` | 要查找的桌面进程名 |
| `-BackoffSeconds` | `0` | 重试退避序列，例如 `30,60,120` |
| `-MaxRetries` | `0` | 每个会话的上限；`0` 表示不限制 |
| `-CooldownSeconds` | `20` | 同一会话两次尝试之间的冷却时间 |
| `-RetryConfirmSeconds` | `30` | 等待关联 turn 恢复事件的时间 |
| `-UiLeaseSeconds` | `5` | 多会话共享桌面 UI 时单次租约时长 |
| `-RescanSeconds` | `60` | 文件监听之外的低频兜底重扫间隔，至少 10 秒 |
| `-StateMaxBytes` / `-StateMaxFiles` | `1 MiB` / `3` | 状态文件大小和轮转备份数 |
| `-AllowNativeClick` | 关闭 | 允许前台桌面原生鼠标回退 |
| `-StatePath` / `-UiDiagnosticPath` | 当前目录下的文件 | 状态和 UI 诊断输出位置 |

例如，设置退避并允许原生点击：

```powershell
.\codex-desktop-retry.ps1 `
  -BackoffSeconds 30,60,120 `
  -AllowNativeClick
```

## 工作方式和限制

脚本启动时会把已存在文件的当前位置记为起点，因此启动前已经写入的容量错误会被跳过，
避免首次运行时重放历史事件。目前没有回放旧事件的开关。

点击 Retry 后不会立即记录成功。监控器会在触发错误的 rollout 中等待原 turn 的明确输出或
完成事件；如果桌面创建了新 turn，则先记录为候选，只有同一候选 turn 随后出现
`turn_context` 以及自己的输出/完成事件才会确认恢复。其他 rollout、并行 turn 或普通的
无关 assistant 输出不会确认成功。超时会写入 `retry-unconfirmed`，之后按会话冷却策略继续监控。

UI 更新导致找不到会话或 Retry 控件时，脚本会写入 `ui-controls.log` 并记录
`retry-failed`，不会为了恢复任务而结束进程或点击未经确认的会话。可以先运行下面的只读检查
查看当前 UI Automation 树：

如果 Retry 控件在错误页底部、当前不在视口内，脚本会沿已验证会话的内容区域调用 Windows
UI Automation 的 `ScrollPattern`，每次向下滚动一个较大的步长，然后重新抓取 UI 树。只有控件
进入视口、名称匹配且处于启用状态后才会点击；找不到可滚动容器时则继续按 UI 租约和冷却策略等待。

如果侧边栏没有显示对应会话，脚本会打开 Search/搜索，优先用会话标题、没有标题时用
`session_id` 查询结果；选中结果后还会再次验证当前页面的会话标识，确认无误才继续寻找 Retry。

```powershell
.\tests\check-desktop.ps1
```

## 项目结构

```text
codex-desktop-retry.ps1       # 根目录启动器和参数入口
retry\Retry.Logs.ps1          # 日志发现、缓存、增量 JSONL 解析
retry\Retry.State.ps1         # 会话状态和有界状态日志
retry\Retry.Monitor.ps1       # 容量错误、确认和 UI 租约状态机
retry\Retry.Ui.ps1            # 会话定位、导航和 Retry 控件调用
tests\                        # 临时 rollout、启动和桌面检查
scripts\build-stable.ps1      # 生成冻结版启动器
releases\                     # 已验证的冻结版
RETRY_SPEC.md                 # 设计边界和可验证行为
```

## 验证

在 Windows PowerShell 7 环境中运行：

```powershell
.\tests\validate-retry.ps1   # 日志监听、turn 确认、轮转和 UI 租约
.\tests\smoke-start.ps1      # 启动后持续运行检查
.\tests\smoke-stable.ps1     # 冻结版启动检查
```

`check-desktop.ps1` 只读取当前 UI Automation 树，不会点击控件。真实的 UI 点击行为仍依赖
当前桌面版本、窗口可见性和交互式 Windows 会话。

## 许可证

本项目采用 [MIT License](LICENSE)。

本项目是社区脚本，与 OpenAI、Codex Desktop 或 ChatGPT 官方无隶属关系。
