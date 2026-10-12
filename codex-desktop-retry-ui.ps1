[CmdletBinding()]
param(
    [int] $Port = 8765,
    [switch] $NoBrowser,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'retry-ui-settings.json'),
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $ControlPath = (Join-Path $PSScriptRoot 'retry-control.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log'),
    [string] $RuntimePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$webRoot = Join-Path $scriptRoot 'web'
$monitorScript = Join-Path $scriptRoot 'codex-desktop-retry.ps1'
$taskName = 'Codex Desktop Retry Monitor'
$monitorProcess = $null
$monitorOwned = $false
$activeStatePath = $StatePath
$activeControlPath = $ControlPath
$activeUiDiagnosticPath = $UiDiagnosticPath
$activeLogRoot = $null
$runtimePath = ''
$listener = [Net.HttpListener]::new()
if (-not ('RetryHttpAccept' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Concurrent;
using System.Net;
public static class RetryHttpAccept {
    public static readonly ConcurrentQueue<HttpListenerContext> Queue = new ConcurrentQueue<HttpListenerContext>();
    public static void Accept(IAsyncResult result) {
        var listener = (HttpListener)result.AsyncState;
        try {
            Queue.Enqueue(listener.EndGetContext(result));
            if (listener.IsListening) listener.BeginGetContext(Accept, listener);
        } catch { }
    }
}
'@
}
. (Join-Path $PSScriptRoot 'retry\Retry.Status.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Rollouts.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Runtime.ps1')
$runtimePath = Get-RetryMonitorRuntimePath $StatePath $RuntimePath
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
    $parent = Split-Path -Parent $activeControlPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [ordered]@{ paused = $Paused; updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $activeControlPath -Encoding UTF8
}

function Get-ControlPaused {
    if (-not (Test-Path -LiteralPath $activeControlPath -PathType Leaf)) { return $false }
    try { return [bool]((Get-Content -LiteralPath $activeControlPath -Raw | ConvertFrom-Json).paused) } catch { return $false }
}

function Get-RegisteredMonitor {
    $registration = Read-RetryMonitorRuntime $runtimePath
    if (-not $registration -or [int]$registration.pid -le 0) { return $null }
    try {
        $process = Get-Process -Id ([int]$registration.pid) -ErrorAction Stop
        if ($process.HasExited) { return $null }
        return [pscustomobject]@{ Process = $process; Registration = $registration }
    } catch {
        return $null
    }
}

function Use-MonitorRegistration($Attached) {
    $registration = $Attached.Registration
    $script:monitorProcess = $Attached.Process
    $script:monitorOwned = $false
    if ($registration.statePath) { $script:activeStatePath = [IO.Path]::GetFullPath([string]$registration.statePath) }
    if ($registration.controlPath) { $script:activeControlPath = [IO.Path]::GetFullPath([string]$registration.controlPath) }
    if ($registration.uiDiagnosticPath) { $script:activeUiDiagnosticPath = [IO.Path]::GetFullPath([string]$registration.uiDiagnosticPath) }
    if ($registration.logRoot) { $script:activeLogRoot = @($registration.logRoot) }
}

function Test-MonitorAlive {
    $attached = Get-RegisteredMonitor
    if ($attached) {
        if (-not $script:monitorProcess -or $script:monitorProcess.Id -ne $attached.Process.Id) { Use-MonitorRegistration $attached }
        return $true
    }
    if ($script:monitorProcess -and -not $script:monitorProcess.HasExited) { return $true }
    $script:monitorProcess = $null
    $script:monitorOwned = $false
    return $false
}

function Start-Monitor {
    if (Test-MonitorAlive) { return }
    $settings = Read-Settings
    $script:activeStatePath = $StatePath
    $script:activeControlPath = $ControlPath
    $script:activeUiDiagnosticPath = $UiDiagnosticPath
    $script:activeLogRoot = @($settings.logRoot)
    Write-Control $false
    $argList = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $monitorScript)) { [void]$argList.Add([string]$value) }
    [void]$argList.Add('-LogRoot'); [void]$argList.Add(([string](@($settings.logRoot) -join ',')))
    [void]$argList.Add('-ProcessName'); [void]$argList.Add(([string](@($settings.processName) -join ',')))
    foreach ($pair in @(
        @('-MaxRetries', [string]$settings.maxRetries), @('-BackoffSeconds', [string](@($settings.backoffSeconds) -join ',')),
        @('-PollSeconds', [string]$settings.pollSeconds), @('-CooldownSeconds', [string]$settings.cooldownSeconds),
        @('-RetryUiWaitSeconds', [string]$settings.retryUiWaitSeconds), @('-RetryConfirmSeconds', [string]$settings.retryConfirmSeconds),
        @('-UiLeaseSeconds', [string]$settings.uiLeaseSeconds), @('-RescanSeconds', [string]$settings.rescanSeconds),
        @('-StatePath', $StatePath), @('-UiDiagnosticPath', $UiDiagnosticPath), @('-ControlPath', $ControlPath), @('-RuntimePath', $runtimePath)
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
    $script:monitorOwned = $true
    Start-Sleep -Milliseconds 100
    [void](Test-MonitorAlive)
}

function Stop-Monitor([switch]$Force) {
    $alive = Test-MonitorAlive
    if ($alive -and ($Force -or $script:monitorOwned)) { $script:monitorProcess.Kill(); $script:monitorProcess.WaitForExit(3000) | Out-Null }
    $script:monitorProcess = $null
    $script:monitorOwned = $false
}

function Read-StateEvents {
    $paths = @($activeStatePath) + (1..3 | ForEach-Object { "$activeStatePath.$_" })
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
    $roots = if ($activeLogRoot) { @($activeLogRoot) } else { @($settings.logRoot) }
    return @(Get-RetryLiveRolloutSessions $liveRolloutIndex $roots)
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
        if ($eventName -in @('retry-clicked', 'retry-invoked')) { $row.attempts++; $row.successes++ }
        if ($eventName -in @('retry-failed', 'retry-unconfirmed', 'limit-reached')) {
            $row.failures++; $row.lastError = Get-NormalizedFailure $eventDetail $eventName
            $reason = $row.lastError; if (-not $row.reasons.ContainsKey($reason)) { $row.reasons[$reason] = 0 }; $row.reasons[$reason]++
        }
        if ($row.timeline.Count -lt 100) { $row.timeline.Add([ordered]@{ at = $eventTime; event = $eventName; detail = $eventDetail; reason = if ($eventName -in @('retry-failed','retry-unconfirmed','limit-reached')) { Get-NormalizedFailure $eventDetail $eventName } else { '' } }) }
    }
    return @($sessionMap.Values)
}

function Get-StatusPayload {
    $running = Test-MonitorAlive
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
    [ordered]@{ monitor = [ordered]@{ running = $running; paused = (Get-ControlPaused); pid = if ($script:monitorProcess) { $script:monitorProcess.Id } else { $null }; url = "http://127.0.0.1:$Port" }; total = $total; sessions = $sessions; recent = @($events | Select-Object -Last 12 | Sort-Object { [string](Read-EventProperty $_ 'timestamp') } -Descending); history = [ordered]@{ paths = @($activeStatePath) + (1..3 | ForEach-Object { "$activeStatePath.$_" }); lastEventAt = if ($last) { Read-EventProperty $last 'timestamp' } else { $null }; note = '统计来自当前状态文件及其轮转副本' } }
}

function Test-RetryClientDisconnectException([System.Exception]$Exception) {
    $current = $Exception
    while ($current) {
        $code = ([int]$current.HResult) -band 0xFFFF
        if ($code -in @(64, 109, 995, 10053, 10054, 10058)) { return $true }
        $message = [string]$current.Message
        if ($message -match '(?i)指定的网络名不再可用|network name is no longer available|远程主机强迫关闭|connection (?:was )?(?:aborted|reset)|broken pipe|pipe.*closed|请求被中止|连接.*(?:重置|关闭)') { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Send-Json($Context, $Value, [int]$StatusCode = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12))
    $Context.Response.StatusCode = $StatusCode; $Context.Response.ContentType = 'application/json; charset=utf-8'; $Context.Response.ContentLength64 = $bytes.Length
    try { $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    catch { if (-not (Test-RetryClientDisconnectException $_.Exception)) { throw } }
    finally { try { $Context.Response.Close() } catch { } }
}

function Send-ProcessEventStream($Context) {
    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType = 'text/event-stream; charset=utf-8'
    $response.SendChunked = $false
    $response.KeepAlive = $false
    $response.Headers['Cache-Control'] = 'no-cache, no-transform'
    $response.Headers['Connection'] = 'close'
    try {
        $running = Test-MonitorAlive
        $paused = if ($running) { Get-ControlPaused } else { $false }
        $processId = if ($script:monitorProcess) { $script:monitorProcess.Id } else { $null }
        $payload = [ordered]@{ running = $running; paused = $paused; pid = $processId }
        $json = $payload | ConvertTo-Json -Compress
        $text = "retry: 1000`nevent: process`ndata: $json`n`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        if (-not (Test-RetryClientDisconnectException $_.Exception)) { throw }
        # Browser navigation/reconnect closes the stream normally.
    } finally {
        try { $response.Close() } catch { }
    }
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
    if ($path -eq '/api/process-events' -and $Context.Request.HttpMethod -eq 'GET') { Send-ProcessEventStream $Context; return }
    if ($path -eq '/api/status' -and $Context.Request.HttpMethod -eq 'GET') { Send-Json $Context (Get-StatusPayload); return }
    if ($path -eq '/api/settings' -and $Context.Request.HttpMethod -eq 'GET') { Send-Json $Context ([ordered]@{ settings = Read-Settings; autostart = Get-Autostart }); return }
    if ($path -eq '/api/control' -and $Context.Request.HttpMethod -eq 'POST') {
        $body = Read-Body $Context
        switch ([string]$body.action) { 'start' { Start-Monitor }; 'resume' { Write-Control $false; if (-not (Test-MonitorAlive)) { Start-Monitor } }; 'pause' { if (Test-MonitorAlive) { Write-Control $true } }; 'restart' { Stop-Monitor -Force; Start-Sleep -Milliseconds 200; Start-Monitor } }
        Send-Json $Context (Get-StatusPayload); return
    }
    if ($path -eq '/api/settings' -and $Context.Request.HttpMethod -eq 'POST') {
        $body = Read-Body $Context; if ($body.settings) { Write-Settings $body.settings }; if ($null -ne $body.autostart) { Set-Autostart ([bool]$body.autostart) }; Stop-Monitor -Force; Start-Sleep -Milliseconds 200; Start-Monitor; Send-Json $Context (Get-StatusPayload); return
    }
    if ($path -eq '/api/autostart' -and $Context.Request.HttpMethod -eq 'POST') { $body = Read-Body $Context; Set-Autostart ([bool]$body.enabled); Send-Json $Context ([ordered]@{ enabled = Get-Autostart }); return }
    $relative = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
    $webRootFull = ([IO.Path]::GetFullPath($webRoot)).TrimEnd('\') + '\'
    $file = [IO.Path]::GetFullPath((Join-Path $webRoot $relative))
    if (-not $file.StartsWith($webRootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Json $Context @{ error = 'Not found' } 404; return }
    $contentTypes = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.svg' = 'image/svg+xml' }
    $bytes = [IO.File]::ReadAllBytes($file)
    $Context.Response.ContentType = if ($contentTypes.ContainsKey([IO.Path]::GetExtension($file))) { $contentTypes[[IO.Path]::GetExtension($file)] } else { 'application/octet-stream' }
    $Context.Response.ContentLength64 = $bytes.Length
    try { $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    catch { if (-not (Test-RetryClientDisconnectException $_.Exception)) { throw } }
    finally { try { $Context.Response.Close() } catch { } }
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
    [void]$listener.BeginGetContext([AsyncCallback][RetryHttpAccept]::Accept, $listener)
    while ($listener.IsListening) {
        $context = $null
        while ([RetryHttpAccept]::Queue.TryDequeue([ref]$context)) {
            try { Serve-Request $context } catch {
                if ($listener.IsListening -and -not (Test-RetryClientDisconnectException $_.Exception)) { Write-Warning $_.Exception.Message }
                try { $context.Response.Close() } catch { }
            }
        }
        Start-Sleep -Milliseconds 50
    }
} finally { try { if ($listener.IsListening) { $listener.Stop() } } catch { }; Stop-RetryRolloutWatchers $liveRolloutIndex; Stop-Monitor }
