# Release preparation

Neither platform is ready for a signed consumer release. Android signing support is implemented, but an owner-held key and real-device acceptance remain required. Windows installers remain unsigned while SignPath setup is pending. This document records preparation, not permission to publish.

## Android

Follow [the release-signing tutorial](tutorial/release-signing.md) to create and protect your key, configure the private properties file, pin its public certificate fingerprint and build a verified ARM64 APK. Use the same key and stable package ID for upgrades. Do not upload private signing files to a release.

Before publication, test on physical devices and verify installation and upgrade of the exact candidate bytes. Publish the public certificate fingerprint, APK SHA-256 checksum, supported ABI and honest platform limitations with the eventual release.

## Code signing policy

SignPath Foundation is the selected Windows signing route. No application, certificate, production signing policy or signing integration is active. Do not describe existing assets as signed or display a provider-credit statement implying approval.

The [official SignPath conditions](https://signpath.org/terms) require open-source eligibility, repository control, contributor MFA, defined signing roles, verifiable source builds and manual release approval. They also require a published code signing policy and privacy disclosure. Their review includes project reputation; meeting the technical checks does not guarantee acceptance. Apply through the [official application page](https://signpath.org/apply.html) once the following preparation is complete.

Checked on 4 November 2026:

- The GitHub repository is public. GitHub still returns no detected licence; the newly added MIT licence is local and has not been pushed.
- Existing Windows release assets are available, but physical acceptance remains incomplete.
- Owner confirmation of contributor MFA and author/reviewer/approver roles remains outstanding.
- A verifiable CI build, dependency/licence review, installer privacy review and approved SignPath artifact configuration are not yet in place. No workflow with invented project IDs or credentials has been added.

Review the public MIT licence and project documentation, confirm the maintainer roles and MFA, then prepare a verifiable Windows CI build for the application. After acceptance, configure signing for owned executables, the installer and uninstaller, preserving third-party signatures. Add SignPath's required provider credit only when it is accurate. Request manual signing approval for each release and verify resulting Authenticode signatures before distribution.

Hopboard sends shared content to the trusted session members chosen by the user. Discovery uses the local network. The Windows Update action contacts GitHub when the user requests an update; include that service interaction in the final signing-policy/privacy disclosure. Clipboard previews, file names and private content must not enter application or release logs.

## Candidate and publication checks

1. Keep `pubspec.yaml` and `applicationVersion` in `lib/core/protocol.dart` synchronized. Increase the build number for Android updates.
2. Run `flutter analyze --no-pub` and `flutter test --no-pub --exclude-tags large`. Rerun the large relay when transport changes require it.
3. Build the Windows installer with `tools/build_windows_installer.ps1`; build Android with the certificate-pinned script described above. Verify hashes and, once Windows signing is configured, Authenticode signatures.
4. Complete the relevant device acceptance rows against those exact files. A compiled or correctly signed binary alone is not consumer validation.
5. Sign the Windows installer for the in-app updater: `dart run tools/update_signing.dart sign <private-key-file> dist/Hopboard-Setup-<version>-x64.exe`, then upload the generated `.manifest.json` and `.manifest.sig` with the installer. The app refuses updates without a valid signature from the key pinned in `UpdateService.updateSigningPublicKeyPem`. First-time setup: `dart run tools/update_signing.dart generate <path-outside-repo>`, back the private key up offline, and pin the printed public key before building that release. Builds without a pinned key cannot update.
6. Review the final source diff, MIT/third-party notices, release notes, public certificate fingerprint, checksums and remaining limitations. Commit/push/tag/release only with the owner's publication authorization.
6. After publication, download the actual assets, verify them again, and run the updater acceptance row. If a release fails, retain the signing key and increase the version for the corrective release; do not reuse a version with different bytes.

No SignPath certificate request or application has been submitted.
