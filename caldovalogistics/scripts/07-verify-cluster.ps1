<#
.SYNOPSIS
    Verify the HorizonDB control-plane state needed by the demos.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics'
)

$ErrorActionPreference = 'Stop'

$cluster = az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query '{name:name,state:properties.provisioningState,version:properties.version,vCores:properties.vCores,replicas:properties.replicaCount,primary:properties.fullyQualifiedDomainName}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Failed to read cluster '$ClusterName'." }

$checks = @(
    [pscustomobject]@{ Check = 'Provisioning state'; Passed = $cluster.state -eq 'Succeeded'; Value = $cluster.state }
    [pscustomobject]@{ Check = 'PostgreSQL version'; Passed = [string]$cluster.version -eq '17'; Value = $cluster.version }
    [pscustomobject]@{ Check = 'Readable HA replica'; Passed = [int]$cluster.replicas -ge 1; Value = $cluster.replicas }
    [pscustomobject]@{ Check = 'Primary endpoint'; Passed = -not [string]::IsNullOrWhiteSpace($cluster.primary); Value = $cluster.primary }
)

$checks | Format-Table -AutoSize
if ($checks.Passed -contains $false) {
    throw 'One or more HorizonDB control-plane checks failed.'
}

Write-Host 'Cluster control-plane checks passed.' -ForegroundColor Green
Write-Host 'Run sql/05-verify.sql through the PostgreSQL extension for database checks.' -ForegroundColor Cyan
