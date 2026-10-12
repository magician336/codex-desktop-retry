$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'retry/Retry.State.ps1')
. (Join-Path $repo 'retry/Retry.Monitor.ps1')
# Isolate scheduling from filesystem discovery and desktop side effects.
function Update-RetryLogCache($Monitor, $Now) {}
function Receive-RetryRecords($Monitor, $Now) {}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('retry-lease-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $temp)
$options = @{ UiLeaseSeconds=5; RetryUiWaitSeconds=90; MaxRetries=0; BackoffSeconds=@(0); CooldownSeconds=20; StatePath=(Join-Path $temp 'state.jsonl'); UiDiagnosticPath=(Join-Path $temp 'diag.jsonl'); StateMaxBytes=1048576; StateMaxFiles=2 }
$m = New-RetryMonitor $options
$path = Join-Path $temp 'rollout.jsonl'
[IO.File]::WriteAllText($path, '')
$hint = [pscustomobject]@{ SessionId='session'; SourcePath=$path; TurnId='turn'; ErrorOffset=0 }
$s = Get-RetrySessionState $m 'session'
$s.Active = New-RetryRequest $hint ([datetime]'2026-10-10T22:41:00')
$s.Phase = 'waiting'
$adapter = [pscustomobject]@{ Calls=0 }
Add-Member -InputObject $adapter -MemberType ScriptMethod -Name Step -Value { param($Request,$Now) $this.Calls++; return 'Pending' }
try {
    $start = [datetime]'2026-10-10T22:41:00'
    foreach ($seconds in @(0,6,91,120)) { Invoke-RetryMonitorTick $m $adapter $start.AddSeconds($seconds) }
    $events = @(Get-Content $options.StatePath -ErrorAction SilentlyContinue | ConvertFrom-Json)
    Write-Output "calls=$($adapter.Calls) phase=$($s.Phase) owner='$($m.UiOwner)' failed=$(@($events | Where-Object event -eq 'retry-failed').Count)"
    if (@($events | Where-Object event -eq 'retry-failed').Count -eq 0) { throw 'BUG: pending navigation neither completes nor reaches the 90-second timeout.' }
    Write-Output 'PASS: pending navigation reaches its deadline.'
} finally { $m.StateMutex.Dispose(); Remove-Item -LiteralPath $temp -Recurse -Force }
