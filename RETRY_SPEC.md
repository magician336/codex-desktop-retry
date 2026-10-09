# Codex Desktop 重试监控器规格

## Problem Statement

容量错误发生在多个 Codex Desktop 会话时，监控器需要持续定位正确会话并点击重试。当前实现会在确认窗口内重复递归扫描目录，使用全局冷却和计数，成功确认可能把同一会话中其他 turn 的活动当成目标任务恢复；UI 搜索、错误处理和状态日志也缺少可验证性和边界。

## Solution

将监控器拆成日志发现与缓存、会话解析、会话导航、重试执行、进度确认和状态持久化几个接缝。每个会话独立维护冷却、重试次数和确认阶段；确认只使用触发容量错误的 rollout 文件和 turn 标识，并要求明确的启动/完成事件。UI 搜索必须回读搜索框并验证结果及导航后的会话标识。目录列表由主循环缓存，状态日志使用有界轮转和进程内互斥写入。

## User Stories

1. As a desktop user, I want each failed session to have independent retry limits and cooldowns, so one busy session cannot starve another.
2. As a desktop user, I want a capacity error to select the matching session, so the retry action cannot affect another conversation.
3. As a desktop user, I want search input and results verified, so a failed search is observable instead of silently falling back.
4. As a desktop user, I want retry confirmation tied to the triggering rollout and turn, so unrelated activity cannot report success.
5. As an operator, I want directory scans reused from the monitor cache, so confirmation does not create repeated recursive I/O.
6. As an operator, I want UI failures to include stage, control, and exception details, so UI changes can be diagnosed.
7. As an operator, I want state logs bounded and serialized, so long-running monitoring cannot grow without limit or interleave records.
8. As an operator, I want startup behavior documented, so errors written before startup are not mistaken for new events.

## Implementation Decisions

- Use a shared log-file cache fed by `FileSystemWatcher`; perform a bounded recursive reconciliation only at startup and at a configurable low-frequency fallback interval. Confirmation filters cached files and never performs a recursive scan on every poll.
- Replace global retry counters with a dictionary keyed by session id, falling back to the source path only when a session id is unavailable.
- Carry source file, source offset, session id, and turn id from the capacity event into confirmation.
- Accept confirmation only for the triggering rollout after the click boundary. A matching turn may confirm with explicit output/completion events; when Codex creates a fresh turn without `parent_turn_id`, the first post-click turn start is only a candidate. That candidate must emit `turn_context` and then its own assistant output/completion before confirmation. Generic activity from before the click, a parallel turn, or another rollout is insufficient.
- Give each session a bounded UI lease. A pending or slow UI operation yields after the lease, returns to the resolve stage, and keeps its attempt counted so another session can progress without inflating retry counts.
- Separate session target resolution, navigation validation, and retry control invocation behind PowerShell functions.
- Compile the native mouse helper once and use UI Automation first; native click remains a diagnosed fallback because it requires foreground desktop input.
- Validate search text through ValuePattern and validate the selected result and post-navigation UI against the session hint.
- Allow a verified conversation content container to scroll through the UI Automation ScrollPattern when the retry control is below the viewport; never scroll the sidebar or search dialog.
- Accept a search result exposed inside the search region even when Electron also marks it as a sidebar descendant, then revalidate the active conversation before acting.
- Write JSONL state records through a named mutex and rotate the active file when it exceeds a configurable byte limit.
- Keep all sessions in the cache instead of truncating the list to a fixed number of recent files.

## Testing Decisions

- Parse the PowerShell script with the PowerShell AST before runtime tests.
- Use temporary rollout inputs as the main seam: verify watcher-discovered files, per-session state, candidate confirmation, UI lease fairness, single native helper, diagnostics, rotation, and search validation from observable state and retry outputs.
- Run a short smoke invocation with invalid arguments to verify parameter guards without opening a desktop UI.
- Runtime UI behavior remains dependent on an interactive Windows desktop and must be validated with captured UI Automation diagnostics.

## Out of Scope

- Replacing Windows UI Automation with a background or headless desktop protocol.
- Guaranteeing native mouse fallback under lock screen or disconnected Remote Desktop sessions.
- Changing Codex Desktop, rollout file formats, authentication, model selection, or account behavior.
- Publishing to an external issue tracker; no tracker endpoint or triage vocabulary is configured in this repository.

## Further Notes

The monitor still initializes file offsets to the current file length at startup. Therefore capacity errors written before startup are intentionally skipped; this behavior is documented in the README and can be changed later with an explicit replay option.
