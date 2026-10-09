[CmdletBinding()]
param(
    [string[]] $LogRoot = @(
        (Join-Path $env:USERPROFILE '.codex')
    ),
    [string[]] $ProcessName = @('ChatGPT', 'Codex', 'OpenAI.Codex'),
    [int] $MaxRetries = 0,
    [int[]] $BackoffSeconds = @(0, 0, 0, 0, 0),
    [double] $PollSeconds = 0.25,
    [int] $CooldownSeconds = 20,
    [int] $RetryUiWaitSeconds = 90,
    [int] $RetryConfirmSeconds = 30,
    [string] $StatePath = (Join-Path $PSScriptRoot 'retry-state.json'),
    [string] $UiDiagnosticPath = (Join-Path $PSScriptRoot 'ui-controls.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($MaxRetries -lt 0) { throw 'MaxRetries must be >= 0.' }
if ($PollSeconds -le 0) { throw 'PollSeconds must be > 0.' }
if ($RetryConfirmSeconds -le 0) { throw 'RetryConfirmSeconds must be > 0.' }
if ($BackoffSeconds.Count -eq 0) { throw 'BackoffSeconds must contain at least one value.' }

$capacityPattern = [regex]::new(
    'Selected model is at capacity|model[_ -]capacity[_ -]exceeded|server[_ -]overloaded|currently overloaded|overloaded_error',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$offsets = @{}
$lastRestart = [DateTime]::MinValue
$retryCount = 0
$logFilesCache = @()
$lastLogScan = [DateTime]::MinValue

function Write-State([string] $Event, [string] $Detail = '') {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        retry = $retryCount
        detail = $Detail
    }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $StatePath -Encoding UTF8
}

function Get-LogFiles {
    foreach ($root in $LogRoot) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.jsonl','*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 30
        } catch { Write-Verbose "Cannot scan ${root}: $($_.Exception.Message)" }
    }
}

function Get-SessionHint([string] $Path) {
    $result = [ordered]@{ SessionId = ''; Text = '' }
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -TotalCount 3 -ErrorAction Stop)) {
            try { $json = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $result.SessionId -and $json.payload.session_id) { $result.SessionId = [string]$json.payload.session_id }
        }
        $userLine = Select-String -LiteralPath $Path -Pattern '"type":"UserMessage"' -SimpleMatch -List -ErrorAction SilentlyContinue
        if ($userLine) {
            try {
                $json = $userLine.Line | ConvertFrom-Json -ErrorAction Stop
                $item = $json.payload.item
                $text = ($item.content | Where-Object { $_.text } | Select-Object -First 1).text
                if ($text) {
                    $clean = [string]$text
                    # Sidebar titles omit Markdown link targets. Normalize the
                    # rollout message to the same visible text before matching.
                    $clean = [regex]::Replace($clean, '\[([^\]]+)\]\s*\\?\([^\)]*\\?\)', '$1')
                    $clean = [regex]::Replace($clean, '\s+', ' ').Trim()
                    $result.Text = $clean
                }
            } catch { }
        }
        if ($result.SessionId) {
            $indexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
            if (Test-Path -LiteralPath $indexPath) {
                $indexLine = Select-String -LiteralPath $indexPath -Pattern ('"id":"' + [regex]::Escape($result.SessionId) + '"') -SimpleMatch:$false -List -ErrorAction SilentlyContinue
                if ($indexLine) {
                    try {
                        $indexJson = $indexLine.Line | ConvertFrom-Json -ErrorAction Stop
                        if ($indexJson.thread_name) { $result.Text = [string]$indexJson.thread_name }
                    } catch { }
                }
            }
        }
    } catch { }
    return $result
}

function Get-SessionRolloutSnapshot([string] $SessionId) {
    $snapshot = @{}
    if (-not $SessionId) { return $snapshot }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.codex\sessions') -Recurse -File -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue)) {
        try { $file.Refresh(); $snapshot[$file.FullName] = $file.Length } catch { }
    }
    return $snapshot
}

function Confirm-RetryProgress([string] $SessionId, [hashtable] $Before, [int] $TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.codex\sessions') -Recurse -File -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue)) {
            $oldLength = if ($Before.ContainsKey($file.FullName)) { [int64]$Before[$file.FullName] } else { 0 }
            try { $file.Refresh(); $newLength = [int64]$file.Length } catch { continue }
            if ($newLength -le $oldLength) { continue }
            try {
                $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                $stream.Position = $oldLength
                $reader = [IO.StreamReader]::new($stream)
                $added = $reader.ReadToEnd()
                $reader.Dispose(); $stream.Dispose()
            } catch { continue }
            if ($added -match 'server[_ -]overloaded|Selected model is at capacity|model[_ -]capacity[_ -]exceeded') {
                continue
            }
            if ($added -match '"type":"task_started"|"type":"turn_started"|"type":"item_started"|response\.output_text\.delta|"role":"assistant"|"type":"task_complete"') {
                return $true
            }
            $Before[$file.FullName] = $newLength
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-CapacityUi($Root) {
    $all = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($control in $all) {
        $name = [string]$control.Current.Name
        if ($name -match 'Selected model is at capacity|server[_ -]overloaded|容量|\d+\s*(秒|s).*(重试|retry)|(重试|retry).*\d+\s*(秒|s)') { return $true }
    }
    return $false
}

function Try-InvokeRetryControl($Root, $SeenNames, $UiLines, [bool] $AllowComposerFallback = $false) {
    $all = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $composerCandidates = New-Object System.Collections.Generic.List[object]
    $windowRect = $Root.Current.BoundingRectangle
    foreach ($control in $all) {
        $name = [string]$control.Current.Name
        if ($name) { $SeenNames.Add($name) }
        try {
            $UiLines.Add("$($control.Current.ControlType.ProgrammaticName)`t$name`tautomationId=$($control.Current.AutomationId)`tclass=$($control.Current.ClassName)")
        } catch { }
        if (
            $control.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and
            $control.Current.ClassName -match 'bg-composer-primary' -and
            $control.Current.ClassName -match 'composer' -and
            $control.Current.IsEnabled -and
            -not $control.Current.IsOffscreen) {
            try {
                $rect = $control.Current.BoundingRectangle
                $rightZone = $windowRect.X + ($windowRect.Width * 0.65)
                $bottomZone = $windowRect.Y + ($windowRect.Height * 0.55)
                if ($rect.X -ge $rightZone -and $rect.Y -ge $bottomZone -and $rect.Width -gt 2 -and $rect.Height -gt 2) {
                    $composerCandidates.Add($control)
                }
            } catch { }
        }
        $isRetryControl = $name -match '^(?i:Retry|Try again|重试|再次尝试)(\s|$|[：:：])' -or
            $name -match '(?i)\d+\s*(秒|s).*(重试|retry)|(重试|retry).*\d+\s*(秒|s)' -or
            ($control.Current.ControlType -eq [Windows.Automation.ControlType]::ProgressBar -and $name -match '(?i)\d+\s*(秒|s)')
        $isSidebarControl = $control.Current.ClassName -match 'sidebar-item|folder-row|group/cwd|sidebar-row' -or
            $name -match '项目操作|开始新聊天|置顶聊天|归档聊天|中的已安排任务'
        if ($isRetryControl -and -not $isSidebarControl) {
            try {
                $invoke = $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                ([Windows.Automation.InvokePattern]$invoke).Invoke()
                Write-Host "Invoked ChatGPT/Codex '$name' control." -ForegroundColor Green
                return $true
            } catch {
                try {
                    $legacy = $control.GetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern)
                    ([Windows.Automation.LegacyIAccessiblePattern]$legacy).DoDefaultAction()
                    Write-Host "Invoked legacy action on ChatGPT/Codex '$name' control." -ForegroundColor Green
                    return $true
                } catch { }
                try {
                    $selection = $control.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
                    ([Windows.Automation.SelectionItemPattern]$selection).Select()
                    Write-Host "Selected ChatGPT/Codex '$name' control." -ForegroundColor Green
                    return $true
                } catch { }
                try {
                    $toggle = $control.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
                    ([Windows.Automation.TogglePattern]$toggle).Toggle()
                    Write-Host "Toggled ChatGPT/Codex '$name' control." -ForegroundColor Green
                    return $true
                } catch { }
                try {
                    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
                    $parent = $walker.GetParent($control)
                    $parentInvoke = $parent.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                    ([Windows.Automation.InvokePattern]$parentInvoke).Invoke()
                    Write-Host "Invoked parent of ChatGPT/Codex '$name' control." -ForegroundColor Green
                    return $true
                } catch { }
                try {
                    if (-not ('RetryNativeMouse' -as [type])) {
                        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RetryNativeMouse {
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError=true)] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
}
"@
                    }
                    $rect = $control.Current.BoundingRectangle
                    if ($rect.Width -gt 2 -and $rect.Height -gt 2) {
                        [RetryNativeMouse]::Click([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
                        Write-Host "Clicked ChatGPT/Codex '$name' control at its UI bounds." -ForegroundColor Green
                        return $true
                    }
                } catch { }
            }
        }
    }
    $composerCandidate = $composerCandidates |
        Sort-Object @{ Expression = { $_.Current.BoundingRectangle.X + $_.Current.BoundingRectangle.Y } } -Descending |
        Select-Object -First 1
    if ($AllowComposerFallback -and $composerCandidate) {
        try {
            $invoke = $composerCandidate.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
            ([Windows.Automation.InvokePattern]$invoke).Invoke()
            Write-Host "Invoked the ChatGPT composer send button '$($composerCandidate.Current.Name)'." -ForegroundColor Green
            return $true
        } catch {
            try {
                $rect = $composerCandidate.Current.BoundingRectangle
                if ($rect.Width -gt 2 -and $rect.Height -gt 2) {
                    if (-not ('RetryNativeMouse' -as [type])) {
                        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RetryNativeMouse {
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero); }
}
"@
                    }
                    [RetryNativeMouse]::Click([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
                    Write-Host 'Clicked the ChatGPT composer send button at its UI bounds.' -ForegroundColor Green
                    return $true
                }
            } catch { }
        }
    }
    return $false
}

function Invoke-CodexRetry([string] $LogPath) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $process) { throw "No visible ChatGPT/Codex window found." }
    $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $hint = Get-SessionHint $LogPath
    $condition = [Windows.Automation.Condition]::TrueCondition
    $buttons = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    $seenNames = New-Object System.Collections.Generic.List[string]
    $uiLines = New-Object System.Collections.Generic.List[string]

    # Select the failed session from the sidebar before searching for Retry.
    # Session ids are preferred; the first user message is a fallback because
    # ChatGPT often exposes the conversation title rather than its UUID.
    $target = $null
    $targetCandidates = New-Object System.Collections.Generic.List[object]
    $needle = @($hint.SessionId, ($hint.Text -replace '\s+', ' ').Trim())
    $needle = @($needle | Where-Object { $_ })
    if ($needle.Count -gt 0) {
        foreach ($element in $buttons) {
            $name = [string]$element.Current.Name
            if ($name -and (($needle | Where-Object { $name -eq $_ -or ($_.Length -ge 8 -and $name.Contains($_.Substring(0,[Math]::Min(24,$_.Length)))) }) | Select-Object -First 1)) {
                $targetCandidates.Add($element)
            }
        }
    }
    if ($targetCandidates.Count -gt 0) {
        $target = $targetCandidates |
            Sort-Object @{ Expression = { if ($_.Current.ControlType -eq [Windows.Automation.ControlType]::Button) { 0 } else { 1 } } } |
            Select-Object -First 1
    }
    if (-not $target -and $needle.Count -gt 0) {
        # The conversation may not be loaded in the visible sidebar. Use the
        # ChatGPT search button and locate it from the search results.
        $search = $buttons | Where-Object {
            $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and
            ([string]$_.Current.Name -match '^(搜索|Search)$')
        } | Select-Object -First 1
        if ($search) {
            try {
                $searchInvoke = $search.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                ([Windows.Automation.InvokePattern]$searchInvoke).Invoke()
                Start-Sleep -Milliseconds 300
                $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                $allSearch = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
                $edit = $allSearch | Where-Object {
                    $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit
                } | Select-Object -First 1
                if ($edit) {
                    $searchText = [string]$hint.Text
                    if ($searchText.Length -gt 80) { $searchText = $searchText.Substring(0,80) }
                    $value = $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                    ([Windows.Automation.ValuePattern]$value).SetValue($searchText)
                    Start-Sleep -Milliseconds 600
                    $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                    $allSearch = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
                    $target = $allSearch | Where-Object {
                        $n = [string]$_.Current.Name
                        $n -and (($needle | Where-Object { $n -eq $_ -or ($_.Length -ge 8 -and $n.Contains($_.Substring(0,[Math]::Min(24,$_.Length)))) }) | Select-Object -First 1)
                    } | Sort-Object @{ Expression = { if ($_.Current.ControlType -eq [Windows.Automation.ControlType]::Button) { 0 } else { 1 } } } | Select-Object -First 1
                }
            } catch { }
        }
    }
    if ($needle.Count -gt 0 -and -not $target) {
        throw "Failed session was not found in the ChatGPT sidebar. session=$($hint.SessionId) hint=$($hint.Text.Substring(0,[Math]::Min(80,$hint.Text.Length)))"
    }
    if ($target) {
        Write-Host "Selected failed session $($hint.SessionId)." -ForegroundColor DarkCyan
        try {
            try {
                $scroll = $target.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern)
                ([Windows.Automation.ScrollItemPattern]$scroll).ScrollIntoView()
            } catch { }
            try {
                $invokeTarget = $target.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                ([Windows.Automation.InvokePattern]$invokeTarget).Invoke()
            } catch {
                $selection = $target.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
                ([Windows.Automation.SelectionItemPattern]$selection).Select()
            }
        } catch {
            throw "Could not activate failed session: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 1200
        $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $buttons = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    }
    if (Try-InvokeRetryControl $root $seenNames $uiLines (Test-CapacityUi $root)) { return $true }
    $deadline = (Get-Date).AddSeconds($RetryUiWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        if (Try-InvokeRetryControl $root $seenNames $uiLines (Test-CapacityUi $root)) { return $true }
    }
    $uiLines | Set-Content -LiteralPath $UiDiagnosticPath -Encoding UTF8
    $sample = (($seenNames | Select-Object -Unique | Select-Object -First 20) -join '; ')
    throw "Retry control was not found. Visible names: $sample"
}

Write-Host 'Codex Desktop retry monitor started. Press Ctrl+C to stop.' -ForegroundColor Cyan
Write-Host "Watching: $($LogRoot -join ', ')" -ForegroundColor DarkCyan
Write-State 'started'

while ($true) {
    if (((Get-Date) - $lastLogScan).TotalSeconds -ge 2 -or $logFilesCache.Count -eq 0) {
        $logFilesCache = @(Get-LogFiles)
        $lastLogScan = Get-Date
    }
    foreach ($file in $logFilesCache) {
        $key = $file.FullName
        try {
            $file.Refresh()
            $length = $file.Length
        } catch { continue }
        if (-not $offsets.ContainsKey($key) -or $offsets[$key] -gt $length) {
            $offsets[$key] = $length
            continue
        }
        if ($offsets[$key] -eq $length) { continue }
        try {
            $stream = [IO.File]::Open($key, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $stream.Position = $offsets[$key]
            $reader = [IO.StreamReader]::new($stream)
            $text = $reader.ReadToEnd()
            $reader.Dispose(); $stream.Dispose()
            $offsets[$key] = $length
        } catch { continue }

        if (-not $capacityPattern.IsMatch($text)) { continue }
        if (((Get-Date) - $lastRestart).TotalSeconds -lt $CooldownSeconds) { continue }
        if ($MaxRetries -gt 0 -and $retryCount -ge $MaxRetries) {
            Write-Warning "Capacity retry limit ($MaxRetries) reached; resetting the counter and continuing."
            Write-State 'limit-reset' $key
            $retryCount = 0
        }

        $delay = $BackoffSeconds[[Math]::Min($retryCount, $BackoffSeconds.Count - 1)]
        $retryCount++
        $retryLabel = if ($MaxRetries -gt 0) { "$retryCount/$MaxRetries" } else { "$retryCount/unlimited" }
        Write-Host "Capacity error detected in $key. UI retry $retryLabel in ${delay}s..." -ForegroundColor Yellow
        Write-State 'capacity-detected' $key
        Start-Sleep -Seconds $delay
        try {
            $sessionHint = Get-SessionHint $key
            $beforeRetry = Get-SessionRolloutSnapshot $sessionHint.SessionId
            $null = Invoke-CodexRetry $key
            Write-State 'retry-clicked' $sessionHint.SessionId
            if (Confirm-RetryProgress $sessionHint.SessionId $beforeRetry $RetryConfirmSeconds) {
                $lastRestart = Get-Date
                Write-State 'retry-confirmed' $sessionHint.SessionId
                $retryCount = 0
            } else {
                Write-Warning "Retry click was not confirmed by new session activity after ${RetryConfirmSeconds}s."
                Write-State 'retry-unconfirmed' $sessionHint.SessionId
            }
        } catch {
            Write-Warning "UI retry failed: $($_.Exception.Message)"
            Write-State 'retry-failed' $_.Exception.Message
        }
    }
    Start-Sleep -Milliseconds ([Math]::Max(50, [int]($PollSeconds * 1000)))
}
