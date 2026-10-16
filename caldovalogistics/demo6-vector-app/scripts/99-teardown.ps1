<#
.SYNOPSIS
    Remove the Knowledge Hub database objects and, optionally, the App Service app.
.DESCRIPTION
    Cancels the pg_durable reconciler, pauses and drops knowledge-hub-pipeline,
    drops the knowledge_hub schema and knowledge_hub_app role. Other Caldova
    demos are not touched. Use -AppName to also delete the web app and its plan.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$AppName,
    [string]$Subscription = 'AzureSQL_bobward',
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$PlanName
)

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$pythonPath = Join-Path $kitRoot '.venv\Scripts\python.exe'

if ($PSCmdlet.ShouldProcess('knowledge_hub schema, pipeline, reconciler, and role', 'Drop')) {
    $env:CALDOVA_DATABASE_PASSWORD = & "$kitRoot\scripts\Get-CaldovaDatabasePassword.ps1" -ProjectRoot $kitRoot -Prompt 'HorizonDB admin password'
    try {
        & $pythonPath (Join-Path $PSScriptRoot 'Invoke-KnowledgeHub.py') teardown --config $configPath
        if ($LASTEXITCODE -ne 0) { throw 'Knowledge Hub database teardown failed.' }
    }
    finally {
        Remove-Item Env:\CALDOVA_DATABASE_PASSWORD -ErrorAction SilentlyContinue
    }
}

if ($AppName -and $PSCmdlet.ShouldProcess("$AppName and its plan", 'Delete App Service resources')) {
    if (-not $PlanName) { $PlanName = "$AppName-plan" }
    az webapp delete --subscription $Subscription --resource-group $ResourceGroup --name $AppName --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete web app $AppName." }
    az appservice plan delete --subscription $Subscription --resource-group $ResourceGroup --name $PlanName --yes --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete plan $PlanName." }
}
