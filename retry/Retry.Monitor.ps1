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
        $same = $event.TurnId -and ($event.TurnId -eq $request.Hint.TurnId -or $request.LinkedTurns.ContainsKey($event.TurnId))
        $linkedNewTurn = $false
        if ($state.Phase -eq 'confirming' -and $Record.EndOffset -gt $request.Boundary -and
            $event.TurnId -and ($event.ParentTurnId -eq $request.Hint.TurnId -or $event.RootTurnId -eq $request.Hint.TurnId)) {
            $request.LinkedTurns[$event.TurnId] = $true; $same = $true
        }
        if ($state.Phase -eq 'confirming' -and $Record.EndOffset -gt $request.Boundary -and
            $event.TurnId -and -not $same -and $event.Kind -in @('task_started', 'turn_started', 'turn_context')) {
            if (-not $request.CandidateTurnId) {
                $request.CandidateTurnId = $event.TurnId
                $request.LinkedTurns[$event.TurnId] = $true
                Write-RetryState $Monitor 'retry-candidate' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; observedTurn = $event.TurnId; association = 'post-click-new-turn' }
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
            if ($state.Phase -eq 'confirming' -and $Record.EndOffset -gt $request.Boundary) {
                # A second unlinked turn is unrelated until it matches the candidate.
                continue
            } else {
                $request.Superseded = $true
                Write-RetryState $Monitor 'retry-superseded' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId }
                $state.Active = $null; $state.Phase = 'observing'
                if ($Monitor.UiOwner -eq $key) { $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue }
            }
        }
        if ($state.Phase -ne 'confirming' -or $Record.EndOffset -le $request.Boundary -or -not $same) { continue }
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
        if ($otherWork -and $Monitor.Sessions.ContainsKey($ownerKey) -and $Monitor.Sessions[$ownerKey].Active) {
            $ownerState = $Monitor.Sessions[$ownerKey]
            # Yield ownership without discarding UI progress. Re-resolving from
            # scratch on every 5-second lease caused search-input/results stages
            # to restart indefinitely, especially when Electron needed time to
            # render the result list. The next owner can continue with the
            # existing window and stage; the normal deadline still bounds it.
            $ownerState.Phase = 'waiting'; $ownerState.NextEligible = $Now
            Write-RetryState $Monitor 'ui-yield' $ownerState.Active.Hint.SourcePath $ownerKey @{ leaseSeconds = $leaseSeconds }
        }
        $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
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
            $request.UiDeadline = $Now.AddSeconds($Monitor.Options.RetryUiWaitSeconds)
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
            $request.Boundary = $before; $request.ConfirmDeadline = $Now.AddSeconds($Monitor.Options.RetryConfirmSeconds)
            $state.Phase = 'confirming'; $state.NextEligible = $Now.AddSeconds($Monitor.Options.CooldownSeconds)
            Write-RetryState $Monitor 'retry-clicked' $request.Hint.SourcePath $key @{ turn = $request.Hint.TurnId; offset = $before }
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
        $Monitor.UiOwner = ''; $Monitor.UiLeaseStarted = [datetime]::MinValue
    }
}
