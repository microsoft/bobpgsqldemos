<#
.SYNOPSIS
    Check and prepare everything required for the Caldova HorizonDB demos.
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
    [string]$ZonePlacementPolicy = 'BestEffort',
    [string]$IPAddress,
    [switch]$ApproveProvisioning,
    [switch]$ApproveQueryStatsRestart,
    [switch]$ResetDatabase
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$connectionConfigPath = Join-Path $projectRoot '.caldova-connection.json'
$pythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'
$databaseTool = Join-Path $PSScriptRoot 'Invoke-CaldovaDatabase.py'
$queryStatsParameterGroupName = 'caldova-observability-tracking-pg17'
$workloadScript = Join-Path $PSScriptRoot '08-run-workload.ps1'
$workloadRoot = Join-Path $projectRoot 'demo5-observability\pgbench'
$workloadFiles = @(
    'reader-tracking.sql',
    'reader-guidance.sql',
    'primary-control.sql',
    'primary-temp-write.sql'
)

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it, run az login, and rerun preflight.'
}

az extension show --name horizondb --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing the Azure CLI HorizonDB preview extension...' -ForegroundColor Yellow
    az extension add --name horizondb --allow-preview true --yes
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install the HorizonDB Azure CLI extension.' }
}

if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
    -not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw 'Python 3.11 or later is required. Install Python, reopen the terminal, and rerun preflight.'
}

$pgbenchCommand = Get-Command pgbench -ErrorAction SilentlyContinue
$pgbenchPath = if ($pgbenchCommand) {
    $pgbenchCommand.Source
}
else {
    Get-ChildItem 'C:\Program Files\PostgreSQL' `
        -Filter pgbench.exe `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $pgbenchPath) {
    throw 'Demo 5 requires pgbench 17 or later. Install the PostgreSQL 17 Command Line Tools and rerun preflight.'
}
$pgbenchVersion = & $pgbenchPath --version
if ($LASTEXITCODE -ne 0 -or $pgbenchVersion -notmatch 'pgbench \(PostgreSQL\) (\d+)') {
    throw "Could not determine the pgbench version from '$pgbenchPath'."
}
if ([int]$Matches[1] -lt 17) {
    throw "Demo 5 requires pgbench 17 or later; found $pgbenchVersion."
}
$missingWorkloadFiles = @(
    if (-not (Test-Path $workloadScript)) { $workloadScript }
    foreach ($fileName in $workloadFiles) {
        $filePath = Join-Path $workloadRoot $fileName
        if (-not (Test-Path $filePath)) { $filePath }
    }
)
if ($missingWorkloadFiles.Count -gt 0) {
    throw "Demo 5 workload files are missing: $($missingWorkloadFiles -join ', ')"
}

$codeCommand = Get-Command code -ErrorAction SilentlyContinue
if ($codeCommand) {
    $pgsqlExtensionInstalled = code --list-extensions | Where-Object { $_ -eq 'ms-ossdata.vscode-pgsql' }
    if (-not $pgsqlExtensionInstalled) {
        Write-Host 'Installing the Microsoft PostgreSQL extension for VS Code...' -ForegroundColor Yellow
        code --install-extension ms-ossdata.vscode-pgsql --force
        if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Microsoft PostgreSQL extension.' }
    }
}
else {
    Write-Warning 'VS Code command-line launcher was not found. Install ms-ossdata.vscode-pgsql manually for the MCP demo.'
}

& "$PSScriptRoot\Test-AzurePrerequisites.ps1" `
    -Subscription $Subscription `
    -ResourceGroup $ResourceGroup `
    -ClusterName $ClusterName `
    -Location $Location

$clusterId = az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query id `
    --output tsv `
    --only-show-errors 2>$null
$clusterExists = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($clusterId)
if (-not $clusterExists) {
    if (-not $ApproveProvisioning) {
        throw "Cluster '$ClusterName' is missing. Re-run with -ApproveProvisioning to create billable Azure resources."
    }
    & "$PSScriptRoot\01-deploy-cluster.ps1" `
        -Subscription $Subscription `
        -ResourceGroup $ResourceGroup `
        -ClusterName $ClusterName `
        -Location $Location `
        -AdminLogin $AdminLogin `
        -VCores $VCores `
        -ReplicaCount $ReplicaCount `
        -ZonePlacementPolicy $ZonePlacementPolicy
}

$firewallArguments = @{
    Subscription = $Subscription
    ResourceGroup = $ResourceGroup
    ClusterName = $ClusterName
    AllowAzureServicesForMcp = $true
}
if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
    $firewallArguments.IPAddress = $IPAddress
}
& "$PSScriptRoot\02-add-firewall-rule.ps1" @firewallArguments
& "$PSScriptRoot\07-verify-cluster.ps1" `
    -Subscription $Subscription `
    -ResourceGroup $ResourceGroup `
    -ClusterName $ClusterName

$cluster = az horizondb show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --query '{primary:properties.fullyQualifiedDomainName,reader:properties.readonlyEndpoint,admin:properties.administratorLogin,state:properties.provisioningState,replicas:properties.replicaCount,parameterGroup:properties.parameterGroup}' `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $cluster) { throw "Failed to read cluster '$ClusterName'." }

$queryStatsParameterGroup = az horizondb parameter-group show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $queryStatsParameterGroupName `
    --output json `
    --only-show-errors 2>$null | ConvertFrom-Json
$queryStatsParameterGroupExists = $LASTEXITCODE -eq 0 -and $queryStatsParameterGroup
$queryStatsParameterGroupAttached = $queryStatsParameterGroupExists -and
    $cluster.parameterGroup.id -eq $queryStatsParameterGroup.id

if (-not $queryStatsParameterGroupAttached) {
    if (-not $ApproveQueryStatsRestart) {
        throw "Demo 5 query analysis requires pg_stat_statements and a cluster restart. Re-run preflight with -ApproveQueryStatsRestart to create and attach '$queryStatsParameterGroupName'."
    }
    if (-not $queryStatsParameterGroupExists) {
        az horizondb parameter-group create `
            --subscription $Subscription `
            --resource-group $ResourceGroup `
            --name $queryStatsParameterGroupName `
            --location $Location `
            --version 17 `
            --parameters `
                'azure.extensions=azure_ai,pg_diskann,pg_durable,pg_stat_statements,vector' `
                'shared_preload_libraries=pg_durable,pg_stat_statements' `
                'pg_stat_statements.track=all' `
            --apply-immediately true `
            --description 'Caldova AI pipeline and dashboard query tracking' `
            --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to create parameter group '$queryStatsParameterGroupName'." }
        $queryStatsParameterGroup = az horizondb parameter-group show `
            --subscription $Subscription `
            --resource-group $ResourceGroup `
            --name $queryStatsParameterGroupName `
            --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $queryStatsParameterGroup) {
            throw "Failed to read parameter group '$queryStatsParameterGroupName' after creation."
        }
    }
    az horizondb update `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --parameter-group $queryStatsParameterGroup.id `
        --yes `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to attach parameter group '$queryStatsParameterGroupName'." }

    $cluster = az horizondb show `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --query '{primary:properties.fullyQualifiedDomainName,reader:properties.readonlyEndpoint,admin:properties.administratorLogin,state:properties.provisioningState,replicas:properties.replicaCount,parameterGroup:properties.parameterGroup}' `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $cluster.state -ne 'Succeeded' -or $cluster.parameterGroup.syncStatus -ne 'InSync') {
        throw "Cluster '$ClusterName' did not return ready with query statistics enabled."
    }
}

@{
    primaryHost = $cluster.primary
    readerHost = $cluster.reader
    database = 'postgres'
    user = $cluster.admin
    sslMode = 'require'
} | ConvertTo-Json | Set-Content -Path $connectionConfigPath -Encoding utf8

if (-not (Test-Path $pythonPath)) {
    & "$PSScriptRoot\04-install-app.ps1"
}

$plainPassword = & "$PSScriptRoot\Get-CaldovaDatabasePassword.ps1" `
    -ProjectRoot $projectRoot `
    -Prompt "Password for $($cluster.admin)"

try {
    $env:CALDOVA_DATABASE_PASSWORD = $plainPassword
    $statusJson = & $pythonPath $databaseTool status --config $connectionConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'Database connectivity or status check failed.' }
    $status = $statusJson | ConvertFrom-Json

    if (-not $status.query_stats_ready) {
        & $pythonPath $databaseTool ensure-query-stats --config $connectionConfigPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create pg_stat_statements in the postgres database.' }
        $statusJson = & $pythonPath $databaseTool status --config $connectionConfigPath
        if ($LASTEXITCODE -ne 0) { throw 'Database verification failed after enabling query statistics.' }
        $status = $statusJson | ConvertFrom-Json
    }

    if (-not $status.base_schema_ready -or $ResetDatabase) {
        if ($status.base_schema_present -and -not $ResetDatabase) {
            throw 'The base schema exists but is incomplete. Re-run with -ResetDatabase after reviewing sql/00-schema-and-seed.sql.'
        }
        & $pythonPath $databaseTool deploy `
            --config $connectionConfigPath `
            --script (Join-Path $projectRoot 'sql\00-schema-and-seed.sql')
        if ($LASTEXITCODE -ne 0) { throw 'Base schema deployment failed.' }
        $statusJson = & $pythonPath $databaseTool status --config $connectionConfigPath
        if ($LASTEXITCODE -ne 0) { throw 'Database verification failed after deployment.' }
        $status = $statusJson | ConvertFrom-Json
    }

    & "$PSScriptRoot\06-test-app.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'Application tests failed.' }

    Write-Host "`n=== Caldova demo readiness ===" -ForegroundColor Cyan
    $readerEndpointIsDistinct = -not [string]::IsNullOrWhiteSpace($cluster.reader) -and
        $cluster.reader -ne $cluster.primary
    @(
        [pscustomobject]@{ Demo = '1 - PostgreSQL baseline'; Ready = $status.base_schema_ready; Evidence = $status.base_summary }
        [pscustomobject]@{ Demo = '2 - Scale and HA'; Ready = [int]$cluster.replicas -ge 1 -and $readerEndpointIsDistinct; Evidence = "reader=$($cluster.reader); replicas=$($cluster.replicas); distinct-endpoint=$readerEndpointIsDistinct" }
        [pscustomobject]@{ Demo = '3 - Grounded AI'; Ready = $status.ai_ready; Evidence = $status.ai_summary }
        [pscustomobject]@{ Demo = '4 - Agent and MCP'; Ready = $false; Evidence = 'Create saved Caldova Reader profile; PostgreSQL MCP registration is host-managed' }
        [pscustomobject]@{ Demo = '5 - Production prototype'; Ready = $status.query_stats_ready; Evidence = "$pgbenchVersion; four workload lanes present; pg_stat_statements=$($status.query_stats_ready); app tests pass" }
    ) | Format-Table -AutoSize -Wrap

    if (-not $status.ai_ready) {
        Write-Warning 'AI Model Management is not ready. It is a limited preview that requires approval and must be enabled in the HorizonDB portal before the AI SQL script can complete.'
    }
}
finally {
    Remove-Item Env:CALDOVA_DATABASE_PASSWORD -ErrorAction SilentlyContinue
    $plainPassword = $null
}


