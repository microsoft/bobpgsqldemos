<#
.SYNOPSIS
    Delete the Caldova Logistics resource group after explicit confirmation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [switch]$ConfirmDelete
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmDelete) {
    throw "Deletion not approved. Re-run with -ConfirmDelete to delete resource group '$ResourceGroup'."
}

az group delete --subscription $Subscription --name $ResourceGroup --yes
if ($LASTEXITCODE -ne 0) { throw "Failed to delete resource group '$ResourceGroup'." }
Write-Host "Deleted resource group '$ResourceGroup'." -ForegroundColor Green