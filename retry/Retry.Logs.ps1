# Log discovery, incremental JSONL reader and session resolver. No UI side effects.
function Get-RetryField($Object, [string] $Name, $Default = '') {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) { return $property.Value }
    return $Default
}

function Get-RetryEvent($Json) {
    $outer = [string](Get-RetryField $Json 'type')
    $payload = Get-RetryField $Json 'payload' $null
    $data = if ($outer -in @('event_msg', 'session_meta', 'turn_context', 'response_item')) { $payload } else { $Json }
    $kind = if ($outer -in @('event_msg', 'response_item')) { [string](Get-RetryField $data 'type') } else { $outer }
    $session = [string](Get-RetryField $data 'session_id')
    if (-not $session -and $outer -eq 'session_meta') { $session = [string](Get-RetryField $data 'id') }
    $turn = [string](Get-RetryField $data 'turn_id')
    $parent = [string](Get-RetryField $data 'retry_of_turn_id')
    if (-not $parent) { $parent = [string](Get-RetryField $data 'retried_turn_id') }
    $root = [string](Get-RetryField $data 'root_turn_id')
    if (-not $turn) {
        $metadata = Get-RetryField $data 'internal_chat_message_metadata_passthrough' $null
        $turn = [string](Get-RetryField $metadata 'turn_id')
    }
    [pscustomobject]@{ Kind = $kind; Outer = $outer; Data = $data; SessionId = $session; TurnId = $turn; ParentTurnId = $parent; RootTurnId = $root }
}

function New-RolloutCursor([string] $Path, [bool] $Baseline, $Monitor = $null) {
    $cursor = [pscustomobject]@{
        Path = $Path; Position = [int64]0; Partial = [byte[]]@(); SkipPartial = $false
        SessionId = ''; TurnId = ''; ActiveTurns = @{}; Title = ''
    }
    # Only read metadata at startup; existing errors are deliberately not replayed.
    if ($Baseline) {
        foreach ($line in @(Get-Content -LiteralPath $Path -TotalCount 12 -ErrorAction Stop)) {
            try { $event = Get-RetryEvent ($line | ConvertFrom-Json -ErrorAction Stop) }
            catch {
                if ($Monitor) { Write-RetryDiagnostic $Monitor 'rollout-metadata-parse' $Path $_.Exception }
                continue
            }
            if ($event.SessionId) { $cursor.SessionId = $event.SessionId }
        }
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $cursor.Position = $stream.Length
            if ($stream.Length -gt 0) {
                $stream.Position = $stream.Length - 1
                $cursor.SkipPartial = $stream.ReadByte() -ne 10
            }
        } finally { $stream.Dispose() }
    }
    return $cursor
}

function Test-RetryRolloutPath($Monitor, [string] $Path) {
    if (-not $Path -or [IO.Directory]::Exists($Path)) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -notin @('.jsonl', '.log')) { return $false }
    return $full -ne [IO.Path]::GetFullPath($Monitor.Options.StatePath) -and
        $full -ne [IO.Path]::GetFullPath($Monitor.Options.UiDiagnosticPath)
}

function Add-RetryLogCursor($Monitor, [string] $Path, [bool] $Baseline) {
    if (-not (Test-RetryRolloutPath $Monitor $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if ($Monitor.Files.Contains($full) -or -not [IO.File]::Exists($full)) { return }
    try { $Monitor.Files[$full] = New-RolloutCursor $full $Baseline $Monitor }
    catch { Write-RetryDiagnostic $Monitor 'log-cursor' $full $_.Exception }
}

function Initialize-RetryLogWatchers($Monitor) {
    if ($Monitor.WatchersReady) { return }
    foreach ($root in $Monitor.Options.LogRoot) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            $queue = $Monitor.PendingPaths
            $watcher = [IO.FileSystemWatcher]::new([IO.Path]::GetFullPath($root))
            $watcher.IncludeSubdirectories = $true
            $watcher.Filter = '*.*'
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
            # Register-ObjectEvent marshals callbacks onto a PowerShell runspace;
            # invoking a script delegate directly from FileSystemWatcher threads
            # can fail with "There is no Runspace available".
            $action = { $Event.MessageData.Enqueue($EventArgs.FullPath) }
            $renameAction = { $Event.MessageData.Enqueue($EventArgs.FullPath); $Event.MessageData.Enqueue($EventArgs.OldFullPath) }
            $subscriptions = @(
                Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $queue -Action $action
                Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $queue -Action $action
                Register-ObjectEvent -InputObject $watcher -EventName Deleted -MessageData $queue -Action $action
                Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $queue -Action $renameAction
            )
            $watcher.EnableRaisingEvents = $true
            $Monitor.Watchers.Add([pscustomobject]@{ Watcher = $watcher; Subscriptions = $subscriptions })
        } catch { Write-RetryDiagnostic $Monitor 'log-watcher' $root $_.Exception }
    }
    $Monitor.WatchersReady = $Monitor.Watchers.Count -gt 0
}

function Dispose-RetryLogWatchers($Monitor) {
    foreach ($entry in @($Monitor.Watchers)) {
        try {
            $entry.Watcher.EnableRaisingEvents = $false
            foreach ($subscription in @($entry.Subscriptions)) {
                Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
                Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
            }
            $entry.Watcher.Dispose()
        } catch { Write-RetryDiagnostic $Monitor 'log-watcher-dispose' '' $_.Exception }
    }
    $Monitor.Watchers.Clear(); $Monitor.WatchersReady = $false
}

function Update-RetryLogCache($Monitor, [datetime] $Now, [switch] $Force) {
    $rescanSeconds = if ($Monitor.Options.ContainsKey('RescanSeconds')) { [int]$Monitor.Options.RescanSeconds } else { 60 }
    $rescan = $Force -or -not $Monitor.Initialized -or ($Now - $Monitor.LastScan).TotalSeconds -ge $rescanSeconds
    if (-not $Monitor.Initialized -or $rescan) {
        $baseline = -not $Monitor.Initialized
        $found = @{}
        foreach ($root in $Monitor.Options.LogRoot) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            try {
                # Full discovery is startup/periodic reconciliation only; normal changes arrive from watchers.
                foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop) {
                    if (-not (Test-RetryRolloutPath $Monitor $file.FullName)) { continue }
                    $full = [IO.Path]::GetFullPath($file.FullName); $found[$full] = $true
                    Add-RetryLogCursor $Monitor $full $baseline
                }
            } catch { Write-RetryDiagnostic $Monitor 'log-discovery' $root $_.Exception }
        }
        foreach ($path in @($Monitor.Files.Keys)) {
            if (-not $found.ContainsKey($path) -and -not [IO.File]::Exists($path)) { $Monitor.Files.Remove($path) }
        }
        $Monitor.LastScan = $Now
        $Monitor.Initialized = $true
        Initialize-RetryLogWatchers $Monitor
    }
    $path = ''
    while ($Monitor.PendingPaths.TryDequeue([ref]$path)) {
        if ([IO.File]::Exists($path)) { Add-RetryLogCursor $Monitor $path $false }
        elseif ($Monitor.Files.Contains([IO.Path]::GetFullPath($path))) { $Monitor.Files.Remove([IO.Path]::GetFullPath($path)) }
    }
}

function Read-RolloutRecords($Monitor, $Cursor) {
    $stream = $null
    try {
        $stream = [IO.File]::Open($Cursor.Path, 'Open', 'Read', 'ReadWrite')
        if ($stream.Length -lt $Cursor.Position) {
            $Cursor.Position = [int64]0; $Cursor.Partial = [byte[]]@(); $Cursor.SkipPartial = $false
            $Cursor.TurnId = ''; $Cursor.SessionId = ''; $Cursor.ActiveTurns.Clear()
        }
        if ($stream.Length -eq $Cursor.Position) { return }
        $stream.Position = $Cursor.Position
        $remaining = $stream.Length - $Cursor.Position
        $partial = [IO.MemoryStream]::new()
        try {
            $partial.Write($Cursor.Partial, 0, $Cursor.Partial.Length)
            $buffer = [byte[]]::new(65536)
            while ($remaining -gt 0) {
                $count = $stream.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
                if ($count -le 0) { break }
                for ($i = 0; $i -lt $count; $i++) {
                    $Cursor.Position++
                    if ($buffer[$i] -eq 10) {
                        if (-not $Cursor.SkipPartial -and $partial.Length -gt 0) {
                            $line = [Text.Encoding]::UTF8.GetString($partial.ToArray()).TrimEnd("`r")
                            try {
                                $json = $line | ConvertFrom-Json -ErrorAction Stop
                                [pscustomobject]@{ Event = (Get-RetryEvent $json); Raw = $line; EndOffset = $Cursor.Position; Path = $Cursor.Path }
                            } catch { Write-RetryDiagnostic $Monitor 'jsonl-parse' $Cursor.Path $_.Exception }
                        }
                        $partial.SetLength(0); $Cursor.SkipPartial = $false
                    } elseif (-not $Cursor.SkipPartial) { $partial.WriteByte($buffer[$i]) }
                }
                $remaining -= $count
            }
            $Cursor.Partial = $partial.ToArray()
        } finally { $partial.Dispose() }
    } catch { Write-RetryDiagnostic $Monitor 'rollout-read' $Cursor.Path $_.Exception }
    finally { if ($stream) { $stream.Dispose() } }
}

function Resolve-RetrySession($Monitor, $Cursor, $Record) {
    $event = $Record.Event
    $turnId = $event.TurnId
    # An untagged record cannot be attributed when the rollout has concurrent turns.
    if (-not $turnId -and $Cursor.ActiveTurns.Count -eq 1) { $turnId = [string]@($Cursor.ActiveTurns.Keys)[0] }
    $title = $Cursor.Title
    if ($Cursor.SessionId) {
        foreach ($root in $Monitor.Options.LogRoot) {
            $index = Join-Path $root 'session_index.jsonl'
            if (-not [IO.File]::Exists($index)) { continue }
            $modified = [IO.File]::GetLastWriteTimeUtc($index)
            if (-not $Monitor.IndexTimes.ContainsKey($index) -or $Monitor.IndexTimes[$index] -ne $modified) {
                try {
                    foreach ($line in Get-Content -LiteralPath $index -ErrorAction Stop) {
                        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { Write-RetryDiagnostic $Monitor 'session-index-parse' $index $_.Exception; continue }
                        $id = [string](Get-RetryField $row 'id')
                        $name = [string](Get-RetryField $row 'thread_name')
                        if ($id -and $name) { $Monitor.Titles[$id] = $name }
                    }
                    $Monitor.IndexTimes[$index] = $modified
                } catch { Write-RetryDiagnostic $Monitor 'session-index' $index $_.Exception }
            }
        }
        if ($Monitor.Titles.ContainsKey($Cursor.SessionId)) { $title = $Monitor.Titles[$Cursor.SessionId] }
    }
    [pscustomobject]@{
        SessionId = $Cursor.SessionId; TurnId = $turnId; Title = $title
        SourcePath = $Cursor.Path; ErrorOffset = $Record.EndOffset
    }
}

function Update-RolloutContext($Cursor, $Event) {
    if ($event.SessionId) { $Cursor.SessionId = $event.SessionId }
    if ($event.TurnId -and $event.Kind -in @('task_started', 'turn_started', 'turn_context')) {
        $Cursor.TurnId = $event.TurnId
        $Cursor.ActiveTurns[$event.TurnId] = $true
    }
    if ($event.TurnId -and $event.Kind -in @('task_complete', 'turn_complete', 'turn_aborted')) {
        $Cursor.ActiveTurns.Remove($event.TurnId)
    }
    if (-not $Cursor.Title) {
        $text = ''
        if ($Event.Kind -eq 'user_message') { $text = [string](Get-RetryField $Event.Data 'message') }
        elseif ((Get-RetryField $Event.Data 'role') -eq 'user') {
            foreach ($part in @(Get-RetryField $Event.Data 'content' @())) {
                $text = [string](Get-RetryField $part 'text')
                if ($text) { break }
            }
        }
        if ($text) {
            $text = [regex]::Replace($text, '\[([^\]]+)\]\([^)]*\)', '$1')
            $Cursor.Title = [regex]::Replace($text, '\s+', ' ').Trim()
        }
    }
}
