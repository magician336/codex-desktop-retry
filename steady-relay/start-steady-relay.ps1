[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string] $Upstream,
    [string] $Listen = '127.0.0.1:8080',
    [int] $MaxRetries = 10,
    [switch] $BufferUntilSuccess
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'steady-relay.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Missing $exe. Build with: go build -o steady-relay.exe ."
}

$args = @('--upstream', $Upstream, '--listen', $Listen, '--max-retries', $MaxRetries)
if ($BufferUntilSuccess) { $args += '--buffer-until-success' }

Write-Host "Starting Steady Relay on http://$Listen/v1" -ForegroundColor Cyan
Write-Host "Upstream: $Upstream" -ForegroundColor DarkCyan
Write-Host 'Keep this window open while Codex is using the relay.' -ForegroundColor Yellow
& $exe @args
exit $LASTEXITCODE
