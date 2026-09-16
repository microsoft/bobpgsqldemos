<#
.SYNOPSIS
    Provision and deploy the Caldova remote MCP server and chat model.
#>
[CmdletBinding()]
param(
    [string]$Subscription = 'AzureSQL_bobward',
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$Location = 'westus3',
    [string]$FoundryAccountName = 'caldova-logistics-ai',
    [string]$EnvironmentName = 'caldova-demo4',
    [switch]$Approve
)

$ErrorActionPreference = 'Stop'
if (-not $Approve) {
    throw 'Deployment creates billable Azure resources. Re-run with -Approve.'
}

$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$templatePath = Join-Path $demoRoot 'infra\main.bicep'

if (-not (Test-Path $configPath)) {
    throw 'Run the parent Caldova scripts/00-preflight.ps1 first.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw 'Azure Developer CLI is required.'
}

$config = Get-Content -Raw $configPath | ConvertFrom-Json
$subscriptionId = az account show --subscription $Subscription --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    throw "Unable to resolve Azure subscription '$Subscription'."
}

$agentPasswordSecure = Read-Host -Prompt 'Password for caldova_agent' -AsSecureString
$agentPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($agentPasswordSecure)
$agentPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($agentPointer)

try {
    az account set --subscription $subscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'Failed to select the Azure subscription.' }

    $existingEnvironment = azd env list --cwd $demoRoot --output json | ConvertFrom-Json |
        Where-Object Name -eq $EnvironmentName
    if (-not $existingEnvironment) {
        azd env new $EnvironmentName --cwd $demoRoot --subscription $subscriptionId --location $Location --no-prompt
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the azd environment.' }
    }
    azd env select $EnvironmentName --cwd $demoRoot
    azd env set AZURE_SUBSCRIPTION_ID $subscriptionId --cwd $demoRoot
    azd env set AZURE_RESOURCE_GROUP $ResourceGroup --cwd $demoRoot
    azd env set AZURE_LOCATION $Location --cwd $demoRoot

    az deployment group create `
        --name $EnvironmentName `
        --resource-group $ResourceGroup `
        --template-file $templatePath `
        --parameters `
            environmentName=$EnvironmentName `
            location=$Location `
            foundryAccountName=$FoundryAccountName `
            databaseHost=$($config.readerHost) `
            databaseWriteHost=$($config.primaryHost) `
            databaseName=$($config.database) `
            databaseUser=caldova_agent `
            databasePassword=$agentPassword `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) { throw 'Azure resource deployment failed.' }

    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
    azd deploy mcp --cwd $demoRoot --environment $EnvironmentName --no-prompt
    if ($LASTEXITCODE -ne 0) { throw 'MCP application deployment failed.' }

    Write-Host 'Remote MCP server and chat deployment are ready.' -ForegroundColor Green
    Write-Host 'Dot-source scripts/02-connect-app.ps1 before starting the app.' -ForegroundColor Cyan
}
finally {
    Remove-Item Env:AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
    if ($agentPointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($agentPointer)
    }
    $agentPassword = $null
}