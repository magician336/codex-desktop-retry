Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $repo 'codex-desktop-retry.ps1'))
$source = [regex]::Replace($source, '(?m)^\. \(Join-Path \$PSScriptRoot ''retry\\[^'']+''\)\r?\n', '')
$modules = @('Retry.Logs.ps1', 'Retry.State.ps1', 'Retry.Ui.ps1', 'Retry.Monitor.ps1')
$functions = ($modules | ForEach-Object { [IO.File]::ReadAllText((Join-Path $repo "retry\$_")) }) -join "`n"
$insert = $source.IndexOf('$options =')
if ($insert -lt 0) { throw 'Cannot locate launcher initialization.' }
$output = "# Frozen usable build, 2026-10-09. Further development uses the root launcher.`n" + $source.Insert($insert, $functions + "`n")
$directory = Join-Path $repo 'releases\2026-10-09'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$path = Join-Path $directory 'codex-desktop-retry.ps1'
[IO.File]::WriteAllText($path, $output, [Text.UTF8Encoding]::new($true))
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
Write-Output $path
