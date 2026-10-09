$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-status-host-' + [guid]::NewGuid().ToString('N'))
$port = 18765
New-Item -ItemType Directory -Path $temp | Out-Null
$process = $null
try {
    $config = Join-Path $temp 'settings.json'
    $state = Join-Path $temp 'state.jsonl'
    $control = Join-Path $temp 'control.json'
    $diag = Join-Path $temp 'diag.log'
    $args = @('-NoProfile', '-File', (Join-Path $repo 'codex-desktop-retry-ui.ps1'), '-NoBrowser', '-Port', $port,
        '-ConfigPath', $config, '-StatePath', $state, '-ControlPath', $control, '-UiDiagnosticPath', $diag)
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $args -WindowStyle Hidden -PassThru
    $url = "http://127.0.0.1:$port/api/status"
    $ready = $false
    foreach ($attempt in 1..30) {
        Start-Sleep -Milliseconds 200
        try { $null = Invoke-RestMethod -Uri $url -TimeoutSec 2; $ready = $true; break } catch { }
    }
    if (-not $ready) { throw 'Status host did not become ready.' }
    $initial = Invoke-RestMethod -Uri $url
    $record = '{"timestamp":"2026-10-10T00:00:01Z","event":"capacity-detected","session":"session-a","detail":"server_is_overloaded"}'
    [IO.File]::AppendAllText($state, $record + "`n", [Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 100
    $updated = Invoke-RestMethod -Uri $url
    if ($updated.total.capacityErrors -ne ($initial.total.capacityErrors + 1)) { throw 'Status endpoint did not expose an appended event.' }
    Write-Output 'PASS smoke-status-index'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
