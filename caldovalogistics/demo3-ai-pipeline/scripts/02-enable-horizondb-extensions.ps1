<#
.SYNOPSIS
    Allow the extensions required by the native HorizonDB AI pipeline.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Location = 'westus3',
    [string]$ParameterGroupName = 'caldova-ai-pipeline-pg17-v3',
    [Parameter(Mandatory)]
    [string]$AllowedExtensions,
    [Parameter(Mandatory)]
    [string]$SharedPreloadLibraries
)

$ErrorActionPreference = 'Stop'

az horizondb parameter-group create `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ParameterGroupName `
    --location $Location `
    --version 17 `
    --parameters `
        "azure.extensions=$AllowedExtensions" `
        "shared_preload_libraries=$SharedPreloadLibraries" `
    --apply-immediately true `
    --description 'Caldova native AI pipeline extensions' `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create or update parameter group '$ParameterGroupName'." }
$parameterGroupId = az horizondb parameter-group show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ParameterGroupName `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0 -or -not $parameterGroupId) {
    throw "Failed to resolve parameter group '$ParameterGroupName'."
}

$clusterParameterGroupId = az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query properties.parameterGroup.id `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "Failed to read cluster '$ClusterName'." }

if ($clusterParameterGroupId -ne $parameterGroupId) {
    az horizondb update `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --parameter-group $parameterGroupId `
        --yes `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to attach parameter group '$ParameterGroupName'." }
}

az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query '{state:properties.state,parameterGroup:properties.parameterGroup.id,sync:properties.parameterGroup.syncStatus}' `
    --output table
