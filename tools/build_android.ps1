param([string]$AndroidSdk = '', [string]$JavaHome = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$previousSdk = $env:ANDROID_HOME
$previousSdkRoot = $env:ANDROID_SDK_ROOT
$previousJava = $env:JAVA_HOME
$previousGradle = $env:GRADLE_USER_HOME
Push-Location $workspace
try {
    if (!$AndroidSdk -and (Test-Path -LiteralPath '.tools/android')) {
        $AndroidSdk = (Resolve-Path -LiteralPath '.tools/android').Path
    }
    if ($AndroidSdk) {
        $env:ANDROID_HOME = (Resolve-Path -LiteralPath $AndroidSdk).Path
        $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    }
    if ($JavaHome) { $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path }
    $env:GRADLE_USER_HOME = Join-Path $workspace '.tools/gradle'
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    flutter build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    $output = Join-Path $workspace 'dist'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $apk = Join-Path $output 'LocalClipboard-Android-arm64.apk'
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk' -Destination $apk -Force
    $checksum = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$apk.sha256" -Value "$checksum  LocalClipboard-Android-arm64.apk" -Encoding ascii
    Write-Output "Created $apk (development signing key)"
} finally {
    $env:ANDROID_HOME = $previousSdk
    $env:ANDROID_SDK_ROOT = $previousSdkRoot
    $env:JAVA_HOME = $previousJava
    $env:GRADLE_USER_HOME = $previousGradle
    Pop-Location
}
