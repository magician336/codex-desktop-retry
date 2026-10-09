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
    [int] $RescanSeconds = 60,
    [int64] $StateMaxBytes = 1048576,
    [int] $StateMaxFiles = 3,
    [switch] $AllowNativeClick,
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log'),
    [string] $ControlPath = (Join-Path $PSScriptRoot 'retry-control.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($MaxRetries -lt 0) { throw 'MaxRetries must be >= 0.' }
if ($PollSeconds -le 0) { throw 'PollSeconds must be > 0.' }
if ($CooldownSeconds -lt 0) { throw 'CooldownSeconds must be >= 0.' }
if ($RetryUiWaitSeconds -le 0) { throw 'RetryUiWaitSeconds must be > 0.' }
if ($RetryConfirmSeconds -le 0) { throw 'RetryConfirmSeconds must be > 0.' }
if ($UiLeaseSeconds -le 0) { throw 'UiLeaseSeconds must be > 0.' }
if ($RescanSeconds -lt 10) { throw 'RescanSeconds must be at least 10.' }
if ($BackoffSeconds.Count -eq 0 -or @($BackoffSeconds | Where-Object { $_ -lt 0 }).Count -gt 0) {
    throw 'BackoffSeconds must contain non-negative values.'
}
if ($StateMaxBytes -lt 4096) { throw 'StateMaxBytes must be at least 4096.' }
if ($StateMaxFiles -lt 1) { throw 'StateMaxFiles must be at least 1.' }

. (Join-Path $PSScriptRoot 'retry\Retry.Logs.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.State.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Ui.ps1')
. (Join-Path $PSScriptRoot 'retry\Retry.Monitor.ps1')
$options = @{
    LogRoot = $LogRoot; ProcessName = $ProcessName; MaxRetries = $MaxRetries
    BackoffSeconds = $BackoffSeconds; CooldownSeconds = $CooldownSeconds
    RetryUiWaitSeconds = $RetryUiWaitSeconds; RetryConfirmSeconds = $RetryConfirmSeconds
    UiLeaseSeconds = $UiLeaseSeconds; RescanSeconds = $RescanSeconds
    StateMaxBytes = $StateMaxBytes; StateMaxFiles = $StateMaxFiles
    AllowNativeClick = $AllowNativeClick.IsPresent; StatePath = $StatePath
    UiDiagnosticPath = $UiDiagnosticPath; ControlPath = $ControlPath
}
$monitor = New-RetryMonitor $options
$adapter = New-DesktopRetryAdapter $monitor
Write-Host 'Codex Desktop retry monitor started. Press Ctrl+C to stop.' -ForegroundColor Cyan
Write-Host "Watching: $($LogRoot -join ', ')" -ForegroundColor DarkCyan
Write-RetryState $monitor 'started'
$wasPaused = $false
try {
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
} finally { $monitor.StateMutex.Dispose() }
