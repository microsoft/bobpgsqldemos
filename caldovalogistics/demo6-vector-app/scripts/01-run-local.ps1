<#
.SYNOPSIS
    Run the Caldova Knowledge Hub locally against HorizonDB as knowledge_hub_app.
#>
[CmdletBinding()]
param(
    [int]$Port = 8020
)

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$pythonPath = Join-Path $kitRoot '.venv\Scripts\python.exe'

if (-not (Test-Path $configPath) -or -not (Test-Path $pythonPath)) {
    throw 'Run the parent Caldova scripts/00-preflight.ps1 first.'
}

& $pythonPath -c "import fastapi, uvicorn, jinja2, multipart, psycopg_pool" 2>$null
if ($LASTEXITCODE -ne 0) {
    & $pythonPath -m pip install --quiet -r (Join-Path $demoRoot 'src\requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install Knowledge Hub dependencies.' }
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$env:KNOWLEDGE_HUB_DATABASE_HOST = $config.primaryHost
$env:KNOWLEDGE_HUB_READ_HOST = $config.readerHost
$env:KNOWLEDGE_HUB_DATABASE_NAME = $config.database
$env:KNOWLEDGE_HUB_DATABASE_USER = 'knowledge_hub_app'
$env:KNOWLEDGE_HUB_DATABASE_PASSWORD = & "$kitRoot\scripts\Get-CaldovaDatabasePassword.ps1" `
    -ProjectRoot $kitRoot `
    -CredentialName 'KNOWLEDGE_HUB_APP_PASSWORD' `
    -Prompt 'knowledge_hub_app password'

Push-Location (Join-Path $demoRoot 'src')
try {
    & $pythonPath -m uvicorn main:app --host 127.0.0.1 --port $Port
}
finally {
    Pop-Location
    Remove-Item Env:\KNOWLEDGE_HUB_DATABASE_PASSWORD -ErrorAction SilentlyContinue
}
