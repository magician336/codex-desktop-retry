[CmdletBinding()]
param(
    [int] $Port = 8765,
    [switch] $NoBrowser,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'retry-ui-settings.json'),
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $ControlPath = (Join-Path $PSScriptRoot 'retry-control.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$webRoot = Join-Path $scriptRoot 'web'
$monitorScript = Join-Path $scriptRoot 'codex-desktop-retry.ps1'
$taskName = 'Codex Desktop Retry Monitor'
$monitorProcess = $null
$listener = [Net.HttpListener]::new()
. (Join-Path $PSScriptRoot 'retry\Retry.Status.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Rollouts.ps1')
$stateIndex = New-RetryStatusIndex
$liveRolloutIndex = New-RetryRolloutIndex
$stateEventsChanged = $true
$stateEventsCache = @()
$stateSessionCache = $null

function Get-PwshPath {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return (Get-Command powershell -ErrorAction Stop).Source
}

function Get-DefaultSettings {
    return [ordered]@{
        logRoot = @((Join-Path $env:USERPROFILE '.codex'))
        processName = @('ChatGPT', 'Codex', 'OpenAI.Codex')
        maxRetries = 0; backoffSeconds = @(0); pollSeconds = 0.25
        cooldownSeconds = 20; retryUiWaitSeconds = 90; retryConfirmSeconds = 30
        uiLeaseSeconds = 5; rescanSeconds = 60; allowNativeClick = $false
    }
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $defaults = Get-DefaultSettings
        $defaults | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        return [pscustomobject]$defaults
    }
    try { return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json) }
    catch { return [pscustomobject](Get-DefaultSettings) }
}

function Write-Settings($Settings) {
    $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Write-Control([bool]$Paused) {
    $parent = Split-Path -Parent $ControlPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [ordered]@{ paused = $Paused; updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $ControlPath -Encoding UTF8
}

function Get-ControlPaused {
    if (-not (Test-Path -LiteralPath $ControlPath -PathType Leaf)) { return $false }
    try { return [bool]((Get-Content -LiteralPath $ControlPath -Raw | ConvertFrom-Json).paused) } catch { return $false }
}

function Test-MonitorAlive {
    if ($script:monitorProcess -and -not $script:monitorProcess.HasExited) { return $true }
    $script:monitorProcess = $null
    return $false
}

function Start-Monitor {
    if (Test-MonitorAlive) { return }
    $settings = Read-Settings
    Write-Control $false
    $argList = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $monitorScript, '-LogRoot')) { [void]$argList.Add([string]$value) }
    [void]$argList.Add(([string](@($settings.logRoot) -join ',')))
    [void]$argList.Add('-ProcessName'); [void]$argList.Add(([string](@($settings.processName) -join ',')))
    foreach ($pair in @(
        @('-MaxRetries', [string]$settings.maxRetries), @('-BackoffSeconds', [string](@($settings.backoffSeconds) -join ',')),
        @('-PollSeconds', [string]$settings.pollSeconds), @('-CooldownSeconds', [string]$settings.cooldownSeconds),
        @('-RetryUiWaitSeconds', [string]$settings.retryUiWaitSeconds), @('-RetryConfirmSeconds', [string]$settings.retryConfirmSeconds),
        @('-UiLeaseSeconds', [string]$settings.uiLeaseSeconds), @('-RescanSeconds', [string]$settings.rescanSeconds),
        @('-StatePath', $StatePath), @('-UiDiagnosticPath', $UiDiagnosticPath), @('-ControlPath', $ControlPath)
    )) { [void]$argList.Add([string]$pair[0]); [void]$argList.Add([string]$pair[1]) }
    if ([bool]$settings.allowNativeClick) { [void]$argList.Add('-AllowNativeClick') }
    $args = @($argList.ToArray())
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-PwshPath
    $quote = { param($value) '"' + ([string]$value).Replace('"', '\"') + '"' }
    $psi.Arguments = (($args | ForEach-Object { & $quote $_ }) -join ' ')
    $psi.WorkingDirectory = $scriptRoot
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $script:monitorProcess = [Diagnostics.Process]::Start($psi)
}

function Stop-Monitor {
    if (Test-MonitorAlive) { $script:monitorProcess.Kill(); $script:monitorProcess.WaitForExit(3000) | Out-Null }
    $script:monitorProcess = $null
}

function Read-StateEvents {
    $paths = @($StatePath) + (1..3 | ForEach-Object { "$StatePath.$_" })
    $revision = $stateIndex.Stats.Revision
    $events = @(Get-RetryStatusEvents $stateIndex $paths)
    $script:stateEventsChanged = $revision -ne $stateIndex.Stats.Revision
    if ($script:stateEventsChanged) { $script:stateEventsCache = $events }
    return @($script:stateEventsCache)
}

function Get-NormalizedFailure([string]$Detail, [string]$Event) {
    if ($Event -eq 'retry-unconfirmed') { return '等待恢复事件超时' }
    if ($Event -eq 'limit-reached') { return '达到重试上限' }
    if (-not $Detail) { return '未知失败' }
    if ($Detail -match 'No visible .*window') { return '找不到 Codex 窗口' }
    if ($Detail -match 'Retry button was not found|retry control') { return '未找到 Retry 按钮' }
    if ($Detail -match '模式|pattern') { return 'UI Automation 模式不支持' }
    if ($Detail -match 'search|搜索') { return '会话搜索或导航失败' }
    if ($Detail -match 'timed out|timeout|超时') { return 'UI 操作超时' }
    return ($Detail -split "`r?`n")[0].Substring(0, [Math]::Min(96, ($Detail -split "`r?`n")[0].Length))
}

function Read-EventProperty($Event, [string]$Name) {
    $property = $Event.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return ''
}

function Get-LiveRolloutSessions {
    $settings = Read-Settings
    return @(Get-RetryLiveRolloutSessions $liveRolloutIndex @($settings.logRoot))
}

function Build-StateSessionCache($Events) {
    $sessionMap = @{}
    foreach ($event in $Events) {
        $key = [string](Read-EventProperty $event 'session')
        if (-not $key) { continue }
        if (-not $sessionMap.ContainsKey($key)) {
            $sessionMap[$key] = [ordered]@{ id = $key; title = ($key -replace '^path:', '' -replace '\\', '/'); hasRecord = $true; capacityErrors = 0; successes = 0; failures = 0; attempts = 0; firstSeen = ''; lastError = ''; lastEvent = ''; lastEventAt = ''; reasons = @{}; timeline = [Collections.Generic.List[object]]::new() }
        }
        $row = $sessionMap[$key]
        $eventName = [string](Read-EventProperty $event 'event'); $eventTime = [string](Read-EventProperty $event 'timestamp'); $eventDetail = [string](Read-EventProperty $event 'detail')
        $row.lastEvent = $eventName; $row.lastEventAt = $eventTime
        if ($eventName -eq 'capacity-detected') { $row.capacityErrors++; if (-not $row.firstSeen) { $row.firstSeen = $eventTime } }
        if ($eventName -in @('retry-clicked', 'retry-invoked')) { $row.attempts++ }
        if ($eventName -eq 'retry-confirmed') { $row.successes++ }
        if ($eventName -in @('retry-failed', 'retry-unconfirmed', 'limit-reached')) {
            $row.failures++; $row.lastError = Get-NormalizedFailure $eventDetail $eventName
            $reason = $row.lastError; if (-not $row.reasons.ContainsKey($reason)) { $row.reasons[$reason] = 0 }; $row.reasons[$reason]++
        }
        if ($row.timeline.Count -lt 100) { $row.timeline.Add([ordered]@{ at = $eventTime; event = $eventName; detail = $eventDetail; reason = if ($eventName -in @('retry-failed','retry-unconfirmed','limit-reached')) { Get-NormalizedFailure $eventDetail $eventName } else { '' } }) }
    }
    return @($sessionMap.Values)
}

function Get-StatusPayload {
    $events = @(Read-StateEvents)
    if ($stateEventsChanged -or $null -eq $stateSessionCache) {
        $script:stateSessionCache = @(Build-StateSessionCache $events)
    }
    $sessionMap = @{}
    foreach ($row in @($stateSessionCache)) { $sessionMap[$row.id] = $row }
    foreach ($live in @(Get-LiveRolloutSessions)) {
        if (-not $sessionMap.ContainsKey($live.id)) { $sessionMap[$live.id] = $live }
    }
    $sessions = @($sessionMap.Values | ForEach-Object {
        [pscustomobject]@{ id = $_.id; title = $_.title; hasRecord = $_.hasRecord; capacityErrors = $_.capacityErrors; successes = $_.successes; failures = $_.failures; attempts = $_.attempts; firstSeen = $_.firstSeen; lastError = $_.lastError; lastEvent = $_.lastEvent; lastEventAt = $_.lastEventAt; reasons = $_.reasons; timeline = @($_.timeline) }
    } | Sort-Object lastEventAt -Descending)
    $total = [ordered]@{ sessions = $sessions.Count; capacityErrors = 0; attempts = 0; successes = 0; failures = 0 }
    foreach ($session in $sessions) { $total.capacityErrors += $session.capacityErrors; $total.attempts += $session.attempts; $total.successes += $session.successes; $total.failures += $session.failures }
    $last = if ($events.Count) { $events[-1] } else { $null }
    [ordered]@{ monitor = [ordered]@{ running = (Test-MonitorAlive); paused = (Get-ControlPaused); pid = if ($script:monitorProcess) { $script:monitorProcess.Id } else { $null }; url = "http://127.0.0.1:$Port" }; total = $total; sessions = $sessions; recent = @($events | Select-Object -Last 12 | Sort-Object { [string](Read-EventProperty $_ 'timestamp') } -Descending); history = [ordered]@{ paths = @($StatePath) + (1..3 | ForEach-Object { "$StatePath.$_" }); lastEventAt = if ($last) { Read-EventProperty $last 'timestamp' } else { $null }; note = '统计来自当前状态文件及其轮转副本' } }
}

function Send-Json($Context, $Value, [int]$StatusCode = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12))
    $Context.Response.StatusCode = $StatusCode; $Context.Response.ContentType = 'application/json; charset=utf-8'; $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length); $Context.Response.Close()
}

function Read-Body($Context) {
    $reader = [IO.StreamReader]::new($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
}

function Set-Autostart([bool]$Enabled) {
    $pwsh = Get-PwshPath
    if ($Enabled) {
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -NoBrowser"
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description 'Start the local Codex Desktop retry monitor console.' -Force | Out-Null
    } else { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}

function Get-Autostart {
    return [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
}

function Serve-Request($Context) {
    $path = $Context.Request.Url.AbsolutePath
    if ($path -eq '/api/status' -and $Context.Request.HttpMethod -eq 'GET') { Send-Json $Context (Get-StatusPayload); return }
    if ($path -eq '/api/settings' -and $Context.Request.HttpMethod -eq 'GET') { Send-Json $Context ([ordered]@{ settings = Read-Settings; autostart = Get-Autostart }); return }
    if ($path -eq '/api/control' -and $Context.Request.HttpMethod -eq 'POST') {
        $body = Read-Body $Context
        switch ([string]$body.action) { 'start' { Start-Monitor }; 'resume' { Write-Control $false; if (-not (Test-MonitorAlive)) { Start-Monitor } }; 'pause' { if (Test-MonitorAlive) { Write-Control $true } }; 'restart' { Stop-Monitor; Start-Sleep -Milliseconds 200; Start-Monitor } }
        Send-Json $Context (Get-StatusPayload); return
    }
    if ($path -eq '/api/settings' -and $Context.Request.HttpMethod -eq 'POST') {
        $body = Read-Body $Context; if ($body.settings) { Write-Settings $body.settings }; if ($null -ne $body.autostart) { Set-Autostart ([bool]$body.autostart) }; Stop-Monitor; Start-Monitor; Send-Json $Context (Get-StatusPayload); return
    }
    if ($path -eq '/api/autostart' -and $Context.Request.HttpMethod -eq 'POST') { $body = Read-Body $Context; Set-Autostart ([bool]$body.enabled); Send-Json $Context ([ordered]@{ enabled = Get-Autostart }); return }
    $relative = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
    $webRootFull = ([IO.Path]::GetFullPath($webRoot)).TrimEnd('\') + '\'
    $file = [IO.Path]::GetFullPath((Join-Path $webRoot $relative))
    if (-not $file.StartsWith($webRootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Json $Context @{ error = 'Not found' } 404; return }
    $contentTypes = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.svg' = 'image/svg+xml' }
    $bytes = [IO.File]::ReadAllBytes($file); $Context.Response.ContentType = if ($contentTypes.ContainsKey([IO.Path]::GetExtension($file))) { $contentTypes[[IO.Path]::GetExtension($file)] } else { 'application/octet-stream' }; $Context.Response.ContentLength64 = $bytes.Length; $Context.Response.OutputStream.Write($bytes,0,$bytes.Length); $Context.Response.Close()
}

if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Port must be between 1024 and 65535.' }
if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) { throw "Web assets are missing: $webRoot" }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Settings (Get-DefaultSettings) }
Write-Control $false
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start(); Start-Monitor
    $url = "http://127.0.0.1:$Port/"
    Write-Host "Retry console running at $url" -ForegroundColor Cyan
    if (-not $NoBrowser) { Start-Process $url }
    while ($listener.IsListening) { try { Serve-Request ($listener.GetContext()) } catch { Write-Warning $_.Exception.Message } }
} finally { try { if ($listener.IsListening) { $listener.Stop() } } catch { }; Stop-RetryRolloutWatchers $liveRolloutIndex; Stop-Monitor }
