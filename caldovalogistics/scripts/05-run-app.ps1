<#
.SYNOPSIS
    Run the Caldova Control Tower locally.
#>
[CmdletBinding()]
param(
    [int]$Port = 8010,
    [string]$ConnectionConfig
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'
$ConnectionConfig = if ($ConnectionConfig) { $ConnectionConfig } else { Join-Path $projectRoot '.caldova-connection.json' }
$passwordPointer = [IntPtr]::Zero
$plainPassword = $null

if (-not (Test-Path $pythonPath)) {
    throw 'Run scripts/04-install-app.ps1 first.'
}
if ([string]::IsNullOrWhiteSpace($env:CALDOVA_HOSTED_AGENT_ENDPOINT)) {
    & (Join-Path $projectRoot 'demo4-agent-mcp\scripts\02-connect-app.ps1')
}
if ([string]::IsNullOrWhiteSpace($env:WRITE_DATABASE_URL) -or [string]::IsNullOrWhiteSpace($env:READ_DATABASE_URL)) {
    if (-not (Test-Path $ConnectionConfig)) {
        throw 'Run scripts/00-preflight.ps1 first or set WRITE_DATABASE_URL and READ_DATABASE_URL.'
    }
    $config = Get-Content $ConnectionConfig -Raw | ConvertFrom-Json
    $securePassword = Read-Host -Prompt "Password for $($config.user)" -AsSecureString
    $passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    $env:WRITE_DATABASE_URL = "host=$($config.primaryHost) port=5432 dbname=$($config.database) user=$($config.user) password=$plainPassword sslmode=$($config.sslMode)"
    $env:READ_DATABASE_URL = "host=$($config.readerHost) port=5432 dbname=$($config.database) user=$($config.user) password=$plainPassword sslmode=$($config.sslMode)"
}

Push-Location (Join-Path $projectRoot 'app')
try {
    & $pythonPath -m uvicorn caldova_logistics.main:app --host 127.0.0.1 --port $Port
}
finally {
    Pop-Location
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    $plainPassword = $null
}
