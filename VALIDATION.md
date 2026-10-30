# Validation record

Development version 0.1.1, checked on 12 October 2026. This records observed results separately from the physical-device release criteria in IMPLEMENTATION.md.

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
