<#
.SYNOPSIS
    Deploy the Azure HorizonDB cluster for Caldova Logistics.

.DESCRIPTION
    Creates a resource group and PostgreSQL 17 HorizonDB cluster with one
    readable replica. The replica supplies read scale and an HA failover target.
    The administrator password is prompted securely and is never written to disk.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Location = 'westus3',
    [string]$AdminLogin = 'caldovaadmin',
    [int]$VCores = 2,
    [int]$ReplicaCount = 1,
    [ValidateSet('BestEffort', 'Strict')]
    [string]$ZonePlacementPolicy = 'BestEffort'
)

$ErrorActionPreference = 'Stop'

$context = az account show `
    --subscription $Subscription `
    --query '{name:name,id:id,user:user.name}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Sign in with az login before running this script.' }

Write-Host '=== Caldova Logistics: deploy HorizonDB ===' -ForegroundColor Cyan
Write-Host "Subscription   : $($context.name) ($($context.id))" -ForegroundColor Yellow
Write-Host "Signed in as   : $($context.user)" -ForegroundColor Yellow
Write-Host "Resource group : $ResourceGroup"
Write-Host "Cluster        : $ClusterName"
Write-Host "Location       : $Location"
Write-Host "Compute        : $VCores vCores, $ReplicaCount readable replica(s)"

$securePassword = Read-Host -Prompt 'Admin password (8-128 chars; upper, lower, number, special)' -AsSecureString
$passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

try {
    az group create `
        --subscription $context.id `
        --name $ResourceGroup `
        --location $Location `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group '$ResourceGroup'." }

    az horizondb create `
        --subscription $context.id `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --location $Location `
        --version 17 `
        --administrator-login $AdminLogin `
        --administrator-login-password $plainPassword `
        --v-cores $VCores `
        --replica-count $ReplicaCount `
        --zone-placement-policy $ZonePlacementPolicy `
        --yes `
        --output table
    if ($LASTEXITCODE -ne 0) { throw "Failed to create HorizonDB cluster '$ClusterName'." }
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    $plainPassword = $null
}

Write-Host "`nCluster deployed. Run 02-add-firewall-rule.ps1 next." -ForegroundColor Green
