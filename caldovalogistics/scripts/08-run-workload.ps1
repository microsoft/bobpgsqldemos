<#
.SYNOPSIS
    Generate a recognizable mixed Caldova workload for the PostgreSQL dashboard.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 300)]
    [int]$DurationSeconds = 90,
    [ValidateRange(1, 200)]
    [int]$ClientsPerLane = 10,
    [ValidateRange(1, 64)]
    [int]$ThreadsPerLane = 2,
    [ValidateRange(1, 30)]
    [int]$ProgressSeconds = 5
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot '.caldova-connection.json'
$workloadRoot = Join-Path $projectRoot 'demo5-observability\pgbench'

if (-not (Test-Path $configPath)) {
    throw 'Run scripts/00-preflight.ps1 first.'
}
if ($ThreadsPerLane -gt $ClientsPerLane) {
    throw 'ThreadsPerLane cannot exceed ClientsPerLane.'
}

$pgbench = Get-Command pgbench -ErrorAction SilentlyContinue
$pgbenchPath = if ($pgbench) {
    $pgbench.Source
}
else {
    Get-ChildItem 'C:\Program Files\PostgreSQL' `
        -Filter pgbench.exe `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $pgbenchPath) {
    throw 'pgbench 17+ is required. Install PostgreSQL 17 Command Line Tools.'
}

$config = Get-Content -Raw $configPath | ConvertFrom-Json
$lanes = @(
    @{ Name = 'caldova-demo5-reader-tracking'; Host = $config.readerHost; Script = 'reader-tracking.sql' }
    @{ Name = 'caldova-demo5-reader-guidance'; Host = $config.readerHost; Script = 'reader-guidance.sql' }
    @{ Name = 'caldova-demo5-primary-control'; Host = $config.primaryHost; Script = 'primary-control.sql' }
    @{ Name = 'caldova-demo5-primary-writer'; Host = $config.primaryHost; Script = 'primary-temp-write.sql' }
)

$plainPassword = & "$PSScriptRoot\Get-CaldovaDatabasePassword.ps1" `
    -ProjectRoot $projectRoot

try {
    $env:PGPASSWORD = $plainPassword
    $env:PGSSLMODE = $config.sslMode
    $processes = foreach ($lane in $lanes) {
        $env:PGAPPNAME = $lane.Name
        $arguments = @(
            '-h', $lane.Host,
            '-p', '5432',
            '-U', $config.user,
            '-d', $config.database,
            '-n',
            '--exit-on-abort',
            '-c', $ClientsPerLane,
            '-j', $ThreadsPerLane,
            '-T', $DurationSeconds,
            '-P', $ProgressSeconds,
            '-f', (Join-Path $workloadRoot $lane.Script)
        )
        Write-Host ("Starting {0} -> {1}" -f $lane.Name, $lane.Host) -ForegroundColor Cyan
        Start-Process `
            -FilePath $pgbenchPath `
            -ArgumentList $arguments `
            -NoNewWindow `
            -PassThru
    }

    $processes | Wait-Process
    $failed = @($processes | Where-Object ExitCode -ne 0)
    if ($failed.Count -gt 0) {
        throw "One or more pgbench lanes failed: $($failed.Id -join ', ')"
    }
    Write-Host ("Demo 5 complete: {0} lanes, {1} clients, {2} seconds." -f $lanes.Count, ($lanes.Count * $ClientsPerLane), $DurationSeconds) -ForegroundColor Green
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
    Remove-Item Env:PGAPPNAME -ErrorAction SilentlyContinue
    $plainPassword = $null
}
