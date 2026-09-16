<#
.SYNOPSIS
    Show password-free primary and reader connection details.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Database = 'postgres'
)

$ErrorActionPreference = 'Stop'

$info = az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query '{primary:properties.fullyQualifiedDomainName,reader:properties.readonlyEndpoint,admin:properties.administratorLogin,state:properties.provisioningState,replicas:properties.replicaCount}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Failed to read cluster '$ClusterName'." }

$readerEndpoint = $info.reader
if ([string]::IsNullOrWhiteSpace($readerEndpoint)) {
    $segments = $info.primary -split '\.', 2
    $remainingSegments = $segments[1] -split '\.', 2
    $readerEndpoint = "$($segments[0]).$($remainingSegments[0]).ro.$($remainingSegments[1])"
}

Write-Host '=== Caldova Logistics connection details ===' -ForegroundColor Cyan
Write-Host "State           : $($info.state)"
Write-Host "Readable replicas: $($info.replicas)"
Write-Host "Primary endpoint: $($info.primary)"
Write-Host "Reader endpoint : $readerEndpoint"
Write-Host "Database        : $Database"
Write-Host "User            : $($info.admin)"
Write-Host 'SSL mode        : require'
Write-Host "`nPrimary psql command (prompts for password):" -ForegroundColor Cyan
Write-Host "psql `"host=$($info.primary) port=5432 dbname=$Database user=$($info.admin) sslmode=require`""
Write-Host "`nReader psql command (prompts for password):" -ForegroundColor Cyan
Write-Host "psql `"host=$readerEndpoint port=5432 dbname=$Database user=$($info.admin) sslmode=require`""
