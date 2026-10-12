$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-monitor-conflict-' + [guid]::NewGuid().ToString('N'))
$port = 18766
[void](New-Item -ItemType Directory -Path $temp)
$monitor = $null
$duplicate = $null
$console = $null
try {
    $state = Join-Path $temp 'state.json'
    $control = Join-Path $temp 'control.json'
    $diag = Join-Path $temp 'diag.log'
    $settings = Join-Path $temp 'settings.json'
    [ordered]@{
        logRoot = @($temp); processName = @('CodexProcessThatDoesNotExist'); maxRetries = 0
        backoffSeconds = @(0); pollSeconds = 0.1; cooldownSeconds = 20; retryUiWaitSeconds = 90
        retryConfirmSeconds = 30; uiLeaseSeconds = 5; rescanSeconds = 60; allowNativeClick = $false
    } | ConvertTo-Json | Set-Content -LiteralPath $settings -Encoding UTF8
    $monitorArgs = @('-NoProfile', '-File', (Join-Path $repo 'codex-desktop-retry.ps1'), '-LogRoot', $temp,
        '-ProcessName', 'CodexProcessThatDoesNotExist', '-PollSeconds', '0.1', '-StatePath', $state,
        '-UiDiagnosticPath', $diag, '-ControlPath', $control)
    $monitor = Start-Process -FilePath 'pwsh' -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    if ($monitor.HasExited) { throw "standalone monitor exited early: $($monitor.ExitCode)" }

    $consoleArgs = @('-NoProfile', '-File', (Join-Path $repo 'codex-desktop-retry-ui.ps1'), '-NoBrowser', '-Port', $port,
        '-ConfigPath', $settings, '-StatePath', $state, '-ControlPath', $control, '-UiDiagnosticPath', $diag)
    $console = Start-Process -FilePath 'pwsh' -ArgumentList $consoleArgs -WindowStyle Hidden -PassThru
    $url = "http://127.0.0.1:$port/api/status"
    $ready = $false
    foreach ($attempt in 1..30) {
        Start-Sleep -Milliseconds 200
        try { $null = Invoke-RestMethod -Uri $url -TimeoutSec 2; $ready = $true; break } catch { }
    }
    if (-not $ready) { throw 'console did not become ready' }
    Start-Sleep -Milliseconds 800
    $status = Invoke-RestMethod -Uri $url
    if ($monitor.HasExited) { throw 'standalone monitor was terminated by console startup' }
    if (-not $status.monitor.running) { throw 'BUG: frontend reports stopped while standalone monitor is running' }
    if ([int]$status.monitor.pid -ne $monitor.Id) { throw "BUG: frontend reports pid $($status.monitor.pid), expected standalone pid $($monitor.Id)" }
    $duplicate = Start-Process -FilePath 'pwsh' -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $duplicate.Refresh()
    if (-not $duplicate.HasExited -or $duplicate.ExitCode -ne 0) { throw 'BUG: direct startup did not reuse the existing monitor instance.' }
    $null = Invoke-RestMethod -Uri "$url/api/control" -Method Post -ContentType 'application/json' -Body '{"action":"pause"}'
    Start-Sleep -Milliseconds 200
    if (-not ((Get-Content -LiteralPath $control -Raw | ConvertFrom-Json).paused)) { throw 'BUG: frontend pause did not reach the standalone monitor.' }
    $null = Invoke-RestMethod -Uri "$url/api/control" -Method Post -ContentType 'application/json' -Body '{"action":"resume"}'
    Stop-Process -Id $console.Id -Force
    Start-Sleep -Milliseconds 300
    if ($monitor.HasExited) { throw 'BUG: closing the frontend terminated the standalone monitor.' }
    Write-Output 'PASS monitor-conflict'
} finally {
    if ($console -and -not $console.HasExited) { Stop-Process -Id $console.Id -Force }
    if ($duplicate -and -not $duplicate.HasExited) { Stop-Process -Id $duplicate.Id -Force }
    if ($monitor -and -not $monitor.HasExited) { Stop-Process -Id $monitor.Id -Force }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
