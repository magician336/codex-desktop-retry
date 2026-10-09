$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('retry-rollout-index-' + [guid]::NewGuid().ToString('N'))
$root2 = Join-Path ([IO.Path]::GetTempPath()) ('retry-rollout-index-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root, $root2 -Force | Out-Null
. (Join-Path $PSScriptRoot '..\retry\Retry.Rollouts.ps1')

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Jsonl([string]$Path, [object[]]$Rows) { $Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 } | Set-Content -LiteralPath $Path -Encoding UTF8 }

try {
    $indexPath = Join-Path $root 'session_index.jsonl'
    $rolloutA = Join-Path $root 'rollout-a.jsonl'
    $rolloutB = Join-Path $root 'rollout-b.jsonl'
    Write-Jsonl $indexPath @([ordered]@{ id = 'session-a'; thread_name = '标题 A' })
    Write-Jsonl $rolloutA @([ordered]@{ type = 'session_meta'; payload = [ordered]@{ id = 'session-a'; thread_name = '原始标题' } })
    $idx = New-RetryRolloutIndex
    [void](Get-RetryLiveRolloutSessions $idx @($root))
    $stats1 = Get-RetryRolloutIndexStats $idx
    Assert ($stats1.DirectoryScans -eq 1 -and $stats1.FileHeadersParsed -eq 1 -and $stats1.SessionIndexReads -eq 1) '首次发现计数不正确。'
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root))
    $stats2 = Get-RetryRolloutIndexStats $idx
    Assert ($rows.Count -eq 1 -and $rows[0].title -eq '标题 A') ("session_index 标题优先级不正确: " + ($rows | ConvertTo-Json -Compress))
    Assert ($stats2.DirectoryScans -eq $stats1.DirectoryScans -and $stats2.FileHeadersParsed -eq $stats1.FileHeadersParsed -and $stats2.SessionIndexReads -eq $stats1.SessionIndexReads) '无变化请求重复扫描。'

    Add-Content -LiteralPath $rolloutA -Value (([ordered]@{ type = 'event_msg'; payload = [ordered]@{ session_id = 'session-a'; message = '追加' } } | ConvertTo-Json -Compress)) -Encoding UTF8
    Start-Sleep -Milliseconds 250
    [void](Get-RetryLiveRolloutSessions $idx @($root))
    $stats3 = Get-RetryRolloutIndexStats $idx
    Assert ($stats3.FileHeadersParsed -eq ($stats2.FileHeadersParsed + 1)) '变更文件没有增量重读。'

    Write-Jsonl $rolloutB @([ordered]@{ type = 'session_meta'; payload = [ordered]@{ id = 'session-b'; thread_name = '标题 B' } })
    Start-Sleep -Milliseconds 250
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root))
    Assert ($rows.Count -eq 2 -and @($rows | Where-Object id -eq 'session-b').Count -eq 1) '新增 rollout 没有被发现。'

    $rolloutRenamed = Join-Path $root 'rollout-renamed.jsonl'
    Move-Item -LiteralPath $rolloutB -Destination $rolloutRenamed -Force
    Start-Sleep -Milliseconds 250
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root))
    Assert ($rows.Count -eq 2 -and @($rows | Where-Object id -eq 'session-b').Count -eq 1) '重命名 rollout 没有正确重建缓存。'

    Remove-Item -LiteralPath $rolloutA -Force
    Start-Sleep -Milliseconds 250
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root))
    Assert ($rows.Count -eq 1 -and $rows[0].id -eq 'session-b') '删除 rollout 没有移除缓存条目。'

    Write-Jsonl $indexPath @([ordered]@{ id = 'session-b'; thread_name = '更新标题 B' })
    Start-Sleep -Milliseconds 250
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root))
    Assert ($rows[0].title -eq '更新标题 B') 'session_index 变更没有刷新标题。'

    $rolloutC = Join-Path $root2 'rollout-c.jsonl'
    Write-Jsonl $rolloutC @([ordered]@{ type = 'session_meta'; payload = [ordered]@{ id = 'session-c'; thread_name = '标题 C' } })
    $rows = @(Get-RetryLiveRolloutSessions $idx @($root2))
    Assert ($rows.Count -eq 1 -and $rows[0].id -eq 'session-c') 'logRoot 切换没有重建缓存。'
    Write-Host 'PASS validate-rollout-index'
} finally {
    Stop-RetryRolloutWatchers $idx
    Remove-Item -LiteralPath $root, $root2 -Recurse -Force -ErrorAction SilentlyContinue
}
