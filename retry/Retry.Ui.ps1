# Desktop adapter: session resolver -> navigation -> retry actuator.
# The isolated worker can enter at verify/actuate with an existing window, so
# it must load UIAutomation before any typed AutomationElement reference runs.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

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
            $sidebar = $current.ClassName -match 'sidebar-item|sidebar-row|folder-row|group/cwd'
            $searchRegion = $false
            $ancestor = $element
            for ($depth = 0; $depth -lt 20; $depth++) {
                $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
                if (-not $ancestor) { break }
                $class = [string]$ancestor.Current.ClassName
                if ($class -match 'sidebar-item|sidebar-row|folder-row|app-shell-left-panel') { $sidebar = $true }
                if ($class -match 'dialog|search-results|search-result|search-modal' -or
                    $ancestor.Current.ControlType -eq [Windows.Automation.ControlType]::Window -and $ancestor.Current.Name -match '(?i)search|搜索') { $searchRegion = $true }
                if ($ancestor.Current.ControlType -eq [Windows.Automation.ControlType]::Document) { break }
            }
            [pscustomobject]@{
                Element = $element; Name = [string]$current.Name; Id = [string]$current.AutomationId
                Class = [string]$current.ClassName; Type = $current.ControlType.ProgrammaticName.Replace('ControlType.', '')
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
    if ($actual -cne $expected -and (-not $prefix -or -not $actual.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) { return $false }
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
        if ($pattern.Current.Value -cne $Text) { throw 'Search input readback does not equal the requested value.' }
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
                if ($current.ClassName -match 'sidebar-item|sidebar-row|folder-row|app-shell-left-panel') { break }
                $controlType = $current.ControlType.ProgrammaticName.Replace('ControlType.', '')
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
        $matches = @()
        foreach ($window in $windows) {
            $snapshot = @(Read-DesktopSnapshot $window $monitor)
            $active = Test-ActiveSession $snapshot $hint $monitor
            $target = if ($active) { $null } else { Find-SessionTarget $snapshot $hint $monitor }
            if ($target -or $active) { $matches += [pscustomobject]@{ Window = $window; Target = $target; Active = $active } }
        }
        if ($matches.Count -gt 1) { throw 'Target session is visible in multiple desktop windows.' }
        if ($matches.Count -eq 1) {
            $Request.Window = $matches[0].Window
            if ($matches[0].Target) {
                if (-not (Invoke-UiNode $matches[0].Target $monitor 'navigation' $true)) { throw 'Session navigation failed.' }
                $Request.ReadyAt = $Now.AddMilliseconds(500)
            }
            $Request.Stage = 'verify'; return 'Pending'
        }
        if ($windows.Count -ne 1) { throw 'Cannot choose a desktop window for session search.' }
        $Request.Window = $windows[0]
        $snapshot = @(Read-DesktopSnapshot $Request.Window $monitor)
        $search = @($snapshot | Where-Object { $_.Visible -and $_.Enabled -and $_.Type -eq 'Button' -and $_.Name -match '^(Search|搜索)$' })
        if ($search.Count -ne 1 -or -not (Invoke-UiNode $search[0] $monitor 'search-open')) { throw 'Cannot open an unambiguous session search.' }
        $Request.Stage = 'search-input'; $Request.ReadyAt = $Now.AddMilliseconds(300); return 'Pending'
    }
    $snapshot = @(Read-DesktopSnapshot $Request.Window $monitor)
    switch ($Request.Stage) {
        'search-input' {
            $edits = @($snapshot | Where-Object { $_.Visible -and $_.Enabled -and $_.Type -eq 'Edit' -and ($_.SearchRegion -or $_.Name -match '(?i)search|搜索') })
            if ($edits.Count -ne 1) { throw 'Search edit is missing or ambiguous.' }
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
        Stage = [string]$Request.Stage; ReadyAt = $Request.ReadyAt.ToString('o')
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
                UiDeadline = [datetime]::MinValue; ConfirmDeadline = [datetime]::MinValue
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
