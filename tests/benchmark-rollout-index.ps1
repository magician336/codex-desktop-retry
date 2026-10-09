$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('retry-rollout-benchmark-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
. (Join-Path $PSScriptRoot '..\retry\Retry.Rollouts.ps1')

try {
    $count = 2000
    for ($i = 0; $i -lt $count; $i++) {
        $path = Join-Path $root ("rollout-{0:D5}.jsonl" -f $i)
        ([ordered]@{ type = 'session_meta'; payload = [ordered]@{ id = "session-$i"; thread_name = "Session $i" } } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
    }
    $idx = New-RetryRolloutIndex
    $watch = [Diagnostics.Stopwatch]::StartNew(); [void](Get-RetryLiveRolloutSessions $idx @($root)); $watch.Stop(); $initialMs = $watch.Elapsed.TotalMilliseconds
    $before = Get-RetryRolloutIndexStats $idx
    $watch.Restart(); [void](Get-RetryLiveRolloutSessions $idx @($root)); $watch.Stop(); $unchangedMs = $watch.Elapsed.TotalMilliseconds
    $middle = Join-Path $root 'rollout-01000.jsonl'
    Add-Content -LiteralPath $middle -Value (([ordered]@{ type = 'event_msg'; payload = [ordered]@{ session_id = 'session-1000'; message = 'append' } } | ConvertTo-Json -Compress)) -Encoding UTF8
    Start-Sleep -Milliseconds 250
    $watch.Restart(); [void](Get-RetryLiveRolloutSessions $idx @($root)); $watch.Stop(); $appendMs = $watch.Elapsed.TotalMilliseconds
    $after = Get-RetryRolloutIndexStats $idx
    [ordered]@{
        Files = $count
        InitialMs = [math]::Round($initialMs, 2)
        UnchangedMs = [math]::Round($unchangedMs, 2)
        AppendMs = [math]::Round($appendMs, 2)
        InitialDirectoryScans = $before.DirectoryScans
        UnchangedDirectoryScans = $after.DirectoryScans
        InitialHeadersParsed = $before.FileHeadersParsed
        HeadersParsedAfterAppend = $after.FileHeadersParsed
        CacheHits = $after.CacheHits
    } | Format-List
} finally {
    Stop-RetryRolloutWatchers $idx
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
