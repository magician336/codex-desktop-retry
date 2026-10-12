# Frozen usable build, 2026-10-12. Further development uses the root launcher.
[CmdletBinding()]
param(
    [string[]] $LogRoot = @((Join-Path $env:USERPROFILE '.codex')),
    [string[]] $ProcessName = @('ChatGPT', 'Codex', 'OpenAI.Codex'),
    [int] $MaxRetries = 0,
    [int[]] $BackoffSeconds = @(0),
    [double] $PollSeconds = 0.25,
    [int] $CooldownSeconds = 20,
    [int] $RetryUiWaitSeconds = 90,
    [int] $RetryConfirmSeconds = 30,
    [int] $UiLeaseSeconds = 5,
    [int] $UiSnapshotMaxMilliseconds = 5000,
    [int] $RescanSeconds = 60,
    [int64] $StateMaxBytes = 1048576,
    [int] $StateMaxFiles = 3,
    [switch] $AllowNativeClick,
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log'),
    [string] $ControlPath = (Join-Path $PSScriptRoot 'retry-control.json'),
    [string] $RuntimePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($MaxRetries -lt 0) { throw 'MaxRetries must be >= 0.' }
if ($PollSeconds -le 0) { throw 'PollSeconds must be > 0.' }
if ($CooldownSeconds -lt 0) { throw 'CooldownSeconds must be >= 0.' }
if ($RetryUiWaitSeconds -le 0) { throw 'RetryUiWaitSeconds must be > 0.' }
if ($RetryConfirmSeconds -le 0) { throw 'RetryConfirmSeconds must be > 0.' }
if ($UiLeaseSeconds -le 0) { throw 'UiLeaseSeconds must be > 0.' }
if ($UiSnapshotMaxMilliseconds -lt 500) { throw 'UiSnapshotMaxMilliseconds must be >= 500.' }
if ($RescanSeconds -lt 10) { throw 'RescanSeconds must be at least 10.' }
if ($BackoffSeconds.Count -eq 0 -or @($BackoffSeconds | Where-Object { $_ -lt 0 }).Count -gt 0) {
    throw 'BackoffSeconds must contain non-negative values.'
}
if ($StateMaxBytes -lt 4096) { throw 'StateMaxBytes must be at least 4096.' }
if ($StateMaxFiles -lt 1) { throw 'StateMaxFiles must be at least 1.' }
# Accept legacy comma-separated command-line values while preserving repeated
# -ProcessName arguments emitted by the UI launcher.
$ProcessName = @($ProcessName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ProcessName.Count -eq 0) { throw 'ProcessName must contain at least one process name.' }
$RuntimePath = Get-RetryMonitorRuntimePath $StatePath $RuntimePath

# Only one monitor may consume a given rollout root. Multiple UI consoles can
# otherwise watch the same capacity event and race each other's UI leases,
# producing repeated ui-yield/retry-superseded results. A per-root named mutex
# also works when each console uses its own temporary state file.
$rootKey = [string](@($LogRoot | Sort-Object) -join '|')
$sha = [Security.Cryptography.SHA256]::Create()
try { $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rootKey))).Replace('-', '')).Substring(0, 24) }
finally { $sha.Dispose() }
$mutexName = "Local\CodexDesktopRetryMonitor-$rootHash"
$mutexCreated = $false
$monitorMutex = [Threading.Mutex]::new($false, $mutexName, [ref]$mutexCreated)
if (-not $mutexCreated) {
    $existing = Read-RetryMonitorRuntime $RuntimePath
    $monitorMutex.Dispose()
    if ($existing -and [int]$existing.pid -gt 0) {
        try {
            $existingProcess = Get-Process -Id ([int]$existing.pid) -ErrorAction Stop
            if (-not $existingProcess.HasExited) {
                Write-Host "Codex Desktop retry monitor is already running (PID $($existing.pid)); using the existing instance." -ForegroundColor Yellow
                exit 0
            }
        } catch { }
    }
    Write-Error "A Codex Desktop retry monitor is already running for: $rootKey"
    exit 2
}

# Shared runtime registration for the standalone monitor and the local console.
# The registration is advisory; the named mutex remains the single-instance
# guard. A PID is accepted only while the registered process is still alive.

function Get-RetryMonitorRuntimePath([string]$StatePath, [string]$RuntimePath = '') {
    if ($RuntimePath) { return [IO.Path]::GetFullPath($RuntimePath) }
    return ([IO.Path]::GetFullPath($StatePath) + '.runtime.json')
}

function Write-RetryMonitorRuntime([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$PID.tmp"
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-RetryMonitorRuntime([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Remove-RetryMonitorRuntime([string]$Path, [int]$OwnerPid = $PID) {
    $runtime = Read-RetryMonitorRuntime $Path
    if ($runtime -and [int]$runtime.pid -eq $OwnerPid) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

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
    $isSubagent = $false
    if ($outer -eq 'session_meta') {
        # Forked rollouts put the parent thread in session_id and their own
        # thread id in id. The child id is the only safe UI target.
        $id = [string](Get-RetryField $data 'id')
        $source = Get-RetryField $data 'source' $null
        $isSubagent = [bool]((Get-RetryField $data 'forked_from_id') -or
            (Get-RetryField $data 'thread_source') -eq 'subagent' -or
            (Get-RetryField $source 'subagent'))
        if ($id) { $session = $id }
    }
    $turn = [string](Get-RetryField $data 'turn_id')
    $parent = [string](Get-RetryField $data 'retry_of_turn_id')
    if (-not $parent) { $parent = [string](Get-RetryField $data 'retried_turn_id') }
    $root = [string](Get-RetryField $data 'root_turn_id')
    if (-not $turn) {
        $metadata = Get-RetryField $data 'internal_chat_message_metadata_passthrough' $null
        $turn = [string](Get-RetryField $metadata 'turn_id')
    }
    [pscustomobject]@{ Kind = $kind; Outer = $outer; Data = $data; SessionId = $session; IsSubagent = $isSubagent; TurnId = $turn; ParentTurnId = $parent; RootTurnId = $root }
}

function New-RolloutCursor([string] $Path, [bool] $Baseline, $Monitor = $null) {
    $cursor = [pscustomobject]@{
        Path = $Path; Position = [int64]0; Partial = [byte[]]@(); SkipPartial = $false
        SessionId = ''; IsSubagent = $false; TurnId = ''; ActiveTurns = @{}; Title = ''
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
            if ($event.IsSubagent) { $cursor.IsSubagent = $true }
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
    # Archived rollouts are historical records and have no visible desktop
    # session to retry. Watching them creates a large backlog that can starve
    # the current session's capacity request.
    if ($full -match '(?i)\\archived_sessions\\') { return $false }
    # LogRoot also contains session_index.jsonl, sandbox logs, and other JSONL
    # files that may mention capacity in a title or diagnostic. Only rollout
    # streams carry turn-scoped events that can safely trigger a retry.
    if ([IO.Path]::GetExtension($full) -ne '.jsonl' -or
        [IO.Path]::GetFileName($full) -notlike 'rollout-*.jsonl') { return $false }
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
                $scanRoot = Join-Path $root 'sessions'
                if (Test-Path -LiteralPath $scanRoot -PathType Container) {
                    # Only today's rollouts can become a current desktop retry.
                    # Historical session trees are immutable workload and make
                    # startup reconciliation starve the live watcher.
                    $todayRoot = Join-Path $scanRoot ((Get-Date).ToString('yyyy\\MM\\dd'))
                    # Around midnight the new date directory may not exist yet.
                    # Do not fall back to the entire sessions tree, otherwise a
                    # periodic rescan replays every historical rollout from byte 0.
                    if (-not (Test-Path -LiteralPath $todayRoot -PathType Container)) { continue }
                    $scanRoot = $todayRoot
                } else { $scanRoot = $root }
                foreach ($file in Get-ChildItem -LiteralPath $scanRoot -Recurse -File -ErrorAction Stop) {
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
        if ([IO.File]::Exists($path)) {
            # FileSystemWatcher observes the whole log tree. A historical
            # rollout can be touched after startup, but its old capacity
            # records must not be replayed as fresh retry requests. Only a
            # rollout under today's sessions directory may start at offset 0.
            $today = (Get-Date).ToString('yyyy\\MM\\dd')
            $todayMarker = [IO.Path]::DirectorySeparatorChar + 'sessions' + [IO.Path]::DirectorySeparatorChar + $today + [IO.Path]::DirectorySeparatorChar
            $isToday = $path.IndexOf($todayMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0
            Add-RetryLogCursor $Monitor $path (-not $isToday)
        }
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
        SessionId = $Cursor.SessionId; IsSubagent = $Cursor.IsSubagent; TurnId = $turnId; Title = $title
        SourcePath = $Cursor.Path; ErrorOffset = $Record.EndOffset
    }
}

function Update-RolloutContext($Cursor, $Event) {
    if ($event.SessionId) { $Cursor.SessionId = $event.SessionId }
    if ($event.IsSubagent) { $Cursor.IsSubagent = $true }
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

# Desktop adapter: session resolver -> navigation -> retry actuator.
# The isolated worker can enter at verify/actuate with an existing window, so
# it must load UIAutomation before any typed AutomationElement reference runs.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# The isolated UI worker loads this file without Retry.Monitor.ps1. Keep the
# shared capacity classifier available for the reconnect-overlay fallback.
if (-not (Get-Command Test-CapacityText -CommandType Function -ErrorAction SilentlyContinue)) {
    function Test-CapacityText([string] $Text) {
        $Text -match 'Selected model is at capacity|model[_ -]capacity[_ -]exceeded|server[_ -]?(?:is[_ -]?)?overloaded|currently overloaded|overloaded_error'
    }
}

function Get-DesktopWindows($Monitor) {
    # PowerShell's -Name binding behaves differently across versions when given
    # an array. Enumerate each configured name explicitly and de-duplicate the
    # handles; Electron can expose several renderer processes for one window.
    $seen = @{}
    foreach ($name in @($Monitor.Options.ProcessName)) {
        foreach ($process in @(Get-Process -Name ([string]$name) -ErrorAction SilentlyContinue)) {
            $handle = [IntPtr]$process.MainWindowHandle
            if ($handle -ne [IntPtr]::Zero -and -not $seen.ContainsKey($handle.ToInt64())) {
                $seen[$handle.ToInt64()] = $true
                [pscustomobject]@{ Handle = $handle; ProcessId = $process.Id }
            }
        }
    }
}

function Get-RetryUiTypeName($ControlType) {
    if ($null -eq $ControlType) { return '' }
    try {
        $programmatic = [string]$ControlType.ProgrammaticName
        if ($programmatic -match '^ControlType\.(.+)$') { return $Matches[1] }
        return $programmatic
    } catch { return '' }
}

function Read-DesktopSnapshot($Window, $Monitor) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($Window.Handle)
    # FindAll can block inside the Electron accessibility provider while a
    # response is rendering. A blocked snapshot also blocks the monitor's
    # deadline and prevents every other session from being retried. Walk the
    # control tree in bounded steps so a bad provider call becomes a normal
    # retry-failed event instead of a stuck UI lease.
    $maxMilliseconds = 5000
    if ($Monitor.Options.ContainsKey('UiSnapshotMaxMilliseconds')) {
        $maxMilliseconds = [int]$Monitor.Options.UiSnapshotMaxMilliseconds
    }
    if ($maxMilliseconds -lt 500) { $maxMilliseconds = 500 }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $pending = [Collections.Generic.Stack[object]]::new()
    $child = $walker.GetFirstChild($root)
    while ($child) {
        $pending.Push($child)
        $child = $walker.GetNextSibling($child)
    }
    while ($pending.Count -gt 0) {
        if ($clock.ElapsedMilliseconds -ge $maxMilliseconds) {
            throw "UI snapshot exceeded ${maxMilliseconds}ms."
        }
        $element = $pending.Pop()
        $child = $walker.GetFirstChild($element)
        while ($child) {
            $pending.Push($child)
            $child = $walker.GetNextSibling($child)
        }
        try {
            $current = $element.Current
            if ($null -eq $current) { continue }
            $sidebar = $current.ClassName -match 'sidebar-item|sidebar-row|folder-row|group/cwd'
            $searchRegion = $false
            $ancestor = $element
            for ($depth = 0; $depth -lt 20; $depth++) {
                try { $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor) } catch { break }
                if (-not $ancestor) { break }
                try { $ancestorCurrent = $ancestor.Current } catch { break }
                if ($null -eq $ancestorCurrent) { break }
                $class = [string]$ancestorCurrent.ClassName
                if ($class -match 'sidebar-item|sidebar-row|folder-row|app-shell-left-panel') { $sidebar = $true }
                $ancestorType = Get-RetryUiTypeName $ancestorCurrent.ControlType
                if ($class -match 'dialog|command-menu|search-results|search-result|search-modal' -or
                    ($ancestorType -eq 'Window' -and [string]$ancestorCurrent.Name -match '(?i)search|搜索|命令菜单')) { $searchRegion = $true }
                if ($ancestorType -eq 'Document') { break }
            }
            $type = Get-RetryUiTypeName $current.ControlType
            if ($type -eq 'ComboBox' -and [string]$current.Name -match '(?i)search|搜索|命令菜单') { $searchRegion = $true }
            [pscustomobject]@{
                Element = $element; Name = [string]$current.Name; Id = [string]$current.AutomationId
                Class = [string]$current.ClassName; Type = $type
                Enabled = $current.IsEnabled; Visible = -not $current.IsOffscreen
                Sidebar = $sidebar; SearchRegion = $searchRegion
            }
        } catch { Write-RetryDiagnostic $Monitor 'ui-snapshot' '' $_.Exception }
    }
}

function Test-UiSessionMatch($Node, $Hint, $Monitor) {
    if ($Hint.SessionId) {
        if ($Node.Name -eq $Hint.SessionId -or ([string]$Node.Id).Contains($Hint.SessionId)) { return $true }
        # A forked rollout may inherit its parent's title. Never navigate to
        # that parent when the child session id is not exposed by the UI.
        if (Get-RetryField $Hint 'IsSubagent' $false) { return $false }
    }
    if (-not $Hint.Title -or -not $Node.Name) { return $false }
    $expected = [regex]::Replace([string]$Hint.Title, '\s+', ' ').Trim()
    $actual = [regex]::Replace([string]$Node.Name, '\s+', ' ').Trim()
    $prefix = if ($expected.Length -ge 8) { $expected.Substring(0, [Math]::Min(32, $expected.Length)) } else { '' }
    $actualVariants = @($actual)
    $withoutStatus = [regex]::Replace($actual, '(?i)^(处理中|正在处理|运行中|等待中|已完成|完成|失败|queued|running|working|completed|failed)\s+', '')
    if ($withoutStatus -ne $actual) { $actualVariants += $withoutStatus }
    $titleMatch = @($actualVariants | Where-Object {
        $_ -ceq $expected -or ($prefix -and $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
    }).Count -gt 0
    if (-not $titleMatch) { return $false }
    # Reject identical titles belonging to different sessions instead of picking the first.
    $duplicates = @($Monitor.Titles.Keys | Where-Object { $Monitor.Titles[$_] -ceq $Hint.Title -and $_ -ne $Hint.SessionId })
    return $duplicates.Count -eq 0
}

function Find-SessionTarget($Snapshot, $Hint, $Monitor, [bool] $SearchResults = $false) {
    $matches = @($Snapshot | Where-Object {
        $_.Visible -and $_.Enabled -and $_.Type -in @('Button', 'Hyperlink', 'ListItem') -and
        (($_.Sidebar -and -not $SearchResults) -or ($SearchResults -and (-not $_.Sidebar -or $_.SearchRegion))) -and
        (Test-UiSessionMatch $_ $Hint $Monitor)
    })
    if ($matches.Count -gt 1) {
        # Electron exposes a row button and one or more nested accessible nodes
        # with the same title. Collapse those aliases before declaring ambiguity.
        $groups = @($matches | Group-Object { "$($_.Type)|$($_.Name)|$($_.Class)" })
        if ($groups.Count -eq 1) { return $groups[0].Group[0] }
        $exact = @($matches | Where-Object { $_.Name -eq $Hint.SessionId -or $_.Name -eq $Hint.Title })
        if ($exact.Count -eq 1) { return $exact[0] }
        $selected = @($exact | Where-Object { $_.Class -match 'app-action-sidebar-thread-selected=true|bg-primary-ghost-hover' })
        if ($selected.Count -eq 1) { return $selected[0] }
        $buttons = @($exact | Where-Object { $_.Type -eq 'Button' })
        if ($buttons.Count -eq 1) { return $buttons[0] }
        throw "Ambiguous session targets. session=$($Hint.SessionId) candidates=$($matches.Name -join '|')"
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-ActiveSession($Snapshot, $Hint, $Monitor) {
    foreach ($node in $Snapshot) {
        if ($node.Visible -and -not $node.Sidebar -and -not $node.SearchRegion -and
            $node.Type -eq 'Document' -and (Test-UiSessionMatch $node $Hint $Monitor)) { return $true }
    }
    return $false
}

function Test-UiSearchOpen($Snapshot) {
    @($Snapshot | Where-Object {
        $_.Visible -and $_.Type -eq 'Window' -and [string]$_.Name -match '(?i)search|搜索|命令菜单'
    }).Count -gt 0
}

function Invoke-UiNode($Node, $Monitor, [string] $Stage, [bool] $Navigation = $false) {
    $element = $Node.Element
    # LegacyIAccessiblePattern is not exposed by the PowerShell 7 UIAutomation
    # assembly on every Windows installation. Invoke and Selection cover the
    # controls used by the current Electron client without a hard type load.
    $patterns = @([Windows.Automation.InvokePattern]::Pattern)
    if ($Navigation) { $patterns += [Windows.Automation.SelectionItemPattern]::Pattern }
    foreach ($pattern in $patterns) {
        try {
            $value = $element.GetCurrentPattern($pattern)
            if ($pattern -eq [Windows.Automation.InvokePattern]::Pattern) { ([Windows.Automation.InvokePattern]$value).Invoke() }
            else { ([Windows.Automation.SelectionItemPattern]$value).Select() }
            return $true
        } catch { Write-RetryDiagnostic $Monitor $Stage $Node.Name $_.Exception }
    }
    return $false
}

function Set-UiSearchValue($Node, [string] $Text, $Monitor) {
    try {
        $pattern = [Windows.Automation.ValuePattern]$Node.Element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $pattern.SetValue($Text)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            if ([string]$pattern.Current.Value -ceq $Text) { return }
            Start-Sleep -Milliseconds 50
        } while ($clock.ElapsedMilliseconds -lt 2000)
        throw 'Search input readback does not equal the requested value before timeout.'
    } catch { Write-RetryDiagnostic $Monitor 'search-value' $Node.Name $_.Exception; throw }
}

function Invoke-UiScrollForRetry($Snapshot, $Monitor) {
    # Retry controls are often below the fold in the conversation document. Use
    # UI Automation's scroll container so the scroll stays scoped to this page.
    $seeds = @($Snapshot | Where-Object {
        $_.Visible -and -not $_.Sidebar -and -not $_.SearchRegion -and
        $_.Type -in @('Document', 'Pane', 'Group', 'Custom', 'Edit', 'Text')
    } | Sort-Object @{ Expression = {
        switch ($_.Type) {
            'Document' { 0; break }
            'Pane' { 1; break }
            'Group' { 2; break }
            default { 3 }
        }
    }})

    foreach ($seed in $seeds) {
        $element = $seed.Element
        for ($depth = 0; $depth -lt 20 -and $element; $depth++) {
            try {
                $current = $element.Current
                if ($null -eq $current) { break }
                if ($current.ClassName -match 'sidebar-item|sidebar-row|folder-row|app-shell-left-panel') { break }
                $controlType = Get-RetryUiTypeName $current.ControlType
                if ($controlType -in @('Document', 'Pane', 'Group', 'Custom')) {
                    try {
                        $scroll = [Windows.Automation.ScrollPattern]$element.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
                        $vertical = [double]$scroll.Current.VerticalScrollPercent
                        if ($vertical -ge 100) {
                            $element = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
                            continue
                        }
                        if ($vertical -ge 0) {
                            $horizontal = [double]$scroll.Current.HorizontalScrollPercent
                            if ($horizontal -lt 0) { $horizontal = 0 }
                            $scroll.SetScrollPercent($horizontal, [Math]::Min(100, $vertical + 80))
                        } else {
                            $scroll.Scroll([Windows.Automation.ScrollAmount]::NoAmount, [Windows.Automation.ScrollAmount]::LargeIncrement)
                        }
                        return $true
                    } catch {
                        # This ancestor is not the scroll owner; keep walking.
                    }
                }
                $element = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
            } catch {
                Write-RetryDiagnostic $Monitor 'retry-scroll' $seed.Name $_.Exception
                break
            }
        }
    }
    return $false
}

function Ensure-RetryNativeMouse {
    if ('RetryNativeMouse' -as [type]) { return }
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RetryNativeMouse {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point p);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static bool Click(IntPtr window, int x, int y) {
        IntPtr desktop = OpenInputDesktop(0, false, 0x100);
        if (desktop == IntPtr.Zero) return false;
        try { if (!SwitchDesktop(desktop)) return false; } finally { CloseDesktop(desktop); }
        Point point = new Point { X=x, Y=y };
        if (GetForegroundWindow()!=window || GetAncestor(WindowFromPoint(point),2)!=window) return false;
        if (!SetCursorPos(x,y)) return false;
        Point actual;
        if (!GetCursorPos(out actual) || actual.X!=x || actual.Y!=y || GetForegroundWindow()!=window) return false;
        mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero);
        return true;
    }
}
"@
}

function Get-DesktopRetryCandidates($Content) {
    $candidates = @($Content | Where-Object {
        $_.Type -eq 'Button' -and $_.Name -match '(?i)^(Retry|Try again|重试|再次尝试)(\s|$|[：:])|\d+\s*(秒|s).*(重试|retry)|(重试|retry).*\d+\s*(秒|s)'
    })
    if ($candidates.Count -gt 0) { return $candidates }
    # Current Codex Desktop renders a capacity failure as a reconnect overlay
    # while it exhausts its own attempts. The overlay has no InvokePattern, but
    # it is the only visible action inside a content area that contains the
    # capacity message, so the native foreground fallback can click it safely.
    $capacity = @($Content | Where-Object { $_.Type -in @('Text', 'Group') -and (Test-CapacityText $_.Name) })
    $reconnect = @($Content | Where-Object {
        $_.Type -eq 'Button' -and $_.Name -match '(?i)^(正在重新连接|reconnecting)\s*\d+\s*/\s*\d+$'
    })
    if ($capacity.Count -gt 0 -and $reconnect.Count -eq 1) { return $reconnect }
    return @()
}

function Invoke-VerifiedRetryControl($Snapshot, $Window, $Monitor) {
    $content = @($Snapshot | Where-Object { $_.Visible -and $_.Enabled -and -not $_.Sidebar -and -not $_.SearchRegion })
    $candidates = @(Get-DesktopRetryCandidates $content)
    if ($candidates.Count -eq 0) {
        # Some versions expose only the composer primary button for capacity retry.
        # An empty editor and visible capacity error are both required.
        $capacity = @($content | Where-Object { $_.Type -in @('Text', 'Group') -and (Test-CapacityText $_.Name) })
        $primary = @($content | Where-Object { $_.Type -eq 'Button' -and $_.Class -match 'bg-composer-primary' })
        $editors = @($content | Where-Object { $_.Type -eq 'Edit' -and $_.Class -match 'composer|ProseMirror' })
        if ($capacity.Count -gt 0 -and $primary.Count -eq 1 -and $editors.Count -eq 1) {
            try {
                $value = [Windows.Automation.ValuePattern]$editors[0].Element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                if (-not $value.Current.Value.Trim()) { $candidates = $primary }
            } catch { Write-RetryDiagnostic $Monitor 'composer-value' $editors[0].Name $_.Exception }
        }
    }
    if ($candidates.Count -gt 1) { throw 'Multiple retry controls are visible; cannot choose the failed turn safely.' }
    if ($candidates.Count -eq 0) {
        # The control may be below the current viewport. Scroll one page and let
        # the next monitor tick take a fresh snapshot before attempting a click.
        [void](Invoke-UiScrollForRetry $content $Monitor)
        return $false
    }
    $node = $candidates[0]
    if (Invoke-UiNode $node $Monitor 'retry-actuator') { return $true }
    if ($Monitor.Options.AllowNativeClick) {
        Ensure-RetryNativeMouse
        $rect = $node.Element.Current.BoundingRectangle
        if ($rect.Width -gt 2 -and $rect.Height -gt 2 -and
            [RetryNativeMouse]::Click($Window.Handle, [int]($rect.X + $rect.Width/2), [int]($rect.Y + $rect.Height/2))) { return $true }
        Write-RetryDiagnostic $Monitor 'native-click' $node.Name $null 'Native click refused: desktop, foreground window or hit target was not valid.'
    }
    return $false
}

function Step-DesktopRetry($Adapter, $Request, [datetime] $Now) {
    $monitor = $Adapter.Monitor
    $hint = $Request.Hint
    if ($Request.Stage -eq 'resolve') {
        $windows = @(Get-DesktopWindows $monitor)
        if ($windows.Count -eq 0) {
            # The desktop process can briefly lose its top-level HWND while an
            # error view is being rendered or the app is restoring its window.
            # Keep the UI lease alive and poll until the configured UI deadline
            # instead of recording a false retry failure on the first miss.
            if ($Request.UiDeadline -eq [datetime]::MinValue -or $Now -lt $Request.UiDeadline) {
                $Request.ReadyAt = $Now.AddMilliseconds(500)
                return 'Pending'
            }
            throw 'No visible ChatGPT/Codex window found.'
        }
        $activeWindows = @()
        $singleWindowSnapshot = $null
        foreach ($window in $windows) {
            $snapshot = @(Read-DesktopSnapshot $window $monitor)
            if ($windows.Count -eq 1) { $singleWindowSnapshot = $snapshot }
            if (Test-ActiveSession $snapshot $hint $monitor) { $activeWindows += $window }
        }
        if ($activeWindows.Count -gt 1) { throw 'Target session is active in multiple desktop windows.' }
        if ($activeWindows.Count -eq 1) {
            $Request.Window = $activeWindows[0]
            $Request.Stage = 'verify'; return 'Pending'
        }
        if ($windows.Count -ne 1) { throw 'Cannot choose a desktop window for session search.' }
        $Request.Window = $windows[0]
        $snapshot = $singleWindowSnapshot
        # A previous navigation attempt may have left the command menu open.
        # Reuse that dialog instead of looking for a search button hidden behind
        # the overlay; otherwise the request retries forever at resolve.
        $openSearch = @($snapshot | Where-Object {
            $_.Visible -and $_.Type -eq 'Window' -and [string]$_.Name -match '(?i)search|搜索|命令菜单'
        })
        if ($openSearch.Count -eq 1) {
            $Request.Stage = 'search-input'; $Request.ReadyAt = $Now.AddMilliseconds(100); return 'Pending'
        }
        if ($openSearch.Count -gt 1) { throw 'Multiple session search dialogs are visible.' }
        $search = @($snapshot | Where-Object { $_.Visible -and $_.Enabled -and $_.Type -eq 'Button' -and $_.Name -match '^(Search|搜索)$' })
        if ($search.Count -ne 1 -or -not (Invoke-UiNode $search[0] $monitor 'search-open')) { throw 'Cannot open an unambiguous session search.' }
        $Request.Stage = 'search-input'; $Request.ReadyAt = $Now.AddMilliseconds(300); return 'Pending'
    }
    $snapshot = @(Read-DesktopSnapshot $Request.Window $monitor)
    switch ($Request.Stage) {
        'search-input' {
            $edits = @($snapshot | Where-Object {
                $_.Visible -and $_.Enabled -and $_.Type -in @('Edit', 'ComboBox') -and
                ($_.SearchRegion -or $_.Name -match '(?i)search|搜索|命令菜单')
            })
            if ($edits.Count -eq 0) {
                if ($Request.UiDeadline -eq [datetime]::MinValue -or $Now -lt $Request.UiDeadline) {
                    $Request.ReadyAt = $Now.AddMilliseconds(300)
                    return 'Pending'
                }
                throw 'Search edit is missing or ambiguous.'
            }
            if ($edits.Count -gt 1) { throw 'Search edit is missing or ambiguous.' }
            $text = if ($hint.Title) { $hint.Title } else { $hint.SessionId }
            Set-UiSearchValue $edits[0] $text $monitor
            $Request.SearchText = $text; $Request.Stage = 'search-results'; $Request.ReadyAt = $Now.AddMilliseconds(600)
            return 'Pending'
        }
        'search-results' {
            $target = Find-SessionTarget $snapshot $hint $monitor $true
            if (-not $target) { $Request.ReadyAt = $Now.AddMilliseconds(500); return 'Pending' }
            if (-not (Invoke-UiNode $target $monitor 'search-result' $true)) { throw 'Cannot activate verified search result.' }
            $Request.Stage = 'verify'; $Request.ReadyAt = $Now.AddMilliseconds(500); return 'Pending'
        }
        'verify' {
            # InvokePattern can succeed on a stale search result without
            # dismissing the command menu. Rebind to the live result while the
            # same request still owns the UI lease instead of waiting forever
            # for a page change that cannot happen behind the overlay.
            if (Test-UiSearchOpen $snapshot) {
                $Request.Stage = 'search-input'; $Request.ReadyAt = $Now.AddMilliseconds(100); return 'Pending'
            }
            if (-not (Test-ActiveSession $snapshot $hint $monitor)) { $Request.ReadyAt = $Now.AddMilliseconds(500); return 'Pending' }
            $Request.Stage = 'actuate'; return 'Pending'
        }
        'actuate' {
            if (-not (Test-ActiveSession $snapshot $hint $monitor)) { throw 'Active page changed before retry actuation.' }
            $cursor = $monitor.Files[$hint.SourcePath]
            if ($cursor.ActiveTurns.Count -gt 0) { return 'Cancelled' }
            if (Invoke-VerifiedRetryControl $snapshot $Request.Window $monitor) { return 'Clicked' }
            $Request.ReadyAt = $Now.AddMilliseconds(500); return 'Pending'
        }
        default { throw "Unknown UI retry stage: $($Request.Stage)" }
    }
}

function Invoke-DesktopRetryStepIsolated($Monitor, $Request, [datetime] $Now) {
    # UIA calls are COM calls into the Electron accessibility provider. A
    # provider deadlock cannot be interrupted from the calling runspace, so
    # execute one UI step in a child PowerShell process and impose a hard
    # wall-clock limit around it. The parent monitor remains able to observe
    # rollout files and schedule another session when the child is stopped.
    $repo = Split-Path -Parent $PSScriptRoot
    $maxSnapshot = 5000
    if ($Monitor.Options.ContainsKey('UiSnapshotMaxMilliseconds')) {
        $maxSnapshot = [int]$Monitor.Options.UiSnapshotMaxMilliseconds
    }
    $timeoutMilliseconds = [Math]::Max(10000, $maxSnapshot + 10000)
    $windowHandle = [int64]0
    $windowProcessId = 0
    if ($Request.Window) {
        $windowHandle = ([IntPtr]$Request.Window.Handle).ToInt64()
        $windowProcessId = [int]$Request.Window.ProcessId
    }
    $activeTurns = @()
    if ($Monitor.Files.ContainsKey($Request.Hint.SourcePath)) {
        $activeTurns = @($Monitor.Files[$Request.Hint.SourcePath].ActiveTurns.Keys)
    }
    $titleRows = @($Monitor.Titles.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Id = [string]$_.Key; Title = [string]$_.Value }
    })
    $payload = [ordered]@{
        Now = $Now.ToString('o')
        Hint = [ordered]@{
            SessionId = [string]$Request.Hint.SessionId; IsSubagent = [bool](Get-RetryField $Request.Hint 'IsSubagent' $false)
            TurnId = [string]$Request.Hint.TurnId; Title = [string]$Request.Hint.Title
            SourcePath = [string]$Request.Hint.SourcePath
        }
        Stage = [string]$Request.Stage; ReadyAt = $Request.ReadyAt.ToString('o'); UiDeadline = $Request.UiDeadline.ToString('o')
        SearchText = [string]$Request.SearchText; WindowHandle = $windowHandle; WindowProcessId = $windowProcessId
        ActiveTurns = $activeTurns; Titles = $titleRows
    }
    $optionsJson = $Monitor.Options | ConvertTo-Json -Compress -Depth 8
    $payloadJson = $payload | ConvertTo-Json -Compress -Depth 8
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($WorkerRepo, $OptionsJson, $PayloadJson)
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'
            . (Join-Path $WorkerRepo 'retry\Retry.Logs.ps1')
            . (Join-Path $WorkerRepo 'retry\Retry.State.ps1')
            . (Join-Path $WorkerRepo 'retry\Retry.Ui.ps1')
            $rawOptions = $OptionsJson | ConvertFrom-Json
            $options = @{}
            foreach ($property in $rawOptions.PSObject.Properties) { $options[$property.Name] = $property.Value }
            $payload = $PayloadJson | ConvertFrom-Json
            $hint = [pscustomobject]@{
                SessionId = [string]$payload.Hint.SessionId; IsSubagent = [bool]$payload.Hint.IsSubagent
                TurnId = [string]$payload.Hint.TurnId; Title = [string]$payload.Hint.Title
                SourcePath = [string]$payload.Hint.SourcePath
            }
            $request = [pscustomobject]@{
                Hint = $hint; Stage = [string]$payload.Stage; ReadyAt = [datetime]$payload.ReadyAt
                UiDeadline = [datetime]$payload.UiDeadline; ConfirmDeadline = [datetime]::MinValue
                Boundary = [int64]::MaxValue; LinkedTurns = @{}; Window = $null; Target = $null
                SearchText = [string]$payload.SearchText; Started = $false; CandidateTurnId = ''
                CandidateContext = $false; CandidateOutput = $false; Superseded = $false; AttemptCounted = $true
            }
            if ([int64]$payload.WindowHandle -ne 0) {
                $request.Window = [pscustomobject]@{ Handle = [IntPtr]::new([int64]$payload.WindowHandle); ProcessId = [int]$payload.WindowProcessId }
            }
            $titles = @{}
            foreach ($row in @($payload.Titles)) { if ($row.Id) { $titles[[string]$row.Id] = [string]$row.Title } }
            $cursor = [pscustomobject]@{ ActiveTurns = @{} }
            foreach ($turn in @($payload.ActiveTurns)) { if ($turn) { $cursor.ActiveTurns[[string]$turn] = $true } }
            $monitor = [pscustomobject]@{
                Options = $options; Titles = $titles; Files = @{ $hint.SourcePath = $cursor }
                UiLines = [Collections.Generic.List[string]]::new()
                StateMutex = [Threading.Mutex]::new($false, 'Local\CodexDesktopRetryState')
            }
            try {
                $adapter = [pscustomobject]@{ Monitor = $monitor }
                $result = Step-DesktopRetry $adapter $request ([datetime]$payload.Now)
                [pscustomobject]@{
                    Result = [string]$result; Stage = [string]$request.Stage; SearchText = [string]$request.SearchText
                    ReadyAt = $request.ReadyAt.ToString('o'); WindowHandle = if ($request.Window) { ([IntPtr]$request.Window.Handle).ToInt64() } else { [int64]0 }
                    WindowProcessId = if ($request.Window) { [int]$request.Window.ProcessId } else { 0 }
                }
            } finally { $monitor.StateMutex.Dispose() }
        } -ArgumentList $repo, $optionsJson, $payloadJson
        $waitSeconds = [int][Math]::Ceiling($timeoutMilliseconds / 1000.0)
        if (-not (Wait-Job -Job $job -Timeout $waitSeconds)) {
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw "Isolated UI step exceeded ${timeoutMilliseconds}ms."
        }
        $rows = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($rows.Count -ne 1) { throw 'Isolated UI step returned no result.' }
        $result = $rows[0]
        $Request.Stage = [string]$result.Stage
        $Request.SearchText = [string]$result.SearchText
        $Request.ReadyAt = [datetime]$result.ReadyAt
        if ([int64]$result.WindowHandle -ne 0) {
            $Request.Window = [pscustomobject]@{ Handle = [IntPtr]::new([int64]$result.WindowHandle); ProcessId = [int]$result.WindowProcessId }
        }
        return [string]$result.Result
    } finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

function New-DesktopRetryAdapter($Monitor) {
    $adapter = [pscustomobject]@{ Monitor = $Monitor }
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name Step -Value {
        param($Request, [datetime] $Now)
        Invoke-DesktopRetryStepIsolated $this.Monitor $Request $Now
    }
    return $adapter
}

# One tick reads every cached rollout and advances independent session requests.
function Test-CapacityText([string] $Text) {
    $Text -match 'Selected model is at capacity|model[_ -]capacity[_ -]exceeded|server[_ -]?(?:is[_ -]?)?overloaded|currently overloaded|overloaded_error'
}

function Get-RetryFailure($Event) {
    $errorValue = Get-RetryField $Event.Data 'error' $null
    if ($errorValue) {
        if ($errorValue -is [string]) { return $errorValue }
        return "$([string](Get-RetryField $errorValue 'message')) $([string](Get-RetryField $errorValue 'codex_error_info')) $([string](Get-RetryField $errorValue 'code'))"
    }
    if ($Event.Kind -in @('error', 'response.failed', 'task_failed', 'turn_failed')) {
        return "$([string](Get-RetryField $Event.Data 'message')) $([string](Get-RetryField $Event.Data 'code')) $([string](Get-RetryField $Event.Data 'codex_error_info'))"
    }
    return ''
}

function New-RetryRequest($Hint, [datetime] $Now) {
    [pscustomobject]@{
        Hint = $Hint; Stage = 'resolve'; ReadyAt = $Now; UiDeadline = [datetime]::MinValue
        ConfirmDeadline = [datetime]::MinValue; Boundary = [int64]::MaxValue
        LinkedTurns = @{}; Window = $null; Target = $null; SearchText = ''; Started = $false
        CandidateTurnId = ''; CandidateContext = $false; CandidateOutput = $false
        Superseded = $false; AttemptCounted = $false
    }
}

function Add-CapacityRequest($Monitor, $Hint, [datetime] $Now) {
    if (Get-RetryField $Hint 'IsSubagent' $false) {
        # Subagent rollouts are represented by hidden child threads. Their
        # capacity failures must not make the visible parent conversation look
        # retryable or take ownership of its UI.
        Write-RetryState $Monitor 'capacity-subagent-ignored' $Hint.SourcePath ([string]$Hint.SessionId) @{ turn = $Hint.TurnId }
        return
    }
    $key = Get-RetrySessionKey $Hint
    $state = Get-RetrySessionState $Monitor $key
    if (-not $Hint.SessionId -or -not $Hint.TurnId) {
        Write-RetryState $Monitor 'capacity-unattributed' $Hint.SourcePath $key @{ turn = $Hint.TurnId }
        return
    }
    if ($state.Active -and $state.Active.Hint.SourcePath -eq $Hint.SourcePath -and $state.Active.Hint.TurnId -eq $Hint.TurnId) {
        # An error after the click disproves this attempt; do not discard the error during cooldown.
        if ($state.Phase -eq 'confirming' -and $Hint.ErrorOffset -gt $state.Active.Boundary) {
            Write-RetryState $Monitor 'retry-capacity-again' $Hint.SourcePath $key @{ turn = $Hint.TurnId }
            $state.Active.Hint = $Hint; $state.Active.Stage = 'resolve'; $state.Active.AttemptCounted = $false
            $state.Phase = 'waiting'; $state.NextEligible = $Now.AddSeconds($Monitor.Options.CooldownSeconds)
        }
        return
    }
    foreach ($queued in $state.Queue) {
        if ($queued.Hint.SourcePath -eq $Hint.SourcePath -and $queued.Hint.TurnId -eq $Hint.TurnId) { $queued.Hint = $Hint; return }
    }
    $state.Queue.Add((New-RetryRequest $Hint $Now))
    Write-RetryState $Monitor 'capacity-detected' $Hint.SourcePath $key @{ turn = $Hint.TurnId; offset = $Hint.ErrorOffset }
}

function Update-RetryConfirmation($Monitor, $Record, [datetime] $Now) {
    $event = $Record.Event
    foreach ($key in @($Monitor.Sessions.Keys)) {
        $state = $Monitor.Sessions[$key]
        $request = $state.Active
        if (-not $request -or $Record.Path -ne $request.Hint.SourcePath) { continue }
        $confirming = $state.Phase -eq 'confirming'
        $manualPending = $state.Phase -in @('waiting', 'navigating')
        if (-not ($confirming -or $manualPending)) { continue }
        $baseline = if ($confirming) { $request.Boundary } else { $request.Hint.ErrorOffset }
        if ($Record.EndOffset -le $baseline) { continue }
        $same = $event.TurnId -and ($event.TurnId -eq $request.Hint.TurnId -or $request.LinkedTurns.ContainsKey($event.TurnId))
        $linkedNewTurn = $false
        if ($confirming -and
            $event.TurnId -and ($event.ParentTurnId -eq $request.Hint.TurnId -or $event.RootTurnId -eq $request.Hint.TurnId)) {
            $request.LinkedTurns[$event.TurnId] = $true; $same = $true
        }
        if (($confirming -or $manualPending) -and
            $event.TurnId -and -not $same -and $event.Kind -in @('task_started', 'turn_started', 'turn_context')) {
            if (-not $request.CandidateTurnId) {
                $request.CandidateTurnId = $event.TurnId
                $request.LinkedTurns[$event.TurnId] = $true
                Write-RetryState $Monitor 'retry-candidate' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; observedTurn = $event.TurnId; association = if ($confirming) { 'post-click-new-turn' } else { 'post-capacity-manual-turn' } }
            }
            if ($event.TurnId -eq $request.CandidateTurnId) {
                $same = $true
                $linkedNewTurn = $true
                if ($event.Kind -eq 'turn_context') { $request.CandidateContext = $true }
            }
            # A different concurrent turn is deliberately ignored until the candidate
            # produces its own context and output/completion.
        }
        if ($event.Kind -in @('task_started', 'turn_started') -and $event.TurnId -and -not $same) {
            if ($confirming) {
                # A second unlinked turn is unrelated until it matches the candidate.
                continue
            }
            # A completed post-error turn is evidence that the user manually
            # recovered the conversation. Candidate tracking below requires
            # context plus output/completion before it closes the request.
        }
        if (-not $same) { continue }
        if (Get-RetryFailure $event) { continue }
        if ($event.Kind -eq 'turn_context' -and $event.TurnId -eq $request.CandidateTurnId) { $request.CandidateContext = $true }
        if ($event.Kind -in @('task_started', 'turn_started', 'retry_started') -and -not $linkedNewTurn) {
            $request.Started = $true
            Write-RetryState $Monitor 'retry-started' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; observedTurn = $event.TurnId }
        }
        $complete = $event.Kind -in @('task_complete', 'turn_complete', 'response.completed')
        $output = $event.Kind -in @('agent_message', 'response.output_text.delta') -or
            ($event.Outer -eq 'response_item' -and $event.Kind -eq 'message' -and (Get-RetryField $event.Data 'role') -eq 'assistant')
        if ($request.CandidateTurnId -and $event.TurnId -eq $request.CandidateTurnId) {
            if ($output -or $complete) { $request.CandidateOutput = $true }
        }
        $candidateReady = $request.CandidateTurnId -and $event.TurnId -eq $request.CandidateTurnId -and
            $request.CandidateContext -and $request.CandidateOutput
        $matchingTurnReady = $event.TurnId -ne $request.CandidateTurnId -and ($complete -or $output)
        if ($candidateReady -or $matchingTurnReady) {
            if ($manualPending) {
                Write-RetryState $Monitor 'retry-manual-resolved' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; observedTurn = $event.TurnId; confirmedType = $event.Kind }
                $state.RetryCount = 0; $state.Active = $null; $state.Phase = 'observing'
                if ($Monitor.UiOwner -eq $key) { $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue }
                continue
            }
            $state.Phase = 'confirmed'
            Write-RetryState $Monitor 'retry-confirmed' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; observedTurn = $event.TurnId; confirmedType = $event.Kind; association = if ($request.CandidateTurnId) { 'post-click-new-turn' } else { 'matching-turn' } }
            $state.RetryCount = 0; $state.Active = $null
        }
    }
}

function Receive-RetryRecords($Monitor, [datetime] $Now) {
    foreach ($cursor in @($Monitor.Files.Values)) {
        foreach ($record in @(Read-RolloutRecords $Monitor $cursor)) {
            Update-RolloutContext $cursor $record.Event
            Update-RetryConfirmation $Monitor $record $Now
            $failure = Get-RetryFailure $record.Event
            if (-not (Test-CapacityText $failure)) { continue }
            Add-CapacityRequest $Monitor (Resolve-RetrySession $Monitor $cursor $record) $Now
        }
    }
}

function Invoke-RetryMonitorTick($Monitor, $Adapter, [datetime] $Now) {
    Update-RetryLogCache $Monitor $Now
    Receive-RetryRecords $Monitor $Now
    $leaseSeconds = if ($Monitor.Options.ContainsKey('UiLeaseSeconds')) { [int]$Monitor.Options.UiLeaseSeconds } else { 5 }
    if ($Monitor.UiOwner -and ($Now - $Monitor.UiLeaseStarted).TotalSeconds -ge $leaseSeconds) {
        $ownerKey = $Monitor.UiOwner
        # Do not interrupt a lone request. A full UI Automation snapshot can
        # take longer than the lease on a large Electron tree; yielding with no
        # competing session makes that request restart forever.
        $otherWork = @($Monitor.Sessions.Keys | Where-Object {
            $_ -ne $ownerKey -and $Monitor.Sessions[$_].Active -and
            $Monitor.Sessions[$_].Phase -eq 'waiting'
        }).Count -gt 0
        $ownerRequest = if ($Monitor.Sessions.ContainsKey($ownerKey)) { $Monitor.Sessions[$ownerKey].Active } else { $null }
        # Once a request has opened search, yielding the lease leaves its
        # dialog in the desktop while another request rewrites the same search
        # box. The original request then cannot click or verify its result.
        # Only yield before navigation has touched the UI; failures inside a
        # later stage release the lease through the normal deadline/error path.
        $canYield = $ownerRequest -and [string]$ownerRequest.Stage -eq 'resolve'
        if ($otherWork -and $canYield) {
            $ownerState = $Monitor.Sessions[$ownerKey]
            # Yield ownership without discarding UI progress. Re-resolving from
            # scratch on every 5-second lease caused search-input/results stages
            # to restart indefinitely, especially when Electron needed time to
            # render the result list. The next owner can continue with the
            # existing window and stage; the normal deadline still bounds it.
            $ownerState.Phase = 'waiting'; $ownerState.NextEligible = $Now
            Write-RetryState $Monitor 'ui-yield' $ownerState.Active.Hint.SourcePath $ownerKey @{ leaseSeconds = $leaseSeconds }
            $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
        }
    }
    foreach ($key in @($Monitor.Sessions.Keys)) {
        $state = $Monitor.Sessions[$key]
        if ($state.Active -and $state.Phase -eq 'confirming' -and $Now -ge $state.Active.ConfirmDeadline) {
            Write-RetryState $Monitor 'retry-unconfirmed' $state.Active.Hint.SourcePath $key @{ turn = $state.Active.Hint.TurnId }
            if ($state.Active.Superseded) { $state.Active = $null; $state.Phase = 'observing' }
            else {
                $state.Active.Stage = 'resolve'; $state.Active.AttemptCounted = $false
                $state.Phase = 'waiting'; $state.NextEligible = $Now.AddSeconds($Monitor.Options.CooldownSeconds)
            }
        }
        if (-not $state.Active -and $state.Queue.Count -gt 0) {
            $state.Active = $state.Queue[0]; $state.Queue.RemoveAt(0)
            $state.Phase = 'waiting'
        }
    }
    if (-not $Monitor.UiOwner) {
        $eligible = @($Monitor.Sessions.Keys | Where-Object {
            $s = $Monitor.Sessions[$_]
            $s.Active -and $s.Phase -eq 'waiting' -and $Now -ge $s.NextEligible
        } | Sort-Object { $Monitor.Sessions[$_].LastAttempt })
        foreach ($key in $eligible) {
            $state = $Monitor.Sessions[$key]; $request = $state.Active
            if (-not $request.AttemptCounted) {
                if ($Monitor.Options.MaxRetries -gt 0 -and $state.RetryCount -ge $Monitor.Options.MaxRetries) {
                    Write-RetryState $Monitor 'limit-reset' $request.Hint.SourcePath $key
                    $state.RetryCount = 0
                }
                $delay = $Monitor.Options.BackoffSeconds[[Math]::Min($state.RetryCount, $Monitor.Options.BackoffSeconds.Count - 1)]
                $state.RetryCount++; $request.AttemptCounted = $true; $request.ReadyAt = $Now.AddSeconds($delay)
            }
            if ($Now -lt $request.ReadyAt) { continue }
            $Monitor.UiOwner = $key; $Monitor.UiLeaseStarted = $Now; $state.Phase = 'navigating'; $state.LastAttempt = $Now
            if ($request.UiDeadline -eq [datetime]::MinValue) {
                $request.UiDeadline = $Now.AddSeconds($Monitor.Options.RetryUiWaitSeconds)
            }
            break
        }
    }
    if (-not $Monitor.UiOwner) { return }
    $key = $Monitor.UiOwner; $state = $Monitor.Sessions[$key]; $request = $state.Active
    try {
        if ($Now -ge $request.UiDeadline) { throw "UI retry timed out at stage $($request.Stage)." }
        if ($Now -lt $request.ReadyAt) { return }
        # Bound confirmation to bytes written after this UI action. Old buffered records cannot confirm it.
        $before = [IO.FileInfo]::new($request.Hint.SourcePath).Length
        $result = $Adapter.Step($request, $Now)
        if ($result -eq 'Clicked') {
            # A verified click is the outcome this tool owns. Do not turn a
            # later server-side capacity response into a false UI failure.
            # A subsequent capacity event will enqueue a separate request.
            Write-RetryState $Monitor 'retry-clicked' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; offset = $before }
            $state.RetryCount = 0; $state.Active = $null; $state.Phase = 'observing'
            $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
        } elseif ($result -eq 'Cancelled') {
            Write-RetryState $Monitor 'retry-superseded' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId }
            $state.Active = $null; $state.Phase = 'observing'; $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
        } elseif ($result -ne 'Pending') { throw "Unexpected retry adapter result: $result" }
    } catch {
        Write-RetryDiagnostic $Monitor $request.Stage $request.Hint.SourcePath $_.Exception
        Write-RetryState $Monitor 'retry-failed' $_.Exception.Message $key @{ turn = $request.Hint.TurnId; stage = $request.Stage }
        $state.Phase = 'waiting'; $state.NextEligible = $Now.AddSeconds([Math]::Max(1, $Monitor.Options.CooldownSeconds))
        $request.Stage = 'resolve'; $request.Window = $null; $request.AttemptCounted = $false
        $request.UiDeadline = [datetime]::MinValue
        $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
    }
}

$options = @{
    LogRoot = $LogRoot; ProcessName = $ProcessName; MaxRetries = $MaxRetries
    BackoffSeconds = $BackoffSeconds; CooldownSeconds = $CooldownSeconds
    RetryUiWaitSeconds = $RetryUiWaitSeconds; RetryConfirmSeconds = $RetryConfirmSeconds
    UiLeaseSeconds = $UiLeaseSeconds; UiSnapshotMaxMilliseconds = $UiSnapshotMaxMilliseconds
    RescanSeconds = $RescanSeconds
    StateMaxBytes = $StateMaxBytes; StateMaxFiles = $StateMaxFiles
    AllowNativeClick = $AllowNativeClick.IsPresent; StatePath = $StatePath
    UiDiagnosticPath = $UiDiagnosticPath; ControlPath = $ControlPath
}
$monitor = New-RetryMonitor $options
$adapter = New-DesktopRetryAdapter $monitor
$wasPaused = $false
$runtimeRegistered = $false
try {
    Write-RetryMonitorRuntime $RuntimePath ([ordered]@{
        pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o'); scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
        statePath = [IO.Path]::GetFullPath($StatePath); controlPath = [IO.Path]::GetFullPath($ControlPath)
        uiDiagnosticPath = [IO.Path]::GetFullPath($UiDiagnosticPath); logRoot = @($LogRoot); processName = @($ProcessName)
    })
    $runtimeRegistered = $true
    Write-Host 'Codex Desktop retry monitor started. Press Ctrl+C to stop.' -ForegroundColor Cyan
    Write-Host "Watching: $($LogRoot -join ', ')" -ForegroundColor DarkCyan
    Write-RetryState $monitor 'started'
    while ($true) {
        $paused = $false
        if ($ControlPath -and (Test-Path -LiteralPath $ControlPath -PathType Leaf)) {
            try {
                $control = Get-Content -LiteralPath $ControlPath -Raw | ConvertFrom-Json
                $paused = [bool]$control.paused
            } catch { $paused = $false }
        }
        if ($paused) {
            if (-not $wasPaused) { Write-RetryState $monitor 'paused' $ControlPath }
            $wasPaused = $true
        } else {
            if ($wasPaused) { Write-RetryState $monitor 'resumed' $ControlPath }
            $wasPaused = $false
            Invoke-RetryMonitorTick $monitor $adapter (Get-Date)
        }
        Start-Sleep -Milliseconds ([Math]::Max(50, [int]($PollSeconds * 1000)))
    }
} finally {
    if ($runtimeRegistered) { Remove-RetryMonitorRuntime $RuntimePath $PID }
    $monitor.StateMutex.Dispose(); $monitorMutex.ReleaseMutex(); $monitorMutex.Dispose()
}
