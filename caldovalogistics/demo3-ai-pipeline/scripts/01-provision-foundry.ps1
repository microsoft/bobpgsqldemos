<#
.SYNOPSIS
    Create the Foundry resource and embedding deployment for Demo 3.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$Location = 'westus3',
    [string]$AccountName = 'caldova-logistics-ai',
    [string]$DeploymentName = 'caldova-embedding',
    [int]$Capacity = 10
)

$ErrorActionPreference = 'Stop'

$account = az cognitiveservices account show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $AccountName `
    --output json `
    --only-show-errors 2>$null | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or -not $account) {
    az cognitiveservices account create `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $AccountName `
        --location $Location `
        --kind AIServices `
        --sku S0 `
        --custom-domain $AccountName `
        --yes `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create Foundry resource '$AccountName'." }
}

$deployment = az cognitiveservices account deployment show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $AccountName `
    --deployment-name $DeploymentName `
    --output json `
    --only-show-errors 2>$null | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or -not $deployment) {
    az cognitiveservices account deployment create `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $AccountName `
        --deployment-name $DeploymentName `
        --model-format OpenAI `
        --model-name text-embedding-3-small `
        --model-version 1 `
        --sku-name GlobalStandard `
        --sku-capacity $Capacity `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to deploy model '$DeploymentName'." }
}

az cognitiveservices account deployment show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $AccountName `
    --deployment-name $DeploymentName `
    --query '{deployment:name,model:properties.model.name,version:properties.model.version,sku:sku.name,capacity:sku.capacity,state:properties.provisioningState}' `
    --output table
if ($LASTEXITCODE -ne 0) { throw 'Failed to verify the embedding deployment.' }
