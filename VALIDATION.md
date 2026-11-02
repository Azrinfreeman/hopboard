# Validation record

Records observed results; sections are dated. The first section was checked on 12 October 2026 against version 0.1.1. This records observed results separately from the physical-device checks that remain open.

Paths under `artifacts/`, `build/`, and uncommitted packages in `dist/` refer to generated local outputs. They are removed during cleanup and can be recreated with the commands below.

## Automatic text replacement follow-up (3 November 2026)

### Local 0.2.1 release installer

Distribution: the user subsequently authorized committing/pushing the source and uploading the installer and checksum as [v0.2.1 release assets](https://github.com/Azrinfreeman/hopboard/releases/tag/v0.2.1). The build-time checks below do not establish successful installation or physical-device acceptance.

- At the user's request, updated package version to `0.2.1+6` and peer-advertised application version to `0.2.1`. `flutter build windows --release --no-pub`: **passed**. `flutter test test/update_test.dart --no-pub`: **4 tests passed**.
- Built `dist/Hopboard-Setup-0.2.1-x64.exe` with `./tools/build_windows_installer.ps1 -SkipBuild` and Inno Setup 6.7.3. Verified application version `0.2.1+6`, installer file version `0.2.1.6`, all 12 staged release files matching the release output, and inclusion of `msvcp140.dll`, `vcruntime140.dll`, and `vcruntime140_1.dll`.
- Installer size: **11,431,896 bytes**. SHA-256 matches the adjacent checksum file: `a377c0f5c6846664f8426e6e07f276b723357b5443ce4a8e88d9471ea1e312aa`.
- Unsigned local release package; installation, upgrade and two-PC acceptance remain unverified. No GitHub release or running installation was updated.

### Source verification before packaging

- Reproduced ordinary startup text blocking fresh remote reception in both host/client receiving roles, and a stale guard after a delayed matching publication acknowledgement. These three acceptance tests failed against unchanged source and pass after the fix.
- Added **16 controller regressions** and **one widget test**. Coverage includes startup snapshot/replay protection, fresh text in both directions without echo, private/image/file/unreadable baselines, first enable/re-enable, paused edits, stale baseline reads, pending-publication status, stale acknowledgements before/after private-copy classification, rejected publications, native revision rejection, and an explicit typed-send conflict surviving recovery from a failed first baseline. Widget checks cover remaining manual reasons and Copy availability at desktop/narrow widths.
- Final `flutter test --no-pub --exclude-tags large`: **121 tests passed** in 36 seconds. Earlier `flutter test --no-pub`: **121 tests passed** in 2 minutes 44 seconds, including the **1 GiB TLS relay**. One final controller guard refinement/regression followed that full run; the final non-large run includes it. The unchanged relay was not repeated afterward.
- Final `flutter analyze --no-pub`: **no issues**. Final `flutter build windows --debug --no-pub`: **passed**, producing `build/windows/x64/runner/Debug/local_clipboard.exe`. Used the existing SDK at `D:/flutter-3.47.6/flutter/bin`; no dependencies or lockfile changed.
- `git diff --check`: **passed**. Relative documentation links checked. Details and manual acceptance steps: [IMPLEMENTATION.notes.md](IMPLEMENTATION.notes.md).
- **Not performed:** native clipboard tests or two-PC paste/tray/private-copy validation. The real OS clipboard and installed application were not changed. No installer or release was produced; published 0.2.0 does not contain this follow-up.

## Verified

| Check | Result |
| --- | --- |
| Static analysis | `flutter analyze`: no issues |
| Automated tests | 36 tests pass |
| Actual TLS connections | Windows loopback: pinned certificate, pair/approve, multiple clients, authentication, broadcast, wrong-pin rejection, revoke, reconnect/rebind |
| Six-digit pairing | SRP mutual proof, wrong-code rejection before approval, five-attempt lock with QR fallback, single-use across QR/code, cancellation, host decline, saved-pin session connection, and code-copy isolation |
| Pairing relay protection | SRP binding rejects altered certificates and replayed evidence; an actual TLS proxy with a substituted certificate cannot reach approval or obtain a credential |
| Protocol correctness | Incremental/fragmented frames, UTF-8/emoji, 64 KiB boundary, preallocation wire limit, version validation, send-rate limit, sequencing, clear, expiry, deduplication before conflict checks |
| Sequence stress | 10,000 publications through the session engine with controlled time; this is not the full native clipboard endurance gate |
| Controller sync | Both directions without echoes, rapid-copy coalescing, pause/resume, concurrent native write guard, protection of newly copied offline text, invitation-copy isolation, recoverable startup permission denial |
| Responsive UI | Desktop and 390-pixel narrow layouts, nearby-host selection, code entry/validation, leading-zero paste, and short-code invitation/copy render without overflow/assertions |
| Windows native smoke test | Version 0.1.0 passed: DPAPI identity save/restore, clipboard listener and tray initialization, rendered overview and session navigation. The 0.1.1 test build compiled, but the smoke run could not start while an existing user app held the single-instance lock; that app was left running. The updated pairing screens pass isolated widget checks. |
| Windows release | Native release build and portable ZIP produced |
| Portable package smoke test | Version 0.1.0: extracted ZIP starts successfully; second launch exits successfully while the first process stays running. Version 0.1.1: executable version 0.1.1+2, required ZIP bundle entries, and SHA-256 verified; an additional launch was avoided while the user's app was running. |
| Android release-mode build | ARM64, ARMv7, and x86_64 APKs produced, with development signing; installation and clipboard behavior on a real phone remain unverified |
| Android package inspection | Version 0.1.1 / ARM64 versionCode 2002, APK signature verifies (v2), ARM64 architecture, target SDK 37, and generated SHA-256 checked. Local-network/camera permissions and app label were inspected in 0.1.0 and their configuration is unchanged. |

Tests use real local TLS sockets for the transport and a controllable clipboard adapter for clipboard changes/races. The Windows native smoke test initializes the real adapters and exercises encrypted storage; it deliberately does not read or replace the user's OS clipboard. It is not proof of cross-device native clipboard operation.

The screenshot in `artifacts/windows-overview.png` comes from the native Windows integration test. Discovery and interface loading are disabled in that test, so its Start session button is disabled; normal builds enumerate LAN interfaces.

## Preliminary footprint

Version 0.1.0 baseline: Windows x64 release, AMD Ryzen 7 5700X (16 logical processors), Windows 11 Pro. Sampled for 60.85 seconds after a five-second warm-up, disconnected, Automatic sharing disabled. The following idle measurements have not been repeated for 0.1.1:

| Measurement | Observed |
| --- | --- |
| Uncompressed portable bundle | Approximately 29.8 MB (28.5 MiB) |
| Portable ZIP | Approximately 12.6 MB |
| Average resident working set | 98.40 MiB |
| Peak resident working set | 100.01 MiB |
| CPU, percentage of whole machine | 0.002% |
| CPU, percentage of one logical core | 0.026% |
| Android ARM64 APK | Approximately 26.3 MiB download; installed size not yet measured |

Raw data is in `artifacts/windows-idle-metrics.json`. This is an idle development baseline, not a connected eight-device measurement, battery test, or latency result. Installed SDK/compiler caches in `.tools/` are build dependencies and are not part of the app bundle.

Version 0.1.1 package measurements: Windows ZIP **12,581,865 bytes**, uncompressed bundle **29,878,047 bytes**; Android ARM64 APK **27,597,747 bytes**. Both package checksums match their accompanying `.sha256` files. The code-pairing feature adds about 22 KB to the Windows ZIP and 66 KB to the Android APK compared with 0.1.0.

## Still required before public release

- Compile iOS on macOS/Xcode, validate Swift/plugin integration, configure signing, and run on a real iPhone. Windows cannot provide an iPhone build.
- Run native clipboard transfers on two Windows PCs, Windows ↔ Android, Windows ↔ iPhone, and Android ↔ iPhone. Verify both phone host roles and three/eight-device sessions on actual Wi-Fi with internet disconnected.
- Verify Android/iOS clipboard behavior, QR camera permission denial, local-network permission denial/recovery, discovery, screen lock, background transitions, and phone-host shutdown.
- Verify Windows clipboard contention/CAS behavior and tray operation against actual applications; the automated clipboard adapter cannot establish OS interoperability.
- Measure 1,000 transfers per supported device-role combination, p95/p99 latency, network-restored recovery, 10,000 native clipboard changes, and eight-hour desktop endurance. These gates have not yet run.
- Verify connected idle footprint, mobile APK installed footprint, mobile memory, and foreground battery use against the plan's budgets.
- Exercise physical network changes, DHCP address changes, VPNs, blocked multicast, guest isolation, host sleep, and narrow Windows firewall rules.
- Review transport/storage security on all targets, encrypted packet capture, malformed/flooded handshake behavior, and credential-revocation persistence. Current automated bounds tests do not constitute a security audit.
- Independently review application-layer SRP certificate binding and test code pairing/discovery on physical PCs and phones, including blocked multicast, exhausted code attempts, cancellation, expiry, and network spoofing.
- Configure private Android release signing and Windows signing/distribution. Current Windows binaries are unsigned; Android development APKs use the debug signing key.

## Reproduce

```powershell
flutter analyze
flutter test --reporter expanded
flutter test integration_test/windows_smoke_test.dart -d windows --dart-define=ARTIFACT_DIR=E:/Projects/2026Projject/LocalClipboard/artifacts --reporter expanded
./tools/build_windows.ps1
./tools/build_android.ps1 -JavaHome "C:/path/to/jdk"
```

The implementation explicitly distinguishes host acknowledgement, inbox availability, and confirmed OS clipboard application. “Flawless and seamless” remains the release contract; this development build cannot yet claim that the physical-device reliability gates have passed.

## Windows rich clipboard development checks (30 October 2026)

The 0.2.0 development implementation builds for Windows and includes image/mixed controller tests plus offline updater validation. Device checks still required:

- Enable image consent independently, then copy a screenshot between two PCs and paste in Paint, Word and a chat app.
- Copy Excel cells and paste as cells in Excel and as an image in Paint. Confirm fallback text does not overwrite a newer local copy when image transfer fails.
- Exercise Pause, Clear, expiry, reconnection, clipboard contention and private clipboard formats during image transfers.
- Run the Update flow against an actual published installer: verify cancellation, corrupted download rejection, app exit, helper launch and successful restart. No real installer was downloaded or executed during automated verification.
- Windows Explorer files/folders are implemented in development source; physical Explorer interoperability and phone image/file workflows remain unverified. Phone rich-content support is pending implementation.

### Phase 3 Windows files/folders (30 October 2026)

- The resumed full suite passed **82 tests**, including the **1 GiB TLS relay** with slow-receiver, ping, suffix-offset and memory-bound checks. After cache-space and progress additions, the suite excluding `large` passed **84 tests**. Final cache/ZIP cleanup changes passed **27 controller/file tests**, and the preceding controller/file/widget run passed **42 tests**. The unchanged large-transfer test was not repeated after these controller/cache refinements.
- Final `flutter analyze --no-pub`: **no issues**. Final `flutter build windows --debug --no-pub`: **passed**.
- `flutter test integration_test/windows_files_test.dart -d windows --no-pub`: **1 native test passed**. It verifies real `CF_HDROP` read/write, Copy rather than Cut semantics, own-write detection, stale-revision rejection and the available-disk-space bridge. It temporarily replaces the clipboard and restores the supported text/image/file content afterward; it does not establish two-PC Explorer paste interoperability.
- Controller/file checks cover bidirectional nested file bytes and empty folders, separate consent, Cut/private-copy rejection, manual size thresholds, source changes, staged cleanup, local-copy cancellation, clear-and-retry, low-disk rejection and retry, retained-cache accounting, ZIP contents and failed ZIP reservation. Member progress is range-checked and cleared on supersession.
- File controls/progress pass desktop and 320-pixel, 2× text-scale widget layouts. Refreshed and visually inspected `artifacts/phase3/windows-files.png`.
- Required next: two-PC Explorer/Office paste, actual Wi-Fi transfer and disconnection, disk exhaustion during writing, clipboard contention and retention/endurance checks. Phone rich-content implementation and real installer upgrade validation remain pending. No release or installer was published.

### Local test packages (30 October 2026)

- Built the Windows x64 release, version `0.2.0-dev+4`, and compiled `dist/Hopboard-Setup-0.2.0-dev-x64.exe` with Inno Setup. Installer tooling now accepts prerelease version labels.
- Verified required installer-stage files, all three x64 Visual C++ runtime DLLs and executable equality with the release build. Verified required contents of the portable ZIP and both generated SHA-256 checksums.
- Packages are unsigned local test builds. The installer was not installed or published; upgrade installation and two-PC paste remain for manual testing.

### Clipboard reliability (3 November 2026)

- Reproduced two failures against the original controller using the new tests: one copy with capture busy for 600 ms never arrived, and a successful write followed by busy confirmation reads never reached the confirmed state. Both regressions pass with the fix.
- Added 19 controller regressions/eligibility checks. Coverage includes text/image/file confirmation without repeated writes, capture recovery without another event, permanent-error classification, bounded retry exhaustion, latest/private-copy handling, duplicate events, pause cancellation, supersession, recovery after unconfirmed writes, manual Copy confirmation, and subsequent bidirectional sharing.
- `flutter test --no-pub --exclude-tags large --reporter expanded`: **104 tests passed** on the final code. File status/action presentation also passes the existing desktop and 320-pixel, 2× text-scale widget test.
- An earlier `flutter test --no-pub --reporter expanded` run passed **99 tests**, including the unchanged **1 GiB relay** (3 minutes 25 seconds). Subsequent capture/confirmation refinements and additional regressions were checked by the final 104-test run; the large transfer was not repeated after those controller-only refinements.
- Final `flutter analyze --no-pub`: **no issues**. Final `flutter build windows --debug --no-pub`: **passed**, producing `build/windows/x64/runner/Debug/local_clipboard.exe`. Commands used the existing Flutter 3.47.6 SDK at `D:/flutter-3.47.6/flutter/bin`; dependencies were resolved with `flutter pub get --offline`, without changing the lockfile.
- Extended `integration_test/windows_files_test.dart` to assert clipboard listener delivery alongside its existing native file/revision checks. **Not run this session:** native tests and external-process clipboard contention. An installed Hopboard process was running at `C:/LocalClipboard/local_clipboard.exe`; it was left open, and the real user clipboard was not read or replaced.
- **Still required:** two-PC Explorer/Office/image/video paste with matching builds, real contention during capture/write/confirmation, physical disconnect and sleep recovery, and the manual acceptance checks in [IMPLEMENTATION.md](IMPLEMENTATION.md). No installer, release, or running installation was updated.

### Version 0.2.0 installer (3 November 2026)

- The user reported that the rebuilt development installer works. This is user feedback, not an independently observed two-PC test.
- Updated the package version to `0.2.0+5` and the application version advertised to peers to `0.2.0`.
- `flutter test --no-pub --exclude-tags large --reporter expanded`: **104 tests passed**. `flutter analyze --no-pub`: **no issues**. `flutter build windows --release --no-pub`: **passed**.
- Built `dist/Hopboard-Setup-0.2.0-x64.exe` with Inno Setup 6.7.3. Verified application version `0.2.0+5`, installer version `0.2.0.5`, the generated SHA-256 checksum, staged release-file equality, and inclusion of all three x64 Visual C++ runtime DLLs.
- This installer is unsigned and has not been installed or published during this build. The remaining physical-device checks above still apply.
