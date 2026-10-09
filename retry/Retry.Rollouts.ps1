# Incremental discovery index for live rollout sessions used by the UI host.

function New-RetryRolloutIndex {
    return [pscustomobject]@{
        RootSignature = ''
        Roots = @()
        Watchers = [Collections.Generic.List[object]]::new()
        Subscriptions = [Collections.Generic.List[object]]::new()
        DirtyQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        Files = [ordered]@{}
        SessionIndexes = [ordered]@{}
        TitleMap = @{}
        LastReconciledAt = [datetime]::MinValue
        ReconcileSeconds = 60
        Stats = [ordered]@{
            DirectoryScans = 0
            FileHeadersParsed = 0
            SessionIndexReads = 0
            QueueEvents = 0
            Reconciliations = 0
            CacheHits = 0
        }
    }
}

function Get-RetryRolloutIndexStats($Index) {
    return [pscustomobject]$Index.Stats
}

function Stop-RetryRolloutWatchers($Index) {
    foreach ($subscription in @($Index.Subscriptions)) {
        try { Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Id $subscription.Action.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    $Index.Subscriptions.Clear()
    foreach ($watcher in @($Index.Watchers)) {
        try { $watcher.EnableRaisingEvents = $false; $watcher.Dispose() } catch { }
    }
    $Index.Watchers.Clear()
}

function Reset-RetryRolloutIndex($Index) {
    Stop-RetryRolloutWatchers $Index
    $Index.RootSignature = ''
    $Index.Roots = @()
    $Index.Files = [ordered]@{}
    $Index.SessionIndexes = [ordered]@{}
    $Index.TitleMap = @{}
    $Index.LastReconciledAt = [datetime]::MinValue
    $discard = $null
    while ($Index.DirtyQueue.TryDequeue([ref]$discard)) { $discard = $null }
}

function Normalize-RetryRolloutRoots([object[]]$Roots) {
    $normalized = [Collections.Generic.List[string]]::new()
    foreach ($root in @($Roots)) {
        if (-not $root) { continue }
        try { $full = [IO.Path]::GetFullPath([string]$root).TrimEnd('\') } catch { continue }
        if ($full -and -not @($normalized | Where-Object { $_.Equals($full, [StringComparison]::OrdinalIgnoreCase) })) { [void]$normalized.Add($full) }
    }
    return @($normalized.ToArray())
}

function Get-RetryRolloutFileSignature([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return [pscustomobject]@{
                Length = [int64]$item.Length
                LastWriteUtc = $item.LastWriteTimeUtc
                CreationUtc = $item.CreationTimeUtc
            }
        }
    } catch { }
    return $null
}

function Read-RetryRolloutHeader([string]$Path, $Index) {
    $signature = Get-RetryRolloutFileSignature $Path
    if ($null -eq $signature) { return $null }
    $sessionId = ''
    $title = ''
    foreach ($line in @(Get-Content -LiteralPath $Path -TotalCount 12 -ErrorAction SilentlyContinue)) {
        try {
            $row = $line | ConvertFrom-Json
            $payload = $row.PSObject.Properties['payload']
            $payloadValue = if ($payload) { $payload.Value } else { $null }
            $candidate = if ($payloadValue) { $payloadValue } else { $row }
            $type = if ($row.PSObject.Properties['type']) { [string]$row.type } else { '' }
            $candidateId = if ($candidate.PSObject.Properties['session_id']) { [string]$candidate.session_id } else { '' }
            if ($type -eq 'session_meta' -and $candidate.PSObject.Properties['id']) { $candidateId = [string]$candidate.id }
            if ($candidateId) { $sessionId = $candidateId }
            if (-not $title -and $candidate.PSObject.Properties['thread_name']) { $title = [string]$candidate.thread_name }
            if (-not $title -and $candidate.PSObject.Properties['message']) { $title = [string]$candidate.message }
        } catch { }
    }
    if (-not $sessionId) { $sessionId = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileName($Path)) }
    $Index.Stats.FileHeadersParsed++
    return [pscustomobject]@{
        Path = $Path
        SessionId = $sessionId
        RawTitle = $title
        LastEventAt = $signature.LastWriteUtc.ToLocalTime().ToString('o')
        Length = $signature.Length
        LastWriteUtc = $signature.LastWriteUtc
        CreationUtc = $signature.CreationUtc
    }
}

function Read-RetrySessionIndex([string]$Path, $Index) {
    $rows = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            try {
                $row = $line | ConvertFrom-Json
                $id = if ($row.PSObject.Properties['id']) { [string]$row.id } else { '' }
                $name = if ($row.PSObject.Properties['thread_name']) { [string]$row.thread_name } else { '' }
                if ($id -and $name) { $rows[$id] = $name }
            } catch { }
        }
    }
    $Index.Stats.SessionIndexReads++
    return $rows
}

function Rebuild-RetryRolloutTitleMap($Index) {
    $map = @{}
    foreach ($root in @($Index.Roots)) {
        $path = Join-Path $root 'session_index.jsonl'
        if ($Index.SessionIndexes.Contains($path)) {
            foreach ($pair in $Index.SessionIndexes[$path].Rows.GetEnumerator()) { $map[$pair.Key] = $pair.Value }
        }
    }
    $Index.TitleMap = $map
}

function Install-RetryRolloutWatchers($Index) {
    Stop-RetryRolloutWatchers $Index
    foreach ($root in @($Index.Roots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $watcher = [IO.FileSystemWatcher]::new($root, '*.jsonl')
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::CreationTime
        $queue = $Index.DirtyQueue
        foreach ($eventName in @('Created', 'Changed', 'Deleted')) {
            $subscription = Register-ObjectEvent -InputObject $watcher -EventName $eventName -MessageData $queue -Action { [void]$Event.MessageData.Enqueue($Event.SourceEventArgs.FullPath) }
            [void]$Index.Subscriptions.Add($subscription)
        }
        $subscription = Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $queue -Action { [void]$Event.MessageData.Enqueue($Event.SourceEventArgs.OldFullPath); [void]$Event.MessageData.Enqueue($Event.SourceEventArgs.FullPath) }
        [void]$Index.Subscriptions.Add($subscription)
        $subscription = Register-ObjectEvent -InputObject $watcher -EventName Error -MessageData $queue -Action { [void]$Event.MessageData.Enqueue('__retry_rollout_reconcile__') }
        [void]$Index.Subscriptions.Add($subscription)
        $watcher.EnableRaisingEvents = $true
        [void]$Index.Watchers.Add($watcher)
    }
}

function Update-RetryRolloutFile($Index, [string]$Path) {
    $full = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    if ([IO.Path]::GetFileName($full) -eq 'session_index.jsonl') {
        $signature = Get-RetryRolloutFileSignature $full
        $Index.SessionIndexes[$full] = [pscustomobject]@{ Signature = $signature; Rows = (Read-RetrySessionIndex $full $Index) }
        Rebuild-RetryRolloutTitleMap $Index
        return
    }
    if ([IO.Path]::GetFileName($full) -notlike 'rollout-*.jsonl') { return }
    $entry = Read-RetryRolloutHeader $full $Index
    if ($null -eq $entry) { [void]$Index.Files.Remove($full); return }
    $Index.Files[$full] = $entry
}

function Reconcile-RetryRolloutIndex($Index) {
    $Index.Stats.DirectoryScans++
    $Index.Stats.Reconciliations++
    $seen = @{}
    foreach ($root in @($Index.Roots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $indexPath = Join-Path $root 'session_index.jsonl'
        if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
            $signature = Get-RetryRolloutFileSignature $indexPath
            $cached = $Index.SessionIndexes[$indexPath]
            if ($null -eq $cached -or $cached.Signature.Length -ne $signature.Length -or $cached.Signature.LastWriteUtc -ne $signature.LastWriteUtc -or $cached.Signature.CreationUtc -ne $signature.CreationUtc) {
                $Index.SessionIndexes[$indexPath] = [pscustomobject]@{ Signature = $signature; Rows = (Read-RetrySessionIndex $indexPath $Index) }
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue)) {
            $full = $file.FullName
            $seen[$full] = $true
            $cached = $Index.Files[$full]
            if ($null -eq $cached -or $cached.Length -ne [int64]$file.Length -or $cached.LastWriteUtc -ne $file.LastWriteTimeUtc -or $cached.CreationUtc -ne $file.CreationTimeUtc) { Update-RetryRolloutFile $Index $full }
        }
    }
    foreach ($path in @($Index.Files.Keys)) { if (-not $seen.ContainsKey($path)) { [void]$Index.Files.Remove($path) } }
    foreach ($path in @($Index.SessionIndexes.Keys)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$Index.SessionIndexes.Remove($path) } }
    Rebuild-RetryRolloutTitleMap $Index
    $Index.LastReconciledAt = Get-Date
}

function Update-RetryRolloutIndex($Index, [object[]]$Roots) {
    $normalized = @(Normalize-RetryRolloutRoots $Roots)
    $signature = ($normalized -join '|').ToLowerInvariant()
    if ($signature -ne $Index.RootSignature) {
        Reset-RetryRolloutIndex $Index
        $Index.Roots = $normalized
        $Index.RootSignature = $signature
        Install-RetryRolloutWatchers $Index
        Reconcile-RetryRolloutIndex $Index
    }
    $dirty = @{}
    $path = $null
    while ($Index.DirtyQueue.TryDequeue([ref]$path)) {
        $Index.Stats.QueueEvents++
        if ($path -eq '__retry_rollout_reconcile__') { $Index.LastReconciledAt = [datetime]::MinValue; continue }
        $dirty[$path] = $true
    }
    foreach ($path in @($dirty.Keys)) { Update-RetryRolloutFile $Index $path }
    if ((Get-Date) - $Index.LastReconciledAt -ge [TimeSpan]::FromSeconds($Index.ReconcileSeconds)) { Reconcile-RetryRolloutIndex $Index }
    return $Index
}

function Get-RetryLiveRolloutSessions($Index, [object[]]$Roots) {
    $before = $Index.Stats.DirectoryScans + $Index.Stats.FileHeadersParsed + $Index.Stats.SessionIndexReads
    [void](Update-RetryRolloutIndex $Index $Roots)
    $after = $Index.Stats.DirectoryScans + $Index.Stats.FileHeadersParsed + $Index.Stats.SessionIndexReads
    if ($after -eq $before) { $Index.Stats.CacheHits++ }
    $found = [ordered]@{}
    foreach ($entry in @($Index.Files.Values)) {
        $title = if ($Index.TitleMap.ContainsKey($entry.SessionId)) { $Index.TitleMap[$entry.SessionId] } else { $entry.RawTitle }
        if (-not $title) { $title = $entry.SessionId }
        $found[$entry.SessionId] = [ordered]@{ id = $entry.SessionId; title = $title; hasRecord = $false; capacityErrors = 0; successes = 0; failures = 0; attempts = 0; firstSeen = ''; lastError = ''; lastEvent = 'listening'; lastEventAt = $entry.LastEventAt; reasons = @{}; timeline = @() }
    }
    return @($found.Values)
}
