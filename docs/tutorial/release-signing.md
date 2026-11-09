# Build an Android release with your signing key

Android release builds now require your own signing configuration. There is no debug-key fallback. The packaging script verifies the APK against a certificate fingerprint you supply before copying it into `dist/`.

## Prerequisites and source files

Use the project's Flutter SDK and installed dependencies, an Android SDK with platforms 36 and 37.0 and build tools, and a compatible JDK. This session used Flutter at `D:/flutter-3.47.6/flutter` and the Android Studio JBR. Run `flutter pub get` if dependencies have not been restored.

- [Android Gradle configuration](../../android/app/build.gradle.kts): permanent package ID, release signing, missing-key checks. Debug builds need no release key.
- [Properties template](../../android/key.properties.example): the four required signing fields; the completed file is private.
- [First-key setup](../../tools/setup_android_signing.ps1): interactive password entry, external private directory, key generation and public fingerprint export; refuses an existing directory.
- [Build script](../../tools/build_android.ps1): builds an ARM64-only release, invokes verification, then creates an APK and checksum in `dist/`.
- [APK verifier](../../tools/verify_android_apk.ps1): checks signature, expected certificate, package, version and architecture.
- [Signing checks](../../tools/test_android_signing.ps1): creates disposable certificates and metadata-only APK fixtures. It does not create a consumer APK or use your release key.

The package ID is `io.github.azrinfreeman.hopboard`. Preserve it and the signing key for future direct-distribution updates. Older development builds with the old package ID are separate installations. If a debug build uses the final package ID, uninstall it before installing a differently signed release; that removes its local identity and pairings.

## Create and protect the key

For the first key, run the setup script in your own Windows PowerShell terminal. It prompts twice for your new password and creates an account-restricted directory at `%LOCALAPPDATA%/Hopboard/Signing`. It uses your approved GitHub identity as the public certificate name, and refuses to overwrite an existing directory or put keys in the repository.

```powershell
./tools/setup_android_signing.ps1 -JavaHome 'C:/Program Files/Android/Android Studio/jbr'
$signingDir = Join-Path $env:LOCALAPPDATA 'Hopboard/Signing'
$env:HOPBOARD_ANDROID_KEY_PROPERTIES = Join-Path $signingDir 'key.properties'
```

The script creates `hopboard-release.p12`, a private `key.properties`, and public certificate/fingerprint files. Back up the key securely in two locations and save the password separately. Do not send the password or the properties file here. The public fingerprint and local file path are sufficient for the next build step. Passwords exist briefly in process memory/environment while `keytool` runs; the script restores that environment afterward.

The manual workflow below is an alternative, not a second key to create after the script succeeds. Keep the key and completed properties file outside this checkout. Do not use a shared or publicly synced directory.

Run these commands yourself in a local PowerShell terminal. `keytool` prompts for a new password and certificate identity. Do not paste passwords into chat, shell arguments, build logs or source control.

```powershell
$signingDir = Join-Path $env:USERPROFILE 'HopboardSigning'
New-Item -ItemType Directory -Path $signingDir -Force | Out-Null
$keytool = 'C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe'
& $keytool -genkeypair -v -storetype PKCS12 -keyalg RSA -keysize 4096 `
    -validity 10000 -alias hopboard-release `
    -keystore (Join-Path $signingDir 'hopboard-release.p12')
```

Use the same password for the store and key with PKCS12. Back up the keystore to two secure locations and keep the password in your password manager. For direct APK distribution, losing this signing key prevents updates to existing installations. Certificate identity information is public in distributed APKs; enter appropriate maintainer information.

Copy `android/key.properties.example` to `HopboardSigning/key.properties` and edit it locally. Fill all four fields:

```properties
# Replace every placeholder locally; never commit the completed file.
storeFile=C:/Users/YOUR_WINDOWS_ACCOUNT/HopboardSigning/hopboard-release.p12
storePassword=YOUR_PRIVATE_STORE_PASSWORD
keyAlias=hopboard-release
keyPassword=YOUR_PRIVATE_KEY_PASSWORD
```

Use forward slashes in `storeFile`. Java properties parsing treats backslashes as escapes; a literal backslash in a password must be written as `\\`. Avoid leading whitespace in values. Relative keystore paths are resolved against the properties file's directory. The properties file contains plaintext secrets: restrict its access and exclude it from ordinary backups or use encrypted backups.

Select the file for the current terminal:

```powershell
$env:HOPBOARD_ANDROID_KEY_PROPERTIES = Join-Path $signingDir 'key.properties'
```

This environment variable must be an absolute path. Without it, Gradle reads `android/key.properties`, which is gitignored. The repository also ignores common keystore extensions; this does not replace safe key storage.

## Obtain the public certificate fingerprint and build

List the certificate using `keytool`; it prompts privately for the store password:

```powershell
& $keytool -list -v -alias hopboard-release `
    -keystore (Join-Path $signingDir 'hopboard-release.p12')
```

Copy the public `SHA256` fingerprint into the command below. Colon-separated or plain hex is accepted. The fingerprint is not a password. Keep its trusted copy alongside your release records; do not take it from an untrusted downloaded APK.

```powershell
# Replace the placeholder with your certificate's public SHA-256 fingerprint.
./tools/build_android.ps1 -ExpectedSignerSha256 'YOUR_CERTIFICATE_SHA256' `
    -AndroidSdk './.tools/android' `
    -JavaHome 'C:/Program Files/Android/Android Studio/jbr'
```

The script uses `flutter` from your terminal's PATH. Confirm `flutter --version` matches the project SDK before building. It uses existing dependencies (`--no-pub`). Only a verified build is copied to `dist/Hopboard-Android-arm64.apk`; an adjacent `.sha256` records its file checksum. Failed verification leaves any older `dist/` APK untouched, so an old file's presence is not proof of a successful build. Always check the current command's result and certificate output.

To verify the generated APK again, pass the source version and expected split-APK version code:

```powershell
# Example for source 0.2.2-rc.1+7: arm64 split versionCode is 2007.
./tools/verify_android_apk.ps1 -Apk './dist/Hopboard-Android-arm64.apk' `
    -ExpectedSignerSha256 'YOUR_CERTIFICATE_SHA256' `
    -ExpectedVersionName '0.2.2-rc.1' -ExpectedVersionCode 2007 `
    -JavaHome 'C:/Program Files/Android/Android Studio/jbr'
```

The verifier rejects Android debug certificates even if their fingerprint was supplied. It requires the final package ID and ARM64-only native libraries. Certificate rotation and multiple distinct signers are deliberately rejected until a migration is designed.

## Make a routine change

To build the next candidate, update the existing `version:` in [pubspec.yaml](../../pubspec.yaml) from `0.2.2-rc.1+7` to `0.2.2-rc.2+8`, and `applicationVersion` in [protocol.dart](../../lib/core/protocol.dart) to `0.2.2-rc.2`. Build using the same keystore and certificate fingerprint. Expected metadata becomes version name `0.2.2-rc.2` and ARM64 split version code `2008`. This example is illustrative; the source version has not been advanced to it.

Run `flutter test test/update_test.dart --no-pub` after changing versions. Install over the previous release-signed APK on a physical phone and confirm pairings survive. Do not change the package ID or generate a new key for routine updates.

## Checks and troubleshooting

Run the independent verifier checks without release credentials:

```powershell
./tools/test_android_signing.ps1 -JavaHome 'C:/Program Files/Android/Android Studio/jbr'
# Include Gradle configuration and the one-time setup fixture:
./tools/test_android_signing.ps1 -JavaHome 'C:/Program Files/Android/Android Studio/jbr' -CheckGradleConfiguration -CheckSetup
```

Seven fixture checks passed on SDK build tools 37.0.0: valid certificate/metadata, wrong certificate, wrong version code, wrong version name, unsigned APK, tampering and debug certificate. Adding `-CheckGradleConfiguration` verifies external signing properties/relative keystore paths and missing-key rejection in Gradle and packaging. Adding `-CheckSetup` tests private key setup, public fingerprint export, password escaping through Gradle and directory guards: fourteen checks total, all passed. Debug manifest processing passed without a release key.

The setup test used a disposable key and simulated secure prompts. Actual owner password entry, owner-key backup, a real release-signed Hopboard build, and phone installation/upgrade remain untested. The commands above describe those manual steps; the fixture test does not prove them. No PDF companion was generated because document export tooling is unavailable in this environment; this Markdown is the authoritative editable tutorial.

If signing is not configured, check the absolute properties-file path and the four fields. If the keystore is not found, check forward slashes and path resolution. If a fingerprint differs, stop and compare against your trusted release certificate before distributing anything. Gradle resolves the SDK from `android/local.properties`; the Flutter build command refreshes that file. A direct Gradle command may need its existing `sdk.dir` corrected to the installed project SDK.

For Windows signing and publication gates, see [RELEASING.md](../RELEASING.md). Android's [app-signing guidance](https://developer.android.com/studio/publish/app-signing) explains key custody; the [apksigner reference](https://developer.android.com/tools/apksigner) describes signature verification.
