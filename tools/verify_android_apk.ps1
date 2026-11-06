param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [Parameter(Mandatory = $true)][string]$ExpectedSignerSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedVersionName,
    [Parameter(Mandatory = $true)][int]$ExpectedVersionCode,
    [string]$AndroidSdk = '',
    [string]$JavaHome = ''
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$previousJava = $env:JAVA_HOME
try {
    $fingerprint = ($ExpectedSignerSha256 -replace '[:\s]', '').ToLowerInvariant()
    if ($fingerprint -notmatch '^[a-f0-9]{64}$') {
        throw 'ExpectedSignerSha256 must be the release certificate SHA-256 fingerprint (64 hex digits).'
    }
    $apkPath = (Resolve-Path -LiteralPath $Apk).Path
    if (!$AndroidSdk) { $AndroidSdk = Join-Path $workspace '.tools/android' }
    if ($JavaHome) { $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path }
    $buildTools = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'aapt.exe'))
        } | Select-Object -First 1
    if (!$buildTools) { throw 'Android build tools with apksigner.bat and aapt.exe are required.' }

    $signature = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --verbose --print-certs $apkPath
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $signatureText = $signature -join "`n"
    if ($signatureText -match '(?im)^[^\r\n]*certificate DN:.*\bCN=Android Debug(?:,|$)') {
        throw 'The APK uses an Android debug certificate. It cannot be packaged as a release.'
    }
    # Build tools 36 use "Signer #1"; 37 use scheme names such as "V3.0 Signer:".
    # A certificate may be printed for multiple schemes; every digest must match the pin.
    $signers = [regex]::Matches($signatureText, '(?im)^[^\r\n]*certificate SHA-256 digest:[ \t]*([a-f0-9]{64})[ \t]*$')
    $digests = @($signers | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
    if ($digests.Count -ne 1 -or $digests[0] -ne $fingerprint) {
        throw 'APK signer does not match the expected release certificate.'
    }

    $badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apkPath
    if ($LASTEXITCODE -ne 0) { throw 'APK manifest inspection failed.' }
    $package = [regex]::Match(($badging -join "`n"), "(?m)^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'")
    if (!$package.Success -or $package.Groups[1].Value -ne 'io.github.azrinfreeman.hopboard' -or
        $package.Groups[2].Value -ne [string]$ExpectedVersionCode -or
        $package.Groups[3].Value -ne $ExpectedVersionName) {
        throw 'APK package or version does not match the release source.'
    }
    if (($badging -join "`n") -notmatch "(?m)^native-code: 'arm64-v8a'\s*$") {
        throw 'Expected an ARM64-only APK.'
    }
    [pscustomobject]@{
        Package = $package.Groups[1].Value
        VersionName = $package.Groups[3].Value
        VersionCode = [int]$package.Groups[2].Value
        SignerSha256 = $fingerprint
    }
} finally {
    $env:JAVA_HOME = $previousJava
}
