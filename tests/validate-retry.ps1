$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'retry\Retry.Logs.ps1')
. (Join-Path $repo 'retry\Retry.State.ps1')
. (Join-Path $repo 'retry\Retry.Monitor.ps1')
. (Join-Path $repo 'retry\Retry.Ui.ps1')

function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-retry-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $rollout = Join-Path $temp 'rollout-session-a.jsonl'
    $state = Join-Path $temp 'state.jsonl'
    $diag = Join-Path $temp 'diag.log'
    $index = Join-Path $temp 'session_index.jsonl'
    $options = @{
        LogRoot = @($temp); ProcessName = @('ChatGPT'); MaxRetries = 2; BackoffSeconds = @(0)
        CooldownSeconds = 20; RetryUiWaitSeconds = 1; RetryConfirmSeconds = 10
        UiLeaseSeconds = 1; RescanSeconds = 60
        StateMaxBytes = 4096; StateMaxFiles = 2; AllowNativeClick = $false
        StatePath = $state; UiDiagnosticPath = $diag
    }
    $monitor = New-RetryMonitor $options
    $meta = '{"type":"session_meta","payload":{"session_id":"session-a","id":"session-a"}}'
    [IO.File]::WriteAllText($rollout, $meta + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($index, '{"id":"session-a","thread_name":"审查 T01 Selected model is at capacity"}' + "`n", [Text.UTF8Encoding]::new($false))
    Update-RetryLogCache $monitor (Get-Date) -Force
    Assert ($monitor.Files.Count -eq 1) 'Expected one cached rollout.'
    Assert (-not (Test-RetryRolloutPath $monitor $index)) 'Session index must not be treated as a retryable rollout.'
    $newRollout = Join-Path $temp 'rollout-session-b.jsonl'
    [IO.File]::WriteAllText($newRollout, $meta.Replace('session-a', 'session-b') + "`n", [Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 300
    Update-RetryLogCache $monitor (Get-Date)
    Assert ($monitor.Files.Count -eq 2) 'FileSystemWatcher did not enqueue a newly created rollout.'
    Add-Content -LiteralPath $rollout -Value '{"type":"event_msg","payload":{"type":"error","turn_id":"turn-a","message":"server_is_overloaded"}}' -Encoding UTF8
    $records = @(Read-RolloutRecords $monitor $monitor.Files[$rollout])
    Assert ($records.Count -eq 1) 'Expected one incremental rollout record.'
    $hint = Resolve-RetrySession $monitor $monitor.Files[$rollout] $records[0]
    Assert ($hint.SessionId -eq 'session-a') 'Session id was not resolved.'
    Assert ($hint.TurnId -eq 'turn-a') 'Turn id was not resolved.'
    $childMeta = '{"type":"session_meta","payload":{"session_id":"parent-session","id":"child-session","forked_from_id":"parent-session","thread_source":"subagent"}}' | ConvertFrom-Json
    $childEvent = Get-RetryEvent $childMeta
    Assert ($childEvent.SessionId -eq 'child-session' -and $childEvent.IsSubagent) 'Forked rollout was attributed to its parent session.'
    Add-CapacityRequest $monitor ([pscustomobject]@{ SessionId = 'child-session'; IsSubagent = $true; TurnId = 'child-turn'; SourcePath = $rollout; ErrorOffset = 1; Title = 'Target' }) (Get-Date)
    Assert (-not $monitor.Sessions.ContainsKey('child-session')) 'Subagent capacity error created a visible retry request.'
    Assert ((Test-CapacityText $records[0].Raw)) 'Capacity event was not classified.'
    $key = Get-RetrySessionKey $hint
    $stateObject = Get-RetrySessionState $monitor $key
    $stateObject.RetryCount = 1
    Write-RetryState $monitor 'capacity-detected' 'test' $key
    Assert (Test-Path -LiteralPath $state) 'State record was not written.'
    $request = New-RetryRequest $hint (Get-Date)
    $request.Boundary = 0
    $stateObject.Active = $request
    $stateObject.Phase = 'confirming'
    $successJson = '{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}' | ConvertFrom-Json
    $successRecord = [pscustomobject]@{ Path = $rollout; EndOffset = 1; Raw = $successJson | ConvertTo-Json -Compress; Event = (Get-RetryEvent $successJson) }
    Update-RetryConfirmation $monitor $successRecord (Get-Date)
    Assert ($stateObject.Phase -eq 'confirming') 'A start event alone must not confirm recovery.'
    $completeJson = '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}' | ConvertFrom-Json
    Update-RetryConfirmation $monitor ([pscustomobject]@{ Path = $rollout; EndOffset = 2; Raw = $completeJson | ConvertTo-Json -Compress; Event = (Get-RetryEvent $completeJson) }) (Get-Date)
    Assert ($stateObject.Phase -eq 'confirmed') 'Matching turn completion did not confirm retry.'
    40..1 | ForEach-Object { Write-RetryState $monitor 'test' $_.ToString() $key }
    Assert (Test-Path -LiteralPath "$state.1") 'State rotation did not create a rotated file.'
    Assert (-not (Test-Path -LiteralPath "$state.3")) 'State rotation exceeded the configured backup count.'
    $uiNode = [pscustomobject]@{ Name = 'A long conversation title with a truncated suffix'; Id = ''; }
    $uiHint = [pscustomobject]@{ SessionId = ''; Title = 'A long conversation title with a truncated suffix and more text' }
    Assert (Test-UiSessionMatch $uiNode $uiHint $monitor) 'Long UI title prefix was not matched.'
    $duplicateA = [pscustomobject]@{ Element = $null; Name = 'Target'; Id = ''; Class = 'row'; Type = 'Button'; Enabled = $true; Visible = $true; Sidebar = $true; SearchRegion = $false }
    $duplicateB = [pscustomobject]@{ Element = $null; Name = 'Target'; Id = ''; Class = 'row'; Type = 'Button'; Enabled = $true; Visible = $true; Sidebar = $true; SearchRegion = $false }
    $childUiHint = [pscustomobject]@{ SessionId = 'child-session'; IsSubagent = $true; Title = 'Target' }
    Assert (-not (Test-UiSessionMatch $duplicateA $childUiHint $monitor)) 'Forked session incorrectly fell back to the parent title.'
    $duplicateHint = [pscustomobject]@{ SessionId = ''; Title = 'Target' }
    Assert ((Find-SessionTarget @($duplicateA, $duplicateB) $duplicateHint $monitor).Name -eq 'Target') 'Equivalent UI aliases were treated as ambiguous.'
    $searchResult = [pscustomobject]@{ Element = $null; Name = 'Target'; Id = ''; Class = 'search-result'; Type = 'Button'; Enabled = $true; Visible = $true; Sidebar = $true; SearchRegion = $true }
    Assert ((Find-SessionTarget @($searchResult) $duplicateHint $monitor $true).Name -eq 'Target') 'Search-region result was not accepted when sidebar matching failed.'
    $uiText = Get-Content -Raw (Join-Path $repo 'retry\Retry.Ui.ps1')
    Assert ($uiText -notmatch '::LegacyIAccessiblePattern') 'Unsupported LegacyIAccessiblePattern type reference remains.'
    Assert ($uiText -match 'ScrollPattern') 'Retry UI does not expose scroll-container handling.'
    Assert ($uiText -match 'Invoke-UiScrollForRetry') 'Retry UI does not scroll when the control is below the viewport.'
    $adapter = [pscustomobject]@{}
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name Step -Value { param($Request, [datetime] $Now) 'Clicked' }
    $monitor2 = New-RetryMonitor $options
    Update-RetryLogCache $monitor2 (Get-Date) -Force
    Add-Content -LiteralPath $rollout -Value '{"type":"event_msg","payload":{"type":"error","turn_id":"turn-b","message":"server_is_overloaded"}}' -Encoding UTF8
    Invoke-RetryMonitorTick $monitor2 $adapter (Get-Date)
    $state2 = $monitor2.Sessions['session-a']
    Assert ($state2.Phase -eq 'observing' -and -not $state2.Active) 'A verified click did not complete the retry request.'
    $monitor3 = New-RetryMonitor $options
    Update-RetryLogCache $monitor3 (Get-Date) -Force
    Add-Content -LiteralPath $rollout -Value '{"type":"event_msg","payload":{"type":"error","turn_id":"turn-c","message":"server_is_overloaded"}}' -Encoding UTF8
    Invoke-RetryMonitorTick $monitor3 $adapter (Get-Date)
    $state3 = $monitor3.Sessions['session-a']
    Assert ($state3.Phase -eq 'observing' -and -not $state3.Active) 'A repeated capacity error did not produce an independent click attempt.'
    $leaseOptions = @{}; foreach ($entry in $options.GetEnumerator()) { $leaseOptions[$entry.Key] = $entry.Value }
    $leaseOptions.StatePath = Join-Path $temp 'lease-state.jsonl'
    $leaseOptions.UiLeaseSeconds = 1
    $monitor4 = New-RetryMonitor $leaseOptions
    $hintA = [pscustomobject]@{ SessionId = 'lease-a'; TurnId = 'lease-turn-a'; SourcePath = $rollout; ErrorOffset = 1; Title = 'Lease A' }
    $hintB = [pscustomobject]@{ SessionId = 'lease-b'; TurnId = 'lease-turn-b'; SourcePath = $newRollout; ErrorOffset = 1; Title = 'Lease B' }
    $stateA = Get-RetrySessionState $monitor4 'lease-a'; $stateB = Get-RetrySessionState $monitor4 'lease-b'
    $stateA.Active = New-RetryRequest $hintA (Get-Date); $stateA.Phase = 'waiting'; $stateA.NextEligible = [datetime]::MinValue
    $stateB.Active = New-RetryRequest $hintB (Get-Date); $stateB.Phase = 'waiting'; $stateB.NextEligible = [datetime]::MinValue
    $pendingAdapter = [pscustomobject]@{}
    Add-Member -InputObject $pendingAdapter -MemberType ScriptMethod -Name Step -Value { param($Request, [datetime] $Now) 'Pending' }
    $leaseStart = Get-Date
    Invoke-RetryMonitorTick $monitor4 $pendingAdapter $leaseStart
    $firstOwner = $monitor4.UiOwner
    $firstState = $monitor4.Sessions[$firstOwner]
    $firstCount = $firstState.RetryCount
    Invoke-RetryMonitorTick $monitor4 $pendingAdapter $leaseStart.AddSeconds(2)
    Assert ($monitor4.UiOwner -and $monitor4.UiOwner -ne $firstOwner) 'UI lease did not yield to another session.'
    Assert ($firstState.RetryCount -eq $firstCount) 'UI lease yield counted a duplicate retry attempt.'
    Dispose-RetryLogWatchers $monitor
    Dispose-RetryLogWatchers $monitor2
    Dispose-RetryLogWatchers $monitor3
    Dispose-RetryLogWatchers $monitor4
    Write-Output 'PASS validate-retry'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
