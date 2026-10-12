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
