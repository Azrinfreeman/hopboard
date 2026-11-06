# Integration checks with disposable certificates and a metadata-only APK fixture.
# These fixtures are not Hopboard builds and must never be installed or released.
param([string]$AndroidSdk = '', [string]$JavaHome = '', [switch]$CheckGradleConfiguration, [switch]$CheckSetup)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (!$AndroidSdk) { $AndroidSdk = Join-Path $workspace '.tools/android' }
if (!$JavaHome) { $JavaHome = $env:JAVA_HOME }
if (!$JavaHome) { throw 'Pass -JavaHome with an installed JDK.' }
$previousJava = $env:JAVA_HOME
$previousPassword = $env:HOPBOARD_SIGNING_TEST_PASSWORD
$previousSigningFile = $env:HOPBOARD_ANDROID_KEY_PROPERTIES
$previousGradle = $env:GRADLE_USER_HOME
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hopboard-signing-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0
function Expect-Rejection([string]$Name, [scriptblock]$Action, [string]$Message) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Message) { throw }
        Write-Output "PASS: $Name"
        return
    }
    throw "Expected rejection: $Name"
}
try {
    $env:JAVA_HOME = $JavaHome
    # Random test-only password, never printed or reused as an owner credential.
    $env:HOPBOARD_SIGNING_TEST_PASSWORD = [guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $toolset = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $aapt = Join-Path $toolset.FullName 'aapt.exe'
    $apksigner = Join-Path $toolset.FullName 'apksigner.bat'
    $keytool = Join-Path $JavaHome 'bin/keytool.exe'
    $fixtureFiles = Join-Path $testRoot 'files'
    $native = Join-Path $fixtureFiles 'lib/arm64-v8a'
    New-Item -ItemType Directory -Path $native -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $native 'libfixture.so') -Value 'Metadata fixture, not executable code.' -Encoding ascii
    $manifest = Join-Path $testRoot 'AndroidManifest.xml'
    Set-Content -LiteralPath $manifest -Encoding utf8 -Value @'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="io.github.azrinfreeman.hopboard" android:versionCode="2001" android:versionName="1.0.0">
  <uses-sdk android:minSdkVersion="29" android:targetSdkVersion="37" />
  <application android:label="Signing test fixture" android:hasCode="false" />
</manifest>
'@
    $unsigned = Join-Path $testRoot 'unsigned.apk'
    & $aapt package -f -M $manifest -I (Join-Path $AndroidSdk 'platforms/android-37.0/android.jar') -F $unsigned $fixtureFiles
    if ($LASTEXITCODE -ne 0) { throw 'Fixture packaging failed.' }
    $verifier = Join-Path $PSScriptRoot 'verify_android_apk.ps1'
    $arguments = @{
        AndroidSdk = $AndroidSdk; JavaHome = $JavaHome
        ExpectedVersionName = '1.0.0'; ExpectedVersionCode = 2001
    }
    foreach ($kind in @('release', 'debug')) {
        $keystore = Join-Path $testRoot "$kind.p12"
        $subject = if ($kind -eq 'debug') { 'CN=Android Debug,O=Android,C=US' } else { 'CN=Hopboard disposable signing test' }
        & $keytool -genkeypair -keystore $keystore -storetype PKCS12 -alias fixture `
            -storepass:env HOPBOARD_SIGNING_TEST_PASSWORD -keypass:env HOPBOARD_SIGNING_TEST_PASSWORD `
            -dname $subject -keyalg RSA -keysize 2048 -validity 2
        if ($LASTEXITCODE -ne 0) { throw 'Fixture key generation failed.' }
        $signed = Join-Path $testRoot "$kind.apk"
        & $apksigner sign --ks $keystore --ks-key-alias fixture --ks-pass env:HOPBOARD_SIGNING_TEST_PASSWORD `
            --key-pass env:HOPBOARD_SIGNING_TEST_PASSWORD --out $signed $unsigned
        if ($LASTEXITCODE -ne 0) { throw 'Fixture signing failed.' }
        $certificate = & $apksigner verify --print-certs $signed
        if ($LASTEXITCODE -ne 0) { throw 'Fixture signature failed.' }
        $fingerprint = [regex]::Match(($certificate -join "`n"), '(?im)^[^\r\n]*certificate SHA-256 digest:[ \t]*([a-f0-9]{64})').Groups[1].Value
        if (!$fingerprint) { throw ('Unexpected certificate output: ' + ($certificate -join "`n")) }
        if ($kind -eq 'debug') {
            Expect-Rejection 'debug certificate' { & $verifier -Apk $signed -ExpectedSignerSha256 $fingerprint @arguments } 'debug certificate'
            $passed++
            continue
        }
        $result = & $verifier -Apk $signed -ExpectedSignerSha256 $fingerprint @arguments
        if ($result.SignerSha256 -ne $fingerprint) { throw 'Verified fixture fingerprint mismatch.' }
        Write-Output 'PASS: valid pinned signature and metadata'
        $passed++
        if ($CheckGradleConfiguration) {
            $propertiesFile = Join-Path $testRoot 'key.properties'
            # This password belongs only to a short-lived fixture; file is deleted below.
            Set-Content -LiteralPath $propertiesFile -Encoding ascii -Value @(
                'storeFile=release.p12', 'keyAlias=fixture',
                "storePassword=$($env:HOPBOARD_SIGNING_TEST_PASSWORD)",
                "keyPassword=$($env:HOPBOARD_SIGNING_TEST_PASSWORD)"
            )
            $env:HOPBOARD_ANDROID_KEY_PROPERTIES = $propertiesFile
            $env:GRADLE_USER_HOME = Join-Path $workspace '.tools/gradle'
            $gradlew = Join-Path $workspace 'android/gradlew.bat'
            $report = & $gradlew -p (Join-Path $workspace 'android') :app:signingReport --offline --console=plain
            if ($LASTEXITCODE -ne 0 -or (($report -join "`n") -replace ':', '') -notmatch $fingerprint) {
                throw 'Gradle did not load the disposable release certificate from the external properties file.'
            }
            Write-Output 'PASS: Gradle loads external signing properties and relative keystore path'
            $passed++
            $env:HOPBOARD_ANDROID_KEY_PROPERTIES = Join-Path $testRoot 'missing.properties'
            # Windows PowerShell wraps redirected native stderr as error records.
            $previousActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $rejection = & $gradlew -p (Join-Path $workspace 'android') :app:assembleRelease --dry-run --offline --console=plain 2>&1
                $releaseExitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $previousActionPreference }
            if ($releaseExitCode -eq 0 -or ($rejection -join "`n") -notmatch 'Android release signing is not configured') {
                throw 'Gradle did not reject missing release credentials.'
            }
            Write-Output 'PASS: Gradle rejects missing release credentials'
            $passed++
            Expect-Rejection 'packaging rejects missing release credentials' {
                & (Join-Path $PSScriptRoot 'build_android.ps1') -ExpectedSignerSha256 $fingerprint
            } 'Release signing is not configured'
            $passed++
            $env:HOPBOARD_ANDROID_KEY_PROPERTIES = $previousSigningFile
        }
        Expect-Rejection 'wrong signer pin' { & $verifier -Apk $signed -ExpectedSignerSha256 ('0' * 64) @arguments } 'does not match'
        $passed++
        $arguments.ExpectedVersionCode = 2002
        Expect-Rejection 'wrong version code' { & $verifier -Apk $signed -ExpectedSignerSha256 $fingerprint @arguments } 'package or version'
        $passed++
        $arguments.ExpectedVersionCode = 2001
        $arguments.ExpectedVersionName = '2.0.0'
        Expect-Rejection 'wrong version name' { & $verifier -Apk $signed -ExpectedSignerSha256 $fingerprint @arguments } 'package or version'
        $passed++
        $arguments.ExpectedVersionName = '1.0.0'
        Expect-Rejection 'unsigned APK' { & $verifier -Apk $unsigned -ExpectedSignerSha256 $fingerprint @arguments } 'signature verification failed'
        $passed++
        $tampered = Join-Path $testRoot 'tampered.apk'
        $bytes = [System.IO.File]::ReadAllBytes($signed)
        $bytes[100] = $bytes[100] -bxor 1
        [System.IO.File]::WriteAllBytes($tampered, $bytes)
        Expect-Rejection 'tampered APK' { & $verifier -Apk $tampered -ExpectedSignerSha256 $fingerprint @arguments } 'signature verification failed'
        $passed++
    }
    if ($CheckSetup) {
        # Override only the test script's prompt scope; never pass a password argument.
        $env:HOPBOARD_SIGNING_TEST_PASSWORD = [guid]::NewGuid().ToString('N') + ' \ ! # = : '
        function Read-Host {
            param([string]$Prompt, [switch]$AsSecureString)
            ConvertTo-SecureString $env:HOPBOARD_SIGNING_TEST_PASSWORD -AsPlainText -Force
        }
        $setupPath = Join-Path $testRoot 'setup'
        $setup = Join-Path $PSScriptRoot 'setup_android_signing.ps1'
        & $setup -SigningDirectory $setupPath -JavaHome $JavaHome -CertificateName 'Hopboard disposable setup test' | Out-Null
        if (!(Get-Acl -LiteralPath $setupPath).AreAccessRulesProtected) { throw 'Setup did not protect directory access.' }
        $publicHash = (Get-FileHash -LiteralPath (Join-Path $setupPath 'release-certificate.der') -Algorithm SHA256).Hash
        if ($publicHash -ine (Get-Content -LiteralPath (Join-Path $setupPath 'release-certificate.sha256') -Raw).Trim()) {
            throw 'Setup certificate fingerprint mismatch.'
        }
        Write-Output 'PASS: first-key setup creates a private directory, key and matching public fingerprint'
        $passed++
        if ($CheckGradleConfiguration) {
            $env:HOPBOARD_ANDROID_KEY_PROPERTIES = Join-Path $setupPath 'key.properties'
            $report = & $gradlew -p (Join-Path $workspace 'android') :app:signingReport --offline --console=plain
            if ($LASTEXITCODE -ne 0 -or (($report -join "`n") -replace ':', '') -notmatch $publicHash) {
                throw 'Gradle could not read setup-generated properties with escaped password characters.'
            }
            Write-Output 'PASS: Gradle loads setup-generated credentials with escaped password characters'
            $passed++
            $env:HOPBOARD_ANDROID_KEY_PROPERTIES = $previousSigningFile
        }
        Expect-Rejection 'setup refuses an existing signing directory' {
            & $setup -SigningDirectory $setupPath -JavaHome $JavaHome
        } 'already exists'
        $passed++
        Expect-Rejection 'setup refuses a repository directory' {
            & $setup -SigningDirectory $workspace -JavaHome $JavaHome
        } 'outside this repository'
        $passed++
        Remove-Item Function:\Read-Host
    }
    Write-Output "$passed signing verification checks passed. No owner key or installable Hopboard APK was created."
} finally {
    $env:JAVA_HOME = $previousJava
    $env:HOPBOARD_SIGNING_TEST_PASSWORD = $previousPassword
    $env:HOPBOARD_ANDROID_KEY_PROPERTIES = $previousSigningFile
    $env:GRADLE_USER_HOME = $previousGradle
    # Only this run's explicitly named temporary directory may be deleted.
    $expectedParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $testRoot).TrimEnd('\') -ne $expectedParent -or
        (Split-Path -Leaf $testRoot) -notmatch '^hopboard-signing-test-[a-f0-9]{32}$') {
        throw 'Refusing cleanup outside the signing-test temporary directory.'
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
