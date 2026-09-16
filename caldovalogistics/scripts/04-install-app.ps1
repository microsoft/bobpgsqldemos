<#
.SYNOPSIS
    Create the local virtual environment and install the Caldova application.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPath = Join-Path $projectRoot '.venv'
$pythonPath = Join-Path $venvPath 'Scripts\python.exe'

if (-not (Test-Path $pythonPath)) {
    $pythonCommand = if (Get-Command python -ErrorAction SilentlyContinue) {
        'python'
    }
    elseif (Get-Command py -ErrorAction SilentlyContinue) {
        'py'
    }
    else {
        throw 'Python 3.11 or later is required.'
    }
    & $pythonCommand -m venv $venvPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the Python virtual environment.' }
}

& $pythonPath -m pip install --editable "$projectRoot\app[dev]"
if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Caldova application.' }

Write-Host "Application installed in $venvPath" -ForegroundColor Green
