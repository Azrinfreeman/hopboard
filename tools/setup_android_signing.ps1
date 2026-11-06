# Run interactively in your own PowerShell terminal. Never supply passwords in chat.
param(
    [string]$SigningDirectory = (Join-Path $env:LOCALAPPDATA 'Hopboard/Signing'),
    [string]$JavaHome = '',
    [string]$CertificateName = 'Azrinfreeman'
)
$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$signingPath = [System.IO.Path]::GetFullPath($SigningDirectory).TrimEnd('\')
if ($signingPath.Equals($workspace, [StringComparison]::OrdinalIgnoreCase) -or
    $signingPath.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a signing directory outside this repository.'
}
if (Test-Path -LiteralPath $signingPath) {
    throw 'SigningDirectory already exists. Nothing was changed. Use your existing key or select a new private directory.'
}
if (!$JavaHome) { $JavaHome = $env:JAVA_HOME }
if (!$JavaHome) { throw 'Pass -JavaHome with an installed JDK.' }
$keytool = Join-Path $JavaHome 'bin/keytool.exe'
if (!(Test-Path -LiteralPath $keytool)) { throw 'keytool.exe was not found in the selected JDK.' }
if ($CertificateName -notmatch '^[A-Za-z0-9 ._-]+$') {
    throw 'CertificateName must use letters, numbers, spaces, periods, underscores or hyphens.'
}

$password = Read-Host 'New release-keystore password (save it in your password manager)' -AsSecureString
$confirmation = Read-Host 'Confirm password' -AsSecureString
$passwordPointer = [IntPtr]::Zero
$confirmationPointer = [IntPtr]::Zero
$previousPassword = $env:HOPBOARD_NEW_KEY_PASSWORD
try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $confirmationPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    if ($plainPassword.Length -lt 6) { throw 'keytool requires at least six password characters. Choose a strong, unique password.' }
    if ($plainPassword -cne [Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmationPointer)) {
        throw 'Passwords do not match. No signing directory was created.'
    }
    # Create an ACL-protected directory before writing any private material.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner([Security.Principal.NTAccount]::new($identity))
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
    ))
    New-Item -ItemType Directory -Path $signingPath | Out-Null
    Set-Acl -LiteralPath $signingPath -AclObject $acl
    $keystore = Join-Path $signingPath 'hopboard-release.p12'
    $properties = Join-Path $signingPath 'key.properties'
    $certificate = Join-Path $signingPath 'release-certificate.der'
    $env:HOPBOARD_NEW_KEY_PASSWORD = $plainPassword
    & $keytool -genkeypair -keystore $keystore -storetype PKCS12 -alias hopboard-release `
        -storepass:env HOPBOARD_NEW_KEY_PASSWORD -keypass:env HOPBOARD_NEW_KEY_PASSWORD `
        -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$CertificateName"
    if ($LASTEXITCODE -ne 0) { throw 'Key generation failed. Inspect the private directory before retrying; never overwrite an existing key.' }
    & $keytool -exportcert -keystore $keystore -alias hopboard-release `
        -storepass:env HOPBOARD_NEW_KEY_PASSWORD -file $certificate
    if ($LASTEXITCODE -ne 0) { throw 'Public certificate export failed. Keep the generated keystore; do not generate a replacement.' }
    # Java Properties uses backslash escapes; preserve spaces and control characters.
    $propertyPassword = $plainPassword.Replace('\', '\\').Replace(' ', '\ ').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    $lines = @(
        "storeFile=$($keystore.Replace('\', '/'))", 'keyAlias=hopboard-release',
        "storePassword=$propertyPassword", "keyPassword=$propertyPassword"
    )
    # Properties.load(InputStream) uses ISO-8859-1; escape non-ASCII characters.
    $escaped = foreach ($line in $lines) {
        $buffer = New-Object System.Text.StringBuilder
        foreach ($character in $line.ToCharArray()) {
            if ([int]$character -gt 126) { [void]$buffer.Append(('\u{0:x4}' -f [int]$character)) }
            else { [void]$buffer.Append($character) }
        }
        $buffer.ToString()
    }
    Set-Content -LiteralPath $properties -Value $escaped -Encoding ascii
    $fingerprint = (Get-FileHash -LiteralPath $certificate -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $signingPath 'release-certificate.sha256') -Value $fingerprint -Encoding ascii
    if (!(Get-Acl -LiteralPath $signingPath).AreAccessRulesProtected) { throw 'Private directory access protection was not applied.' }
    Write-Output "Keystore created in $signingPath"
    Write-Output "Public certificate SHA-256: $fingerprint"
    Write-Output 'Back up the keystore securely in two locations; store the password separately.'
    Write-Output 'Set HOPBOARD_ANDROID_KEY_PROPERTIES to the key.properties path before building.'
} finally {
    $env:HOPBOARD_NEW_KEY_PASSWORD = $previousPassword
    $plainPassword = $null
    $propertyPassword = $null
    $lines = $null
    $escaped = $null
    if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    if ($confirmationPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmationPointer) }
    $password.Dispose()
    $confirmation.Dispose()
}
