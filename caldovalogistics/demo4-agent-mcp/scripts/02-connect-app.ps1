<#
.SYNOPSIS
    Load the deployed Foundry Hosted Agent endpoint into the current PowerShell process.
#>
[CmdletBinding()]
param(
    [string]$Subscription = 'AzureSQL_bobward',
    [string]$AgentProjectPath
)

$ErrorActionPreference = 'Stop'
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
    [System.Environment]::GetEnvironmentVariable('Path', 'User')
$demoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AgentProjectPath = if ($AgentProjectPath) {
    $AgentProjectPath
}
else {
    Join-Path $demoRoot 'demo4-foundry-agent\caldova-logistics-agent'
}

if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw 'Azure Developer CLI is required. Install azd and reopen the terminal.'
}
if (-not (Test-Path (Join-Path $AgentProjectPath 'azure.yaml'))) {
    throw "Hosted Agent project was not found at $AgentProjectPath."
}

az account set --subscription $Subscription
if ($LASTEXITCODE -ne 0) { throw 'Failed to select the Azure subscription.' }

Push-Location $AgentProjectPath
try {
    $agentJson = azd ai agent show --output json
    if ($LASTEXITCODE -ne 0) { throw 'Failed to resolve the deployed Foundry Hosted Agent.' }
    $agent = $agentJson | ConvertFrom-Json
}
finally {
    Pop-Location
}

$endpoint = $agent.agent_endpoints.responses
if ($agent.status -ne 'active' -or [string]::IsNullOrWhiteSpace($endpoint)) {
    throw "Foundry Hosted Agent '$($agent.name)' version '$($agent.version)' is not active with a Responses endpoint."
}

$env:CALDOVA_HOSTED_AGENT_ENDPOINT = $endpoint

Write-Host "Caldova app connected to Hosted Agent $($agent.name) version $($agent.version)." -ForegroundColor Green
Write-Host 'The app authenticates with the current Azure identity; no model or Function keys were loaded.' -ForegroundColor Cyan
