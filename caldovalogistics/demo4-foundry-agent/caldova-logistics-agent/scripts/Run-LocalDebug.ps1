<#
.SYNOPSIS
    Start the Caldova Foundry Hosted Agent locally under debugpy.
#>
[CmdletBinding()]
param(
    [int]$DebugPort = 5679
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content (Join-Path $projectRoot '.azure\config.json') -Raw | ConvertFrom-Json
$envFile = Join-Path $projectRoot ".azure\$($config.defaultEnvironment)\.env"
$repositoryRoot = git -C $projectRoot rev-parse --show-toplevel
$pythonPath = Join-Path $repositoryRoot '.venv-caldova-hosted-agent\Scripts\python.exe'
$entryPoint = Join-Path $projectRoot 'src\agent-framework-agent-basic-responses\main.py'

if (-not (Test-Path $pythonPath)) {
    throw "Hosted Agent Python environment was not found at $pythonPath."
}
if (-not (Test-Path $envFile)) {
    throw "Selected azd environment file was not found at $envFile."
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') {
        $name = $matches[1]
        $value = $matches[2].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

& $pythonPath -m debugpy --listen "127.0.0.1:$DebugPort" $entryPoint
exit $LASTEXITCODE
