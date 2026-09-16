<#
.SYNOPSIS
    Allow the current client IP to reach the Caldova HorizonDB cluster.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$RuleName,
    [string]$IPAddress,
    [switch]$AllowAzureServicesForMcp
)

$ErrorActionPreference = 'Stop'
$subscriptionId = az account show `
    --subscription $Subscription `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'Failed to read the Azure subscription context.'
}

$clusterId = az horizondb show `
    --subscription $subscriptionId `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clusterId)) {
    throw "HorizonDB cluster '$ClusterName' was not found."
}

if ([string]::IsNullOrWhiteSpace($IPAddress)) {
    $IPAddress = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
}
if ($IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "IPAddress '$IPAddress' is not a valid IPv4 address."
}
if ([string]::IsNullOrWhiteSpace($RuleName)) {
    $RuleName = "client-$($IPAddress.Replace('.', '-'))"
}

az horizondb firewall-rule create `
    --subscription $subscriptionId `
    --resource-group $ResourceGroup `
    --cluster-name $ClusterName `
    --name $RuleName `
    --start-ip-address $IPAddress `
    --end-ip-address $IPAddress `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create firewall rule '$RuleName'." }

Write-Host "Allowed $IPAddress through firewall rule '$RuleName'." -ForegroundColor Green

if ($AllowAzureServicesForMcp) {
    az horizondb firewall-rule create `
        --subscription $subscriptionId `
        --resource-group $ResourceGroup `
        --cluster-name $ClusterName `
        --name 'allow-azure-services' `
        --start-ip-address '0.0.0.0' `
        --end-ip-address '0.0.0.0' `
        --description 'Allow Azure-hosted PostgreSQL MCP connections' `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create firewall rule 'allow-azure-services'." }

    Write-Host "Allowed Azure-hosted services through firewall rule 'allow-azure-services'." -ForegroundColor Green
}
