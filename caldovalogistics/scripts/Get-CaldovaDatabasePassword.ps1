param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,
    [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
    [string]$CredentialName = 'CALDOVA_DATABASE_PASSWORD',
    [string]$Prompt = 'Database password'
)

$passwordFile = Join-Path $ProjectRoot 'pwd.env'
if (Test-Path $passwordFile) {
    $passwordLine = Get-Content -Path $passwordFile |
        Where-Object { $_ -match "^\s*$([regex]::Escape($CredentialName))=" } |
        Select-Object -Last 1
    if (-not $passwordLine) {
        throw "'$passwordFile' must contain $CredentialName=<password>."
    }

    $password = ($passwordLine -split '=', 2)[1]
    if ([string]::IsNullOrEmpty($password)) {
        throw "$CredentialName is empty in '$passwordFile'."
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