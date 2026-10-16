<#
.SYNOPSIS
    Build and verify the Caldova Knowledge Hub database objects on HorizonDB.
.DESCRIPTION
    Requires the parent Caldova preflight and Demo 3 preflight (Foundry model
    alias caldova-embedding). Creates the knowledge_hub schema, the on_change
    AI pipeline, the pg_durable reconciler, seed articles, and the
    least-privilege knowledge_hub_app role, then waits until every article is
    searchable. Generates KNOWLEDGE_HUB_APP_PASSWORD in the ignored pwd.env
    when that file exists without it; prompts when pwd.env is absent.
#>
[CmdletBinding()]
param(
    [switch]$ResetArticles
)

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$pythonPath = Join-Path $kitRoot '.venv\Scripts\python.exe'
$passwordFile = Join-Path $kitRoot 'pwd.env'
$helperPath = Join-Path $PSScriptRoot 'Invoke-KnowledgeHub.py'

if (-not (Test-Path $configPath) -or -not (Test-Path $pythonPath)) {
    throw 'Run the parent Caldova scripts/00-preflight.ps1 first.'
}

if (Test-Path $passwordFile) {
    if (-not (Select-String -Path $passwordFile -Pattern '^\s*KNOWLEDGE_HUB_APP_PASSWORD=' -Quiet)) {
        $bytes = [byte[]]::new(24)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $generated = 'Kh1-' + ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'x')
        $existing = [System.IO.File]::ReadAllText($passwordFile)
        $separator = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { [Environment]::NewLine } else { '' }
        [System.IO.File]::AppendAllText($passwordFile, "${separator}KNOWLEDGE_HUB_APP_PASSWORD=$generated$([Environment]::NewLine)")
        Write-Host 'Generated KNOWLEDGE_HUB_APP_PASSWORD in the ignored pwd.env.' -ForegroundColor Yellow
    }
}
else {
    Write-Host 'pwd.env not found; you will be prompted for the admin and knowledge_hub_app passwords. Choose a strong app password and reuse it for 01-run-local.ps1 and 02-deploy-appservice.ps1.' -ForegroundColor Yellow
}

$adminPassword = & "$kitRoot\scripts\Get-CaldovaDatabasePassword.ps1" -ProjectRoot $kitRoot -Prompt 'HorizonDB admin password'
$appPassword = & "$kitRoot\scripts\Get-CaldovaDatabasePassword.ps1" -ProjectRoot $kitRoot -CredentialName 'KNOWLEDGE_HUB_APP_PASSWORD' -Prompt 'knowledge_hub_app password (new or existing)'

try {
    $env:CALDOVA_DATABASE_PASSWORD = $adminPassword
    $env:KNOWLEDGE_HUB_APP_PASSWORD = $appPassword
    $arguments = @($helperPath, 'setup', '--config', $configPath)
    if ($ResetArticles) { $arguments += '--reset' }
    $result = & $pythonPath @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Knowledge Hub setup failed.' }
    $state = $result | ConvertFrom-Json
    [pscustomobject]@{
        Ready = $state.ready
        Articles = "$($state.searchable)/$($state.articles) searchable"
        Chunks = "$($state.embedded_chunks)/$($state.expected_chunks) embedded"
        Reconciler = $state.reconciler
    } | Format-List
}
finally {
    Remove-Item Env:\CALDOVA_DATABASE_PASSWORD, Env:\KNOWLEDGE_HUB_APP_PASSWORD -ErrorAction SilentlyContinue
    $adminPassword = $null
    $appPassword = $null
}
