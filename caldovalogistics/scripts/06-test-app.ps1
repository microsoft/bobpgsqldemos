<#
.SYNOPSIS
    Run the Caldova application test suite.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'

if (-not (Test-Path $pythonPath)) {
    throw 'Run scripts/04-install-app.ps1 first.'
}

Push-Location (Join-Path $projectRoot 'app')
try {
    & $pythonPath -m pytest tests -q
    if ($LASTEXITCODE -ne 0) { throw 'Application tests failed.' }
}
finally {
    Pop-Location
}
