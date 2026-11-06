param(
    [Parameter(Mandatory = $true)][string]$ExpectedSignerSha256,
    [string]$AndroidSdk = '',
    [string]$JavaHome = ''
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$previousSdk = $env:ANDROID_HOME
$previousSdkRoot = $env:ANDROID_SDK_ROOT
$previousJava = $env:JAVA_HOME
$previousGradle = $env:GRADLE_USER_HOME
Push-Location $workspace
try {
    $fingerprint = $ExpectedSignerSha256 -replace '[:\s]', ''
    if ($fingerprint -notmatch '^[a-fA-F0-9]{64}$') { throw 'ExpectedSignerSha256 must be a SHA-256 certificate fingerprint.' }
    $signingFile = $env:HOPBOARD_ANDROID_KEY_PROPERTIES
    if ($signingFile -and ![System.IO.Path]::IsPathRooted($signingFile)) {
        throw 'HOPBOARD_ANDROID_KEY_PROPERTIES must be an absolute path.'
    }
    if (!$signingFile) { $signingFile = Join-Path $workspace 'android/key.properties' }
    if (!(Test-Path -LiteralPath $signingFile -PathType Leaf)) {
        throw 'Release signing is not configured. See docs/tutorial/release-signing.md. No APK was packaged.'
    }
    if (!$AndroidSdk -and (Test-Path -LiteralPath '.tools/android')) {
        $AndroidSdk = (Resolve-Path -LiteralPath '.tools/android').Path
    }
    if ($AndroidSdk) {
        $env:ANDROID_HOME = (Resolve-Path -LiteralPath $AndroidSdk).Path
        $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    }
    if ($JavaHome) { $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path }
    $env:GRADLE_USER_HOME = Join-Path $workspace '.tools/gradle'
    flutter build apk --release --split-per-abi --target-platform android-arm64 --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    $version = [regex]::Match((Get-Content -LiteralPath 'pubspec.yaml' -Raw), '(?m)^version:\s*(\S+)\+(\d+)\s*$')
    if (!$version.Success) { throw 'Expected a version name and build number in pubspec.yaml.' }
    $builtApk = Join-Path $workspace 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    $verified = & (Join-Path $PSScriptRoot 'verify_android_apk.ps1') -Apk $builtApk `
        -AndroidSdk $AndroidSdk -JavaHome $JavaHome -ExpectedSignerSha256 $fingerprint `
        -ExpectedVersionName $version.Groups[1].Value -ExpectedVersionCode (2000 + [int]$version.Groups[2].Value)
    $output = Join-Path $workspace 'dist'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $apk = Join-Path $output 'Hopboard-Android-arm64.apk'
    Copy-Item -LiteralPath $builtApk -Destination $apk -Force
    $checksum = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$apk.sha256" -Value "$checksum  Hopboard-Android-arm64.apk" -Encoding ascii
    Write-Output "Created $apk"
    Write-Output "Package: $($verified.Package); version: $($verified.VersionName); versionCode: $($verified.VersionCode)"
    Write-Output "Signer certificate SHA-256: $($verified.SignerSha256)"
} finally {
    $env:ANDROID_HOME = $previousSdk
    $env:ANDROID_SDK_ROOT = $previousSdkRoot
    $env:JAVA_HOME = $previousJava
    $env:GRADLE_USER_HOME = $previousGradle
    Pop-Location
}
