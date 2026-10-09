# Read-only UIA check: no navigation, keyboard input or mouse clicks.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'retry\Retry.Logs.ps1')
. (Join-Path $repo 'retry\Retry.State.ps1')
. (Join-Path $repo 'retry\Retry.Monitor.ps1')
. (Join-Path $repo 'retry\Retry.Ui.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-retry-desktop-' + [guid]::NewGuid().ToString('N'))
$monitor = New-RetryMonitor @{
    ProcessName = @('ChatGPT','Codex','OpenAI.Codex'); StatePath = (Join-Path $temp 'state.jsonl')
    UiDiagnosticPath = (Join-Path $temp 'diag.log'); StateMaxBytes = 1048576; StateMaxFiles = 3
}
try {
    $windows = @(Get-DesktopWindows $monitor)
    if ($windows.Count -eq 0) { throw 'No live desktop window found for read-only verification.' }
    foreach ($window in $windows) {
        $snapshot = @(Read-DesktopSnapshot $window $monitor)
        $documents = @($snapshot | Where-Object { $_.Type -eq 'Document' -and $_.Visible })
        if ($snapshot.Count -eq 0 -or $documents.Count -eq 0) { throw 'UIA snapshot did not expose a visible page document.' }
        $hint = [pscustomobject]@{ SessionId=''; Title=$documents[0].Name }
        if (-not (Test-ActiveSession $snapshot $hint $monitor)) { throw 'Active document identity was not detected.' }
        Write-Output "PASS desktop-readonly: pid=$($window.ProcessId) nodes=$($snapshot.Count) active-document=$($documents.Count)"
    }
} finally { $monitor.StateMutex.Dispose() }
