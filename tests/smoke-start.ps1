$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-retry-start-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$out = Join-Path $temp 'stdout.log'
$err = Join-Path $temp 'stderr.log'
$args = @('-NoProfile', '-File', (Join-Path $repo 'codex-desktop-retry.ps1'), '-LogRoot', $temp,
    '-ProcessName', 'CodexProcessThatDoesNotExist', '-PollSeconds', '0.1', '-StatePath', (Join-Path $temp 'state.jsonl'),
    '-UiDiagnosticPath', (Join-Path $temp 'diag.log'))
try {
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    Start-Sleep -Seconds 2
    if ($process.HasExited) { throw "monitor exited early: $($process.ExitCode)`n$([IO.File]::ReadAllText($err))" }
    Stop-Process -Id $process.Id -Force
    Write-Output 'PASS smoke-start'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
