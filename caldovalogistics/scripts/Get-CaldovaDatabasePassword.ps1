param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,
    [string]$Prompt = 'Database password'
)

$passwordFile = Join-Path $ProjectRoot 'pwd.env'
if (Test-Path $passwordFile) {
    $passwordLine = Get-Content -Path $passwordFile |
        Where-Object { $_ -match '^\s*CALDOVA_DATABASE_PASSWORD=' } |
        Select-Object -Last 1
    if (-not $passwordLine) {
        throw "'$passwordFile' must contain CALDOVA_DATABASE_PASSWORD=<password>."
    }

    $password = ($passwordLine -split '=', 2)[1]
    if ([string]::IsNullOrEmpty($password)) {
        throw "CALDOVA_DATABASE_PASSWORD is empty in '$passwordFile'."
    }
    return $password
}

$securePassword = Read-Host -Prompt $Prompt -AsSecureString
$passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}