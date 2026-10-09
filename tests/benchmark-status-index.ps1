$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'retry\Retry.Status.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-status-bench-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $state = Join-Path $temp 'state.jsonl'
    $paths = @($state, "$state.1", "$state.2", "$state.3")
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($number in 1..2000) { $lines.Add((ConvertTo-Json ([ordered]@{ timestamp = "2026-10-10T00:00:$('{0:D2}' -f ($number % 60)).$number`Z"; event = 'test'; session = "session-$($number % 10)"; detail = '' }) -Compress)) }
    [IO.File]::WriteAllLines($state, $lines, [Text.UTF8Encoding]::new($false))
    $index = New-RetryStatusIndex
    $clock = [Diagnostics.Stopwatch]::StartNew(); [void](Get-RetryStatusEvents $index $paths); $clock.Stop(); $firstMs = $clock.Elapsed.TotalMilliseconds
    $before = Get-RetryStatusIndexStats $index
    $clock.Restart(); [void](Get-RetryStatusEvents $index $paths); $clock.Stop(); $unchangedMs = $clock.Elapsed.TotalMilliseconds
    $afterUnchanged = Get-RetryStatusIndexStats $index
    [IO.File]::AppendAllText($state, (ConvertTo-Json ([ordered]@{ timestamp = '2026-10-10T01:00:00Z'; event = 'test'; session = 'session-new'; detail = '' }) -Compress) + "`n", [Text.UTF8Encoding]::new($false))
    $clock.Restart(); [void](Get-RetryStatusEvents $index $paths); $clock.Stop(); $appendMs = $clock.Elapsed.TotalMilliseconds
    $afterAppend = Get-RetryStatusIndexStats $index
    [pscustomobject]@{
        InitialLines = $before.ParsedLines
        UnchangedParsedLines = $afterUnchanged.ParsedLines - $before.ParsedLines
        AppendedParsedLines = $afterAppend.ParsedLines - $afterUnchanged.ParsedLines
        InitialMs = [math]::Round($firstMs, 2)
        UnchangedMs = [math]::Round($unchangedMs, 2)
        AppendMs = [math]::Round($appendMs, 2)
    } | Format-List
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
