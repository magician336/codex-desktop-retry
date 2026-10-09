# Incremental state JSONL index used by the local console.
function New-RetryStatusIndex {
    return [pscustomobject]@{
        Files = @{}
        Events = @()
        EventsRevision = -1
        Stats = [ordered]@{ FullRebuilds = 0; IncrementalReads = 0; ParsedLines = 0; InvalidLines = 0; Revision = 0 }
    }
}

function Get-RetryStatusIndexStats($Index) {
    return [pscustomobject]@{
        FullRebuilds = [int]$Index.Stats.FullRebuilds
        IncrementalReads = [int]$Index.Stats.IncrementalReads
        ParsedLines = [int]$Index.Stats.ParsedLines
        InvalidLines = [int]$Index.Stats.InvalidLines
        Revision = [int]$Index.Stats.Revision
    }
}

function Reset-RetryStatusIndex($Index) {
    $Index.Files.Clear()
    $Index.Events = @()
    $Index.EventsRevision = -1
    foreach ($key in @($Index.Stats.Keys)) { $Index.Stats[$key] = 0 }
}

function New-RetryStatusFileShard([string]$Path) {
    return [pscustomobject]@{
        Path = $Path
        Position = [int64]0
        LastWriteUtc = [datetime]::MinValue
        CreationTimeUtc = [datetime]::MinValue
        Pending = [Collections.Generic.List[byte]]::new()
        Events = [Collections.Generic.List[object]]::new()
    }
}

function Reset-RetryStatusFileShard($Index, $Shard) {
    $Shard.Position = [int64]0
    $Shard.LastWriteUtc = [datetime]::MinValue
    $Shard.CreationTimeUtc = [datetime]::MinValue
    $Shard.Pending.Clear()
    $Shard.Events.Clear()
    $Index.Stats.FullRebuilds++
}

function Read-RetryStatusFileShard($Index, $Shard, $Info, [bool]$Rebuild) {
    if ($Rebuild) { Reset-RetryStatusFileShard $Index $Shard }
    $start = $Shard.Position
    $stream = $null
    try {
        $stream = [IO.File]::Open($Shard.Path, 'Open', 'Read', 'ReadWrite')
        if ($stream.Length -lt $Shard.Position) {
            Reset-RetryStatusFileShard $Index $Shard
            $start = [int64]0
        }
        $stream.Position = $Shard.Position
        $buffer = [byte[]]::new(65536)
        while ($true) {
            $count = $stream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) { break }
            for ($offset = 0; $offset -lt $count; $offset++) {
                $byte = $buffer[$offset]
                if ($byte -eq 10) {
                    if ($Shard.Pending.Count -gt 0) {
                        $line = [Text.Encoding]::UTF8.GetString($Shard.Pending.ToArray()).TrimEnd("`r")
                        $Shard.Pending.Clear()
                        if ($line) {
                            $Index.Stats.ParsedLines++
                            try { $Shard.Events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { $Index.Stats.InvalidLines++ }
                        }
                    }
                } else { $Shard.Pending.Add($byte) }
            }
            $Shard.Position = $stream.Position
        }
        $Shard.Position = $stream.Position
    } finally { if ($stream) { $stream.Dispose() } }
    $Shard.LastWriteUtc = $Info.LastWriteTimeUtc
    $Shard.CreationTimeUtc = $Info.CreationTimeUtc
    $Index.Stats.Revision++
    if (-not $Rebuild -and $Shard.Position -gt $start) { $Index.Stats.IncrementalReads++ }
}

function Update-RetryStatusIndex($Index, [string[]]$Paths) {
    $present = @{}
    foreach ($path in $Paths) {
        $full = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $present[$full] = $true
        try { $info = Get-Item -LiteralPath $full -ErrorAction Stop } catch { continue }
        $shard = $Index.Files[$full]
        $rebuild = $false
        if (-not $shard) {
            $shard = New-RetryStatusFileShard $full
            $Index.Files[$full] = $shard
            $rebuild = $true
        } elseif ($info.Length -lt $shard.Position -or
            $info.LastWriteTimeUtc -lt $shard.LastWriteUtc -or
            $info.CreationTimeUtc -ne $shard.CreationTimeUtc -or
            ($info.Length -eq $shard.Position -and $info.LastWriteTimeUtc -ne $shard.LastWriteUtc)) {
            $rebuild = $true
        }
        if ($rebuild -or $info.Length -gt $shard.Position) {
            Read-RetryStatusFileShard $Index $shard $info $rebuild
        }
    }
    foreach ($path in @($Index.Files.Keys)) {
        if (-not $present.ContainsKey($path)) {
            $Index.Files.Remove($path)
            $Index.Stats.Revision++
        }
    }
}

function Get-RetryStatusEvents($Index, [string[]]$Paths) {
    Update-RetryStatusIndex $Index $Paths
    if ($Index.EventsRevision -eq $Index.Stats.Revision) { return @($Index.Events) }
    $events = [Collections.Generic.List[object]]::new()
    foreach ($shard in $Index.Files.Values) {
        foreach ($event in $shard.Events) { $events.Add($event) }
    }
    $Index.Events = @($events | Sort-Object timestamp)
    $Index.EventsRevision = $Index.Stats.Revision
    return @($Index.Events)
}
