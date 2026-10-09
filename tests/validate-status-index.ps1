$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'retry\Retry.Status.ps1')

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-status-index-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $active = Join-Path $temp 'retry-state.json'
    $rotated = "$active.1"
    $eventA = '{"timestamp":"2026-10-10T00:00:01Z","event":"started","session":"session-a","detail":"启动"}'
    $eventB = '{"timestamp":"2026-10-10T00:00:02Z","event":"capacity-detected","session":"session-a","detail":"server_is_overloaded"}'
    $eventC = '{"timestamp":"2026-10-10T00:00:03Z","event":"retry-clicked","session":"session-a","detail":""}'
    [IO.File]::WriteAllText($active, "$eventA`n$eventB`n", [Text.UTF8Encoding]::new($false))
    $index = New-RetryStatusIndex
    $paths = @($active, $rotated, "$active.2", "$active.3")

    $events = @(Get-RetryStatusEvents $index $paths)
    Assert ($events.Count -eq 2) 'Initial state index did not read both events.'
    $stats = Get-RetryStatusIndexStats $index
    Assert ($stats.FullRebuilds -eq 1 -and $stats.ParsedLines -eq 2) 'Initial read did not record one full rebuild and two parsed lines.'

    [void](Get-RetryStatusEvents $index $paths)
    $unchanged = Get-RetryStatusIndexStats $index
    Assert ($unchanged.ParsedLines -eq 2 -and $unchanged.IncrementalReads -eq 0) 'Unchanged files were parsed again.'

    [IO.File]::AppendAllText($active, "$eventC`n", [Text.UTF8Encoding]::new($false))
    $events = @(Get-RetryStatusEvents $index $paths)
    $stats = Get-RetryStatusIndexStats $index
    Assert ($events.Count -eq 3 -and $stats.ParsedLines -eq 3 -and $stats.IncrementalReads -eq 1) 'Appended state was not read incrementally.'

    [IO.File]::AppendAllText($active, "not-json`n", [Text.UTF8Encoding]::new($false))
    $events = @(Get-RetryStatusEvents $index $paths)
    $stats = Get-RetryStatusIndexStats $index
    Assert ($events.Count -eq 3 -and $stats.InvalidLines -eq 1 -and $stats.ParsedLines -eq 4) 'Invalid JSON handling changed the indexed result.'

    Move-Item -LiteralPath $active -Destination $rotated -Force
    [IO.File]::WriteAllText($active, "$eventA`n", [Text.UTF8Encoding]::new($false))
    $events = @(Get-RetryStatusEvents $index $paths)
    $stats = Get-RetryStatusIndexStats $index
    Assert ($events.Count -eq 4 -and $stats.FullRebuilds -ge 3) 'Rotation did not rebuild the affected shards.'

    [IO.File]::WriteAllText($active, '{"timestamp":"2026-10-10T00:00:04Z","event":"resumed"}' + "`n", [Text.UTF8Encoding]::new($false))
    $events = @(Get-RetryStatusEvents $index $paths)
    Assert ($events.Count -eq 4 -and $events[-1].event -eq 'resumed') 'Truncation did not replace the active shard.'
    Write-Output 'PASS validate-status-index'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
