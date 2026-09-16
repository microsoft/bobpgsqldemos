<#
.SYNOPSIS
    Validate Azure prerequisites for the Caldova HorizonDB demo.

.DESCRIPTION
    Internal read-only helper used by setup and the overall demo preflight.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Location = 'westus3'
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Value)
    $checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Value = $Value })
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not installed or is not on PATH.'
}

$context = az account show `
    --subscription $Subscription `
    --query '{name:name,id:id,tenantId:tenantId,user:user.name,state:state}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $context) {
    throw "Cannot access subscription '$Subscription'. Run az login and verify access."
}
Add-Check 'Subscription' ($context.state -eq 'Enabled') "$($context.name) ($($context.id))"
Add-Check 'Signed-in identity' (-not [string]::IsNullOrWhiteSpace($context.user)) $context.user

$extension = az extension show `
    --name horizondb `
    --query '{name:name,version:version}' `
    --output json 2>$null | ConvertFrom-Json
Add-Check 'HorizonDB CLI extension' ($LASTEXITCODE -eq 0 -and $extension) $(
    if ($extension) { "$($extension.name) $($extension.version)" } else { 'Not installed' }
)

$provider = az provider show `
    --subscription $context.id `
    --namespace Microsoft.HorizonDB `
    --query '{state:registrationState,locations:resourceTypes[?resourceType==`clusters`].locations | [0]}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $provider) {
    throw 'Failed to read the Microsoft.HorizonDB provider state.'
}
Add-Check 'Microsoft.HorizonDB provider' ($provider.state -eq 'Registered') $provider.state

$locationInfo = az account list-locations `
    --query "[?name=='$Location'] | [0].{name:name,displayName:displayName}" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve Azure region '$Location'."
}
$locationSupported = $locationInfo -and $provider.locations -contains $locationInfo.displayName
Add-Check 'HorizonDB region' $locationSupported $(
    if ($locationInfo) { "$($locationInfo.displayName) ($Location)" } else { "$Location is not an Azure region" }
)

$resourceGroupExists = az group exists `
    --subscription $context.id `
    --name $ResourceGroup | ConvertFrom-Json
Add-Check 'Resource group state' $true $(
    if ($resourceGroupExists) { "$ResourceGroup already exists" } else { "$ResourceGroup is available to create" }
)

$cluster = az horizondb show `
    --subscription $context.id `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query '{name:name,state:properties.provisioningState,location:location,version:properties.version,vCores:properties.vCores,replicas:properties.replicaCount}' `
    --output json `
    --only-show-errors 2>$null | ConvertFrom-Json
$clusterLookupSucceeded = $LASTEXITCODE -eq 0 -and $cluster
Add-Check 'Target cluster state' $true $(
    if ($clusterLookupSucceeded) {
        "$($cluster.name) exists: $($cluster.state), PostgreSQL $($cluster.version), $($cluster.vCores) vCores, $($cluster.replicas) replica(s)"
    }
    else {
        "$ClusterName is available to create in $ResourceGroup"
    }
)

$otherClusters = @(az horizondb list `
    --subscription $context.id `
    --query '[].{name:name,resourceGroup:resourceGroup,location:location,state:properties.provisioningState}' `
    --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Failed to list existing HorizonDB clusters.' }
Add-Check 'Existing HorizonDB inventory' $true $(
    if ($otherClusters.Count -eq 0) { 'No existing clusters' }
    else { ($otherClusters | ForEach-Object { "$($_.name) [$($_.resourceGroup), $($_.location), $($_.state)]" }) -join '; ' }
)

Write-Host '=== Caldova Logistics: Azure prerequisites ===' -ForegroundColor Cyan
$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "Azure prerequisites failed: $($failed.Check -join ', ')."
}

Write-Host 'Azure prerequisites passed. No resources were changed.' -ForegroundColor Green
