<#
.SYNOPSIS
    Check, build, and verify the native HorizonDB AI pipeline demo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,
    [string]$ResourceGroup = 'caldova-logistics-rg',
    [string]$ClusterName = 'caldova-logistics',
    [string]$Location = 'westus3',
    [string]$FoundryAccount = 'caldova-logistics-ai',
    [string]$EmbeddingDeployment = 'caldova-embedding',
    [switch]$ApproveProvisioning,
    [switch]$ApproveClusterRestart
)

$ErrorActionPreference = 'Stop'
$demoRoot = Split-Path -Parent $PSScriptRoot
$kitRoot = Split-Path -Parent $demoRoot
$configPath = Join-Path $kitRoot '.caldova-connection.json'
$pythonPath = Join-Path $kitRoot '.venv\Scripts\python.exe'
$helperPath = Join-Path $PSScriptRoot 'Invoke-Demo3Pipeline.py'
$pipelineSql = Join-Path $demoRoot 'sql\01-create-pipeline.sql'

if (-not (Test-Path $configPath) -or -not (Test-Path $pythonPath)) {
    throw 'Run the parent Caldova scripts/00-preflight.ps1 first.'
}

$accountExists = az cognitiveservices account show `
    --subscription $Subscription `
    --resource-group $ResourceGroup `
    --name $FoundryAccount `
    --query id `
    --output tsv `
    --only-show-errors 2>$null
$deploymentExists = $false
if ($LASTEXITCODE -eq 0 -and $accountExists) {
    $deploymentExists = [bool](az cognitiveservices account deployment show `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $FoundryAccount `
        --deployment-name $EmbeddingDeployment `
        --query name `
        --output tsv `
        --only-show-errors 2>$null)
}

if ((-not $accountExists -or -not $deploymentExists) -and -not $ApproveProvisioning) {
    throw 'Foundry resource or embedding deployment is missing. Re-run with -ApproveProvisioning.'
}
if (-not $accountExists -or -not $deploymentExists) {
    & "$PSScriptRoot\01-provision-foundry.ps1" `
        -Subscription $Subscription `
        -ResourceGroup $ResourceGroup `
        -Location $Location `
        -AccountName $FoundryAccount `
        -DeploymentName $EmbeddingDeployment
}

$securePassword = Read-Host -Prompt 'HorizonDB password' -AsSecureString
$passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

try {
    $env:CALDOVA_DATABASE_PASSWORD = $plainPassword
    $settings = (& $pythonPath $helperPath settings --config $configPath) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect HorizonDB extension settings.' }

    $existingExtensions = @($settings.azure_extensions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $allowedExtensions = @($existingExtensions + @('vector', 'pg_diskann', 'azure_ai', 'pg_durable') | Sort-Object -Unique) -join ','
    $configurablePreloadLibraries = @(
        'age', 'auto_explain', 'azure_storage', 'pg_cron', 'pg_durable',
        'pg_partman_bgw', 'pg_prewarm', 'pg_stat_statements', 'pg_textsearch',
        'pgaudit', 'wal2json'
    )
    $existingLibraries = @($settings.shared_preload_libraries -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $preloadLibraries = @(
        $existingLibraries | Where-Object { $_ -in $configurablePreloadLibraries }
    ) + 'pg_durable' | Sort-Object -Unique
    $preloadLibraries = $preloadLibraries -join ','

    $currentParameterGroup = az horizondb show `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --query properties.parameterGroup.id `
        --output tsv
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect the HorizonDB parameter group.' }
    if ($currentParameterGroup -notmatch '/caldova-ai-pipeline-pg17$') {
        if (-not $ApproveClusterRestart) {
            throw 'The AI pipeline parameter group is not attached. Re-run with -ApproveClusterRestart.'
        }
        & "$PSScriptRoot\02-enable-horizondb-extensions.ps1" `
            -Subscription $Subscription `
            -ResourceGroup $ResourceGroup `
            -ClusterName $ClusterName `
            -Location $Location `
            -AllowedExtensions $allowedExtensions `
            -SharedPreloadLibraries $preloadLibraries
    }

    $endpoint = "https://$FoundryAccount.openai.azure.com/"
    $foundryKey = az cognitiveservices account keys list `
        --subscription $Subscription `
        --resource-group $ResourceGroup `
        --name $FoundryAccount `
        --query key1 `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($foundryKey)) {
        throw 'Failed to retrieve the Foundry key.'
    }
    $env:CALDOVA_FOUNDRY_ENDPOINT = $endpoint
    $env:CALDOVA_FOUNDRY_KEY = $foundryKey
    $env:CALDOVA_EMBEDDING_DEPLOYMENT = $EmbeddingDeployment

    & $pythonPath $helperPath setup --config $configPath --script $pipelineSql
    if ($LASTEXITCODE -ne 0) { throw 'Failed to configure or run the native AI pipeline.' }
    $statusJson = & $pythonPath $helperPath status --config $configPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to verify the native AI pipeline.' }
    $status = $statusJson | ConvertFrom-Json
    $pipelineStatus = @($status.pipeline_status)[0]
    @(
        [pscustomobject]@{ Check = 'Required extensions'; Passed = $status.extensions_ready; Value = $status.installed_extensions -join ', ' }
        [pscustomobject]@{ Check = 'Embedding model registry'; Passed = $status.model_registered; Value = 'caldova-embedding' }
        [pscustomobject]@{ Check = 'Pipeline run'; Passed = $pipelineStatus.last_run_status -eq 'completed'; Value = "$($pipelineStatus.last_run_status); processed=$($pipelineStatus.total_processed)" }
        [pscustomobject]@{ Check = 'Embedded chunks'; Passed = $status.chunks -eq $status.embeddings_written; Value = "$($status.embeddings_written)/$($status.chunks)" }
        [pscustomobject]@{ Check = 'Source guides'; Passed = $status.source_documents -eq 8; Value = $status.source_documents }
        [pscustomobject]@{ Check = 'DiskANN index'; Passed = $status.diskann_index; Value = 'operations_guide_chunk_diskann_idx' }
    ) | Format-Table -AutoSize
    if (-not $status.ready) { throw 'Demo 3 pipeline verification did not pass.' }
    Write-Host 'Demo 3 native AI pipeline is ready.' -ForegroundColor Green
}
finally {
    Remove-Item Env:CALDOVA_DATABASE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:CALDOVA_FOUNDRY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item Env:CALDOVA_FOUNDRY_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:CALDOVA_EMBEDDING_DEPLOYMENT -ErrorAction SilentlyContinue
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    $plainPassword = $null
    $foundryKey = $null
}
