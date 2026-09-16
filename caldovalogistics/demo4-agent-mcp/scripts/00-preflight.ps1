<#
.SYNOPSIS
    Check, configure, and verify the governed PostgreSQL MCP demo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$pythonPath = Join-Path $kitRoot '.venv\Scripts\python.exe'
$helperPath = Join-Path $PSScriptRoot 'Invoke-Demo4Security.py'
$sqlPath = Join-Path $demoRoot 'sql\01-agent-api.sql'

function Sync-FunctionAgentCredential {
    param([Parameter(Mandatory)][string]$Password)

    $functionName = az resource list `
        --resource-group caldova-logistics-rg `
        --resource-type Microsoft.Web/sites `
        --query "[?tags.workload=='caldova-agent-mcp'] | [0].name" `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($functionName)) {
        return
    }

    $subscriptionId = az account show --query id --output tsv
    $token = az account get-access-token `
        --resource https://management.azure.com `
        --query accessToken `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $subscriptionId -or -not $token) {
        throw 'Failed to acquire an ARM token for Function credential synchronization.'
    }

    $headers = @{ Authorization = "Bearer $token" }
    $base = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/caldova-logistics-rg/providers/Microsoft.Web/sites/$functionName/config/appsettings"
    $settings = Invoke-RestMethod `
        -Method Post `
        -Uri "${base}/list?api-version=2024-04-01" `
        -Headers $headers
    $settings.properties | Add-Member `
        -NotePropertyName CALDOVA_AGENT_DATABASE_PASSWORD `
        -NotePropertyValue $Password `
        -Force
    $body = @{ properties = $settings.properties } | ConvertTo-Json -Depth 10
    [void](Invoke-RestMethod `
        -Method Put `
        -Uri "${base}?api-version=2024-04-01" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $body)
    Write-Host "Synchronized the encrypted agent credential for $functionName." -ForegroundColor Green
}

if (-not (Test-Path $configPath) -or -not (Test-Path $pythonPath)) {
    throw 'Run the parent Caldova scripts/00-preflight.ps1 first.'
}

$passwordHelper = Join-Path $kitRoot 'scripts\Get-CaldovaDatabasePassword.ps1'
$adminPassword = & $passwordHelper `
    -ProjectRoot $kitRoot `
    -Prompt 'HorizonDB administrator password'
$agentPassword = & $passwordHelper `
    -ProjectRoot $kitRoot `
    -CredentialName 'CALDOVA_AGENT_PASSWORD' `
    -Prompt 'Set password for caldova_agent'

try {
    $env:CALDOVA_DATABASE_PASSWORD = $adminPassword
    $env:CALDOVA_AGENT_PASSWORD = $agentPassword
    & $pythonPath $helperPath setup --config $configPath --script $sqlPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to configure the Demo 4 agent API.' }
    $statusJson = & $pythonPath $helperPath verify --config $configPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to verify the Demo 4 agent API.' }
    $status = $statusJson | ConvertFrom-Json
    @(
        [pscustomobject]@{ Check = 'Agent login'; Passed = $status.agent_role -eq 'caldova_agent'; Value = $status.agent_role }
        [pscustomobject]@{ Check = 'Incident view'; Passed = $status.incident_rows -ge 1; Value = $status.incident_rows }
        [pscustomobject]@{ Check = 'Candidate facility view'; Passed = $status.candidate_facilities -ge 1; Value = $status.candidate_facilities }
        [pscustomobject]@{ Check = 'Handling guide view'; Passed = $status.handling_guides -ge 1; Value = $status.handling_guides }
        [pscustomobject]@{ Check = 'Recovery plan view'; Passed = $status.recovery_plans -ge 0; Value = $status.recovery_plans }
        [pscustomobject]@{ Check = 'Direct table read denied'; Passed = $status.direct_table_read_denied; Value = $status.direct_table_read_denied }
        [pscustomobject]@{ Check = 'Direct table write denied'; Passed = $status.direct_table_write_denied; Value = $status.direct_table_write_denied }
        [pscustomobject]@{ Check = 'Can propose plan'; Passed = $status.can_propose; Value = $status.can_propose }
        [pscustomobject]@{ Check = 'Can execute approved plan'; Passed = $status.can_execute; Value = $status.can_execute }
        [pscustomobject]@{ Check = 'Cannot approve own plan'; Passed = -not $status.can_approve; Value = $status.can_approve }
    ) | Format-Table -AutoSize
    if (-not $status.ready) { throw 'Demo 4 permission verification did not pass.' }
    Sync-FunctionAgentCredential -Password $agentPassword
    Write-Host 'Demo 4 database security is ready.' -ForegroundColor Green
    Write-Host 'The remote MCP server can now be deployed with 01-deploy-remote-mcp.ps1.' -ForegroundColor Cyan
}
finally {
    Remove-Item Env:CALDOVA_DATABASE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:CALDOVA_AGENT_PASSWORD -ErrorAction SilentlyContinue
    $adminPassword = $null
    $agentPassword = $null
}
