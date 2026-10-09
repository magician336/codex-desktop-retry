# Per-session state machine and bounded JSONL persistence.
function New-RetryMonitor($Options) {
    [pscustomobject]@{
        Options = $Options
        Files = @{}
        Sessions = @{}
        UiOwner = ''
        UiLines = [Collections.Generic.List[string]]::new()
        Titles = @{}
        IndexTimes = @{}
        LastScan = [datetime]::MinValue
        Initialized = $false
        Watchers = [Collections.Generic.List[object]]::new()
        PendingPaths = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        WatchersReady = $false
        UiLeaseStarted = [datetime]::MinValue
        StateMutex = [Threading.Mutex]::new($false, 'Local\CodexDesktopRetryState')
    }
}

function Write-RetryDiagnostic($Monitor, [string] $Stage, [string] $Control, [System.Exception] $Exception, [string] $Message = '') {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o'); stage = $Stage; control = $Control
        message = if ($Message) { $Message } elseif ($Exception) { $Exception.Message } else { '' }
        exception = if ($Exception) { $Exception.GetType().FullName } else { '' }
    }
    try {
        Write-BoundedRetryRecord $Monitor $Monitor.Options.UiDiagnosticPath $record
    } catch { Write-Warning "Unable to write diagnostic: $($_.Exception.Message)" }
}

function Get-RetrySessionState($Monitor, [string] $SessionKey) {
    if (-not $Monitor.Sessions.ContainsKey($SessionKey)) {
        $Monitor.Sessions[$SessionKey] = [pscustomobject]@{
            RetryCount = 0; NextEligible = [datetime]::MinValue; Phase = 'observing'
            LastAttempt = [datetime]::MinValue; Active = $null
            Queue = [Collections.Generic.List[object]]::new()
        }
    }
    return $Monitor.Sessions[$SessionKey]
}

function Rotate-RetryState($Monitor, [string] $Path, [int] $IncomingBytes) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $path).Length + $IncomingBytes -le $Monitor.Options.StateMaxBytes) { return }
    if ($Monitor.Options.StateMaxFiles -eq 1) {
        [IO.File]::WriteAllText($path, '', [Text.UTF8Encoding]::new($false))
        return
    }
    $oldest = "$path.$($Monitor.Options.StateMaxFiles)"
    if (Test-Path -LiteralPath $oldest -PathType Leaf) { Remove-Item -LiteralPath $oldest -Force }
    for ($index = $Monitor.Options.StateMaxFiles - 1; $index -ge 1; $index--) {
        $source = "$path.$index"; $destination = "$path.$($index + 1)"
        if (Test-Path -LiteralPath $source -PathType Leaf) { Move-Item -LiteralPath $source -Destination $destination -Force }
    }
    Move-Item -LiteralPath $path -Destination "$path.1" -Force
}

function Write-BoundedRetryRecord($Monitor, [string] $Path, $Record) {
    # Limit diagnostic strings too, so even one record fits in the active file.
    foreach ($key in @($Record.Keys)) {
        if ($Record[$key] -is [string] -and $Record[$key].Length -gt 256) { $Record[$key] = $Record[$key].Substring(0, 256) }
    }
    $line = ($Record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine
    $locked = $false
    try {
        try { $locked = $Monitor.StateMutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out waiting for retry-state mutex.' }
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $bytes = [Text.Encoding]::UTF8.GetByteCount($line)
        if ($bytes -gt $Monitor.Options.StateMaxBytes) { throw 'State record exceeds StateMaxBytes.' }
        Rotate-RetryState $Monitor $Path $bytes
        [IO.File]::AppendAllText($Path, $line, [Text.UTF8Encoding]::new($false))
    } finally { if ($locked) { $Monitor.StateMutex.ReleaseMutex() | Out-Null } }
}

function Write-RetryState($Monitor, [string] $Event, [string] $Detail = '', [string] $SessionKey = '', [hashtable] $Extra = $null) {
    $record = [ordered]@{ timestamp = (Get-Date).ToString('o'); event = $Event; session = $SessionKey; detail = $Detail }
    if ($SessionKey -and $Monitor.Sessions.ContainsKey($SessionKey)) {
        $record.retry = $Monitor.Sessions[$SessionKey].RetryCount
        $record.phase = $Monitor.Sessions[$SessionKey].Phase
    }
    if ($Extra) { foreach ($key in $Extra.Keys) { $record[$key] = $Extra[$key] } }
    try {
        Write-BoundedRetryRecord $Monitor $Monitor.Options.StatePath $record
    } catch { Write-RetryDiagnostic $Monitor 'state-write' $Monitor.Options.StatePath $_.Exception }
}

function Get-RetrySessionKey($Hint) {
    if ($Hint.SessionId) { return [string]$Hint.SessionId }
    return "path:$($Hint.SourcePath)"
}
