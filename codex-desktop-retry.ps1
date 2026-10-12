[CmdletBinding()]
param(
    [string[]] $LogRoot = @((Join-Path $env:USERPROFILE '.codex')),
    [string[]] $ProcessName = @('ChatGPT', 'Codex', 'OpenAI.Codex'),
    [int] $MaxRetries = 0,
    [int[]] $BackoffSeconds = @(0),
    [double] $PollSeconds = 0.25,
    [int] $CooldownSeconds = 20,
    [int] $RetryUiWaitSeconds = 90,
    [int] $RetryConfirmSeconds = 30,
    [int] $UiLeaseSeconds = 5,
    [int] $UiSnapshotMaxMilliseconds = 5000,
    [int] $RescanSeconds = 60,
    [int64] $StateMaxBytes = 1048576,
    [int] $StateMaxFiles = 3,
    [switch] $AllowNativeClick,
    [switch] $DisableNativeClick,
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log'),
    [string] $ControlPath = (Join-Path $PSScriptRoot 'retry-control.json'),
    [string] $RuntimePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($MaxRetries -lt 0) { throw 'MaxRetries must be >= 0.' }
if ($PollSeconds -le 0) { throw 'PollSeconds must be > 0.' }
if ($CooldownSeconds -lt 0) { throw 'CooldownSeconds must be >= 0.' }
if ($RetryUiWaitSeconds -le 0) { throw 'RetryUiWaitSeconds must be > 0.' }
if ($RetryConfirmSeconds -le 0) { throw 'RetryConfirmSeconds must be > 0.' }
if ($UiLeaseSeconds -le 0) { throw 'UiLeaseSeconds must be > 0.' }
if ($UiSnapshotMaxMilliseconds -lt 500) { throw 'UiSnapshotMaxMilliseconds must be >= 500.' }
if ($RescanSeconds -lt 10) { throw 'RescanSeconds must be at least 10.' }
if ($BackoffSeconds.Count -eq 0 -or @($BackoffSeconds | Where-Object { $_ -lt 0 }).Count -gt 0) {
    throw 'BackoffSeconds must contain non-negative values.'
}
if ($StateMaxBytes -lt 4096) { throw 'StateMaxBytes must be at least 4096.' }
if ($StateMaxFiles -lt 1) { throw 'StateMaxFiles must be at least 1.' }
# Accept legacy comma-separated command-line values while preserving repeated
# -ProcessName arguments emitted by the UI launcher.
$ProcessName = @($ProcessName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ProcessName.Count -eq 0) { throw 'ProcessName must contain at least one process name.' }
. (Join-Path $PSScriptRoot 'retry\Retry.Runtime.ps1')
$RuntimePath = Get-RetryMonitorRuntimePath $StatePath $RuntimePath

# Only one monitor may consume a given rollout root. Multiple UI consoles can
# otherwise watch the same capacity event and race each other's UI leases,
# producing repeated ui-yield/retry-superseded results. A per-root named mutex
# also works when each console uses its own temporary state file.
$rootKey = [string](@($LogRoot | Sort-Object) -join '|')
$sha = [Security.Cryptography.SHA256]::Create()
try { $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rootKey))).Replace('-', '')).Substring(0, 24) }
finally { $sha.Dispose() }
$mutexName = "Local\CodexDesktopRetryMonitor-$rootHash"
$mutexCreated = $false
$monitorMutex = [Threading.Mutex]::new($false, $mutexName, [ref]$mutexCreated)
if (-not $mutexCreated) {
    $existing = Read-RetryMonitorRuntime $RuntimePath
    $monitorMutex.Dispose()
    if ($existing -and [int]$existing.pid -gt 0) {
        try {
            $existingProcess = Get-Process -Id ([int]$existing.pid) -ErrorAction Stop
            if (-not $existingProcess.HasExited) {
                Write-Host "Codex Desktop retry monitor is already running (PID $($existing.pid)); using the existing instance." -ForegroundColor Yellow
                exit 0
            }
        } catch { }
    }
    Write-Error "A Codex Desktop retry monitor is already running for: $rootKey"
    exit 2
}

. (Join-Path $PSScriptRoot 'retry\Retry.Logs.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.State.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Ui.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Monitor.ps1')
$options = @{
    LogRoot = $LogRoot; ProcessName = $ProcessName; MaxRetries = $MaxRetries
    BackoffSeconds = $BackoffSeconds; CooldownSeconds = $CooldownSeconds
    RetryUiWaitSeconds = $RetryUiWaitSeconds; RetryConfirmSeconds = $RetryConfirmSeconds
    UiLeaseSeconds = $UiLeaseSeconds; UiSnapshotMaxMilliseconds = $UiSnapshotMaxMilliseconds
    RescanSeconds = $RescanSeconds
    StateMaxBytes = $StateMaxBytes; StateMaxFiles = $StateMaxFiles
    AllowNativeClick = (-not $DisableNativeClick.IsPresent) -or $AllowNativeClick.IsPresent; StatePath = $StatePath
    UiDiagnosticPath = $UiDiagnosticPath; ControlPath = $ControlPath
}
$monitor = New-RetryMonitor $options
$adapter = New-DesktopRetryAdapter $monitor
$wasPaused = $false
$runtimeRegistered = $false
try {
    Write-RetryMonitorRuntime $RuntimePath ([ordered]@{
        pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o'); scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
        statePath = [IO.Path]::GetFullPath($StatePath); controlPath = [IO.Path]::GetFullPath($ControlPath)
        uiDiagnosticPath = [IO.Path]::GetFullPath($UiDiagnosticPath); logRoot = @($LogRoot); processName = @($ProcessName)
    })
    $runtimeRegistered = $true
    Write-Host 'Codex Desktop retry monitor started. Press Ctrl+C to stop.' -ForegroundColor Cyan
    Write-Host "Watching: $($LogRoot -join ', ')" -ForegroundColor DarkCyan
    Write-RetryState $monitor 'started'
    while ($true) {
        $paused = $false
        if ($ControlPath -and (Test-Path -LiteralPath $ControlPath -PathType Leaf)) {
            try {
                $control = Get-Content -LiteralPath $ControlPath -Raw | ConvertFrom-Json
                $paused = [bool]$control.paused
            } catch { $paused = $false }
        }
        if ($paused) {
            if (-not $wasPaused) { Write-RetryState $monitor 'paused' $ControlPath }
            $wasPaused = $true
        } else {
            if ($wasPaused) { Write-RetryState $monitor 'resumed' $ControlPath }
            $wasPaused = $false
            Invoke-RetryMonitorTick $monitor $adapter (Get-Date)
        }
        Start-Sleep -Milliseconds ([Math]::Max(50, [int]($PollSeconds * 1000)))
    }
} finally {
    if ($runtimeRegistered) { Remove-RetryMonitorRuntime $RuntimePath $PID }
    $monitor.StateMutex.Dispose(); $monitorMutex.ReleaseMutex(); $monitorMutex.Dispose()
}
