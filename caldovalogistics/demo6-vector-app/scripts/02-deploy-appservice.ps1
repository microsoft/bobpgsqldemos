<#
.SYNOPSIS
    Deploy the Caldova Knowledge Hub to Azure App Service (Linux, Python).
.DESCRIPTION
    Creates the resource group, App Service plan (Linux P0v3), and web app
    (PYTHON:3.14) when missing, configures the least-privilege HorizonDB
    connection, enables the Oryx build, sets the uvicorn startup command, and
    zip-deploys src/. Creating the plan and web app is billable.

    The app has no sign-in and can edit articles and make billed embedding
    calls, so by default only -AllowedIpAddress (your current public IP) can
    reach it. Re-run with a new address when your network changes, or use
    -AllowPublicAccess to remove the restriction.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{1,38}[a-z0-9]$')]
    [string]$AppName,
    [string]$Subscription = 'AzureSQL_bobward',
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Location = 'westus3',
    [string]$PlanName,
    [string]$Sku = 'P0v3',
    [string]$Runtime = 'PYTHON:3.14',
    [string]$AllowedIpAddress,
    [switch]$AllowPublicAccess
)

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
if (-not $PlanName) { $PlanName = "$AppName-plan" }
if (-not (Test-Path $configPath)) { throw 'Run the parent Caldova scripts/00-preflight.ps1 first.' }

function Invoke-Az {
    $output = & az @args --subscription $Subscription --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed." }
    return $output
}

function Test-AzResource {
    # Windows PowerShell 5.1 turns redirected native stderr into a terminating
    # error under 'Stop'; a missing resource must return $false instead.
    $ErrorActionPreference = 'Continue'
    & az @args --subscription $Subscription --only-show-errors --output none 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function New-ZipPackage {
    param([string]$SourceDirectory, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $root = (Resolve-Path $SourceDirectory).Path.TrimEnd('\', '/')
    $archive = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -Path $root -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](__pycache__|\.pytest_cache)[\\/]' -and $_.Extension -ne '.pyc' } |
            ForEach-Object {
                # Linux App Service needs '/' separators inside the zip.
                $entryName = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entryName) | Out-Null
            }
    }
    finally {
        $archive.Dispose()
    }
}

$azureRule = Invoke-Az horizondb firewall-rule list --resource-group $ResourceGroup --cluster-name $ClusterName `
    --query "[?properties.startIpAddress=='0.0.0.0' && properties.endIpAddress=='0.0.0.0'] | length(@)" --output tsv
if ($azureRule -ne '1') {
    throw "HorizonDB firewall has no Azure-services rule. Run scripts/02-add-firewall-rule.ps1 -Subscription '$Subscription' -AllowAzureServicesForMcp."
}

if (-not $AllowPublicAccess -and -not $AllowedIpAddress) {
    $AllowedIpAddress = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
}
if (-not $AllowPublicAccess -and $AllowedIpAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "AllowedIpAddress '$AllowedIpAddress' is not a valid IPv4 address."
}

Write-Host "Deploying $AppName (plan $PlanName, $Sku Linux, $Runtime) to $ResourceGroup in $Location." -ForegroundColor Cyan

if (-not (Test-AzResource group show --name $ResourceGroup)) {
    Invoke-Az group create --name $ResourceGroup --location $Location --output none
}
if (-not (Test-AzResource appservice plan show --name $PlanName --resource-group $ResourceGroup)) {
    Invoke-Az appservice plan create --name $PlanName --resource-group $ResourceGroup --location $Location --is-linux --sku $Sku --output none
}
if (-not (Test-AzResource webapp show --name $AppName --resource-group $ResourceGroup)) {
    Invoke-Az webapp create --name $AppName --resource-group $ResourceGroup --plan $PlanName --runtime $Runtime --https-only true --output none
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$appPassword = & "$kitRoot\scripts\Get-CaldovaDatabasePassword.ps1" -ProjectRoot $kitRoot -CredentialName 'KNOWLEDGE_HUB_APP_PASSWORD' -Prompt 'knowledge_hub_app password'
try {
    Invoke-Az webapp config appsettings set --name $AppName --resource-group $ResourceGroup --output none --settings `
        "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
        "KNOWLEDGE_HUB_DATABASE_HOST=$($config.primaryHost)" `
        "KNOWLEDGE_HUB_READ_HOST=$($config.readerHost)" `
        "KNOWLEDGE_HUB_DATABASE_NAME=$($config.database)" `
        "KNOWLEDGE_HUB_DATABASE_USER=knowledge_hub_app" `
        "KNOWLEDGE_HUB_DATABASE_PASSWORD=$appPassword" | Out-Null
}
finally {
    $appPassword = $null
}

Invoke-Az webapp config set --name $AppName --resource-group $ResourceGroup --output none `
    --startup-file 'python -m uvicorn main:app --host 0.0.0.0' `
    --always-on true --ftps-state Disabled --min-tls-version 1.2 | Out-Null

$existingRule = Invoke-Az webapp config access-restriction show --name $AppName --resource-group $ResourceGroup `
    --query "ipSecurityRestrictions[?name=='presenter'] | length(@)" --output tsv
if ($existingRule -ne '0') {
    Invoke-Az webapp config access-restriction remove --name $AppName --resource-group $ResourceGroup --rule-name presenter --output none | Out-Null
}
if (-not $AllowPublicAccess) {
    Invoke-Az webapp config access-restriction add --name $AppName --resource-group $ResourceGroup --rule-name presenter `
        --action Allow --ip-address "$AllowedIpAddress/32" --priority 100 --output none | Out-Null
    Write-Host "Access restricted to $AllowedIpAddress." -ForegroundColor Yellow
}
else {
    Write-Warning 'The app is publicly reachable without sign-in.'
}

$package = Join-Path ([System.IO.Path]::GetTempPath()) "knowledge-hub-$([guid]::NewGuid().ToString('N')).zip"
try {
    New-ZipPackage -SourceDirectory (Join-Path $demoRoot 'src') -Destination $package
    Invoke-Az webapp deploy --name $AppName --resource-group $ResourceGroup --src-path $package --type zip --track-status false --output none | Out-Null
}
finally {
    Remove-Item -Force $package -ErrorAction SilentlyContinue
}

$hostName = Invoke-Az webapp show --name $AppName --resource-group $ResourceGroup --query defaultHostName --output tsv
Write-Host "Deployed https://$hostName" -ForegroundColor Green
