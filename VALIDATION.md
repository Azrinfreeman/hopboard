# Validation record

## Seamless clipboard (7 November 2026)

- `dart analyze lib test integration_test`: no issues. `flutter test --exclude-tags large`: **169 tests pass** (153 before; new `test/newest_wins_test.dart` 6, `test/virtual_files_test.dart` 5, `test/rich_text_test.dart` 5). Four of the newest-wins tests fail with the setting off, confirming they test the change. With the test helper's default flipped to newest-wins on, 12 older tests fail, all of the intended kind (a local copy made before a later remote copy now loses, or a lost race no longer becomes a conflict); tests where the local copy is made during or after the incoming write still pass, and the Android tests pass because newest-wins is desktop-only. The helper keeps the old default for those tests.
- `flutter build windows --debug`: passes with `/WX`.
- Released as `0.3.0+15` (same code as rc.8; only the version changed; 169 tests pass). Built `dist/Hopboard-Setup-0.3.0-x64.exe` (SHA-256 `8c9ca51a7c898d3ab57874f6667fe406a057949d15e9c328ea663b94a4d6d456`). Earlier build: version `0.2.2-rc.8+14`. Built `dist/Hopboard-Setup-0.2.2-rc.8-x64.exe` (SHA-256 `30bf3509a6c1365bcbac57628da875cec2793751bbf0d11aa24812bf32c64970`) with `./tools/build_windows_installer.ps1`; the release executable reports `0.2.2-rc.8+14` and contains the virtual-file marker format. Not yet installed on a second PC.
- New `integration_test/windows_virtual_test.dart` on this PC's real clipboard (restored afterwards): virtual write, stale-revision guard, own-write detection, upgrade to real files, clear of a superseded item, and HTML/RTF round trip. **2 tests pass**, repeated 3 times; each run needed 1-2 short "busy" retries caused by other clipboard listeners.
- Native harness (outside the repository) linking `virtual_clipboard.cpp`: a 24 MiB file and a nested folder pasted through the destination folder's shell drop target (Explorer's paste path) while bytes arrived progressively, including renaming the file under an open stream: identical output. The pasted file has `Zone.Identifier` with `ZoneId=3`. Replacing the clipboard with `CF_HDROP` mid-paste (the prefetch upgrade) did not disturb the paste. A failed download made reads fail with `STG_E_READFAULT` instead of hanging; clear removed the object.
- `integration_test/windows_smoke_test.dart` fails on UI text that no longer exists in `lib` ("Copy here. Paste over there.", "Your shared clipboard."); it was already stale before this work. The native startup it covers ran without errors.
- Android `0.3.0+15` APK built and verified (package `io.github.azrinfreeman.hopboard`, versionCode 2015, signer SHA-256 `9a2bdc94972cbb1a2d58030056c5cf891bc97969c47d6e91ee96fcdcab305ecd`, APK SHA-256 `57ae2186dd8c67f4d7bf64d850a4a40bbc3c96b665b77187316ad1de47066db3`) and attached to release v0.3.0 at the owner's request, before the physical-device worksheet was run.
- Owner check (rc.8, two Windows PCs): seamless copy and paste works in both directions, and disconnecting the sender during a large paste behaves as intended.
- **Not performed:** paste into apps without virtual-file support, Office/browser formatted paste, and a host (not sender) disconnect during a paste.

## Android D21 diagnostic removed (5 November 2026)

- Removed the background clipboard test (UI card, controller and bridge code, native probe, Gradle JUnit dependency and its tests) after the owner's tablet counted 0 background signals. Version `0.2.2-rc.7+13`. Analysis clean; **153 tests pass** (nine diagnostic tests removed). The release APK was rebuilt, signed and verified; the tile and Share behaviour are otherwise unchanged. Not re-run on a device after the removal.

## Android Quick Settings tile, D21 result (5 November 2026)

- The owner's Xiaomi tablet counted 0 background clipboard signals in all D21 runs, so the overlay-based automatic send was dropped.
- Added the **Send to PC** Quick Settings tile (`SendTileService`), an in-app **Add "Send to PC" tile** button, and a flipped icon arrow. Version `0.2.2-rc.6+12`.
- Analysis clean and 162 tests pass; release-signed ARM64 APK built (versionCode 2012).
- Emulator (Android 17): the system add-tile prompt appeared with the tile and icon; copying text in Settings and clicking the tile sent it to the test PC (`tile-send-test-1`, "Ready to paste" there). **Not performed:** the Xiaomi tablet, the locked-device unlock path, the Android 12 and older Intent start path, and a dimmed-tile tap.

## Android D21 callback diagnostic (5 November 2026)

- Owner report: D20 works as intended on the Xiaomi tablet. Individual E1-E8 edge-case outcomes were not supplied. This clears the D20 gate for measuring D21's background trigger; it does not establish that the trigger or overlay approach works.
- Added an explicit, off-by-default, 60-second callback test in **Clipboard > Background clipboard test**. The diagnostic accepts no clipboard text or descriptions. It counts stopped-activity callbacks separately from focused events, excludes locked-screen/recent-own-write/visible-unfocused events, measures background time, and keeps reports only in memory. Notification Stop test, Pause, Stop and lifecycle cleanup are implemented. Returning to the activity ends the background interval before delayed callbacks can count there. The tablet still needs to verify native notification and lifecycle behavior.
- `D:/flutter-3.47.6/flutter/bin/flutter.bat test --no-pub --exclude-tags large`: **162 passed**, 47 seconds. New controller/bridge cases cover start gates, no diagnostic reads/writes, counter refresh, error recovery, and stopping through Pause/background off/automatic off/Leave. Existing D20 and background receive tests remain green.
- `./android/gradlew.bat -p android :app:testDebugUnitTest --console=plain` with Android Studio's JBR and `.tools/gradle`: **5 passed**, zero skipped/failures/errors in the native XML report. Tests cover stopped-activity boundaries, focus loss, delayed callbacks on return, own/locked exclusions, exact timeout, frozen counts and restart. Initial offline debug resolution failed because the existing Flutter debug embedding was uncached; normal resolution succeeded. A release unit-test attempt found that this Flutter plugin exposes no such task; use the documented debug task. Test-only JUnit 4.12 was added; runtime dependencies are unchanged.
- Direct `dart analyze --format machine lib test`: clean. New widget controls tested at 375/390 pixels and 900×500 landscape with 2× text and animations disabled. The 390-pixel capture in `build/d21-captures/android-d21-390-2x.png` was inspected: text wraps and scrolls; controls remain reachable. It uses fake counts, not real tablet data. The existing header word-wrap at 2× remains. No independent dark-mode or screen-reader run was performed.
- `tools/build_android.ps1` with the existing owner key: release ARM64 APK built in 130.6 seconds; package `io.github.azrinfreeman.hopboard`, version `0.2.2-rc.5`, versionCode **2011**, expected signer SHA-256 `9a2bdc94972cbb1a2d58030056c5cf891bc97969c47d6e91ee96fcdcab305ecd` verified. Output `dist/Hopboard-Android-arm64.apk`; SHA-256 `47449302d0c9e60a18e413405f5520dd0e8b1f473db9607e3b995926164254f7` matches the adjacent checksum. Manifest permission inspection confirms no overlay permission was added. No automatic focus-taking, polling, accessibility service or keyboard substitution is included.
- Updated the existing [editable Android tutorial](docs/tutorial/android-send.md#try-the-d21-callback-test), its HTML companion and [device rows S1-S4](docs/testing/device-test-checklist.md#android-d21-callback-experiment-rc5). The native source, Flutter controls, representative duration change and build/test instructions are identified there. Documentation checks and export verification are recorded after execution below.
- **Remaining:** run S1/S2 on the Xiaomi tablet and record counts, source apps and OS version. Positive background callbacks would justify a later overlay/focus spike, not prove automatic capture. Zero callbacks with confirmed copies and sufficient hidden time means no trigger was observed in that configuration. No Android device was attached; this candidate was not installed or tested in an emulator, and native OS notification/focus behavior remains unverified. No Windows build/replacement, real OS clipboard manipulation, commit, push or publication was performed for this diagnostic.

Records observed results; sections are dated. The first section was checked on 12 October 2026 against version 0.1.1. This records observed results separately from the physical-device checks that remain open.

Paths under `artifacts/`, `build/`, and uncommitted packages in `dist/` refer to generated local outputs. They are removed during cleanup and can be recreated with the commands below.

## Android explicit send D20 (5 November 2026)

- Owner clarification: their PC-to-Xiaomi-tablet test received **text only**, not files. That report establishes ordinary receive working on rc.3, not full background/endurance acceptance.
- D20 implemented: exported Share / PROCESS_TEXT target; private focused notification reader; cold-start intent handoff; saved-host reconnect; acknowledgement before success; pause, private-copy and received-text checks. No overlay, accessibility service or Quick Settings tile was added. Notification action is persistent while the service is active and unpaused because Android may suppress clipboard-change callbacks in the background.
- `D:/flutter-3.47.6/flutter/bin/flutter.bat test --no-pub --exclude-tags large`: **153 passed**, about 41 seconds. Eleven new tests use real loopback TLS and fake clipboards: explicit Share preserves the clipboard with Automatic off, background sending, sensitive/own-write rejection, received-text echo suppression, unpaired and unreachable hosts, reconnect with and without the background service, pause/invalid/UTF-8 size limits, and subsequent PC copies preserving a newer local copy. The `large` transfer was not rerun.
- `D:/flutter-3.47.6/flutter/bin/cache/dart-sdk/bin/dart.exe analyze --format machine lib test`: **passed with no diagnostics** after fixing two braces lints. `flutter analyze --no-pub` stalled in this environment and was stopped; the direct Dart command is the completed analysis check. No dependency changes or global Git settings were needed.
- Release build: `flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64 --no-pub` using Flutter 3.47.6, existing Android SDK, Android Studio JBR and `.tools/gradle`. **Passed** for both ABIs, including Kotlin compilation. Final rebuild after source changes passed in 79.4 seconds. Existing JDK native-access warnings are non-fatal.
- `tools/verify_android_apk.ps1` **passed** for the ARM64 split against the existing owner's public release certificate fingerprint, final package ID `io.github.azrinfreeman.hopboard`, version `0.2.2-rc.4`, version code **2010**, signature and ARM64-only native libraries. Copied the verified APK to `dist/Hopboard-Android-arm64.apk` and regenerated its checksum. SHA-256: `1fd373759b6bc68cca09b3dcfe368289967cf642a31d1322c03776f2586fac8f`.
- Emulator: `Medium_Phone_API_37.0`, Android 17 / API 37, release-signed builds. The temporary multi-ABI test APK could not update the prior split APK because its unsplit version code was lower; only the disposable emulator's old Hopboard installation was removed, then it was freshly paired. Later x86_64 split updates installed successfully without removing pairing. No physical device was connected or modified.
- Emulator host: existing `tools/emulator_host_harness.dart`, real local TLS with fake PC clipboard, loopback port 47399 reached as 10.0.2.2 from the emulator. Tested warm ACTION_SEND, cold ACTION_SEND after force-stop, ACTION_PROCESS_TEXT, Settings search copy then notification Send to PC, and a later PC-to-phone background copy showing Ready to paste. Host log records the sent test strings; the focused send windows returned to Settings. Final binary's cold Share also passed. Android's resolver lists the Share activity for both text intents. Direct shell launch of the private clipboard reader was correctly rejected as not exported. Source-app-specific Share/selection UI, native private-copy and exhaustive pause/stop checks still need the tablet worksheet; those controller behaviors are covered automatically.
- Host harness never reads or writes the real Windows clipboard. The emulator was headless, but the attempted `-feature -ClipboardSharing` flag was rejected by this emulator build, so host clipboard isolation **was not established**; disposable emulator test strings may have reached the Windows clipboard. No clipboard content was read back from Windows. Emulator screenshots/logs are generated files under `build/emu/`.
- Added `docs/tutorial/android-send.md` as authoritative editable guide and `android-send.html` as its printable text companion, regenerated with `python tools/export_android_send_guide.py`. HTML preview was inspected for wrapping and overflow. No PDF was produced. Relative file links, balanced code fences, export-script syntax and `git diff --check` passed; only existing line-ending warnings remain.
- Remaining: install rc.4 on the Xiaomi tablet and run E1-E8 in `docs/testing/device-test-checklist.md`. **D21 is authorized after D20 works on that tablet**, and is not implemented. Its first check must establish a usable background clipboard-change signal; overlay permission alone does not supply one. Windows stays on rc.3; no Windows rebuild, commit, push, publication or installed Windows app replacement was performed.

## Android release-signing support (4 November 2026)

- Replaced Android's debug-key release fallback with an external/default ignored properties-file configuration. Explicit release requests without credentials fail before resolving release dependencies; task-graph checks also cover aggregate requests. Debug configuration remains usable without credentials. This prevents an unsigned or debug-signed release from silently passing as a consumer build.
- `tools/build_android.ps1` now requires a trusted public signer fingerprint, builds ARM64 only using existing dependencies, and invokes `tools/verify_android_apk.ps1` before copying outputs to `dist/`. Verification checks Android signatures, expected certificate, debug-certificate exclusion, final package ID, source version name/build code and ARM64 architecture. It handles the different certificate-output formats in SDK build tools 36 and 37; the real fixture run used 37.0.0.
- Added `tools/setup_android_signing.ps1`: private terminal password prompts, an external account-restricted directory, RSA 4096/PKCS12 key generation, public fingerprint export and escaped Java properties. It refuses repository paths and existing directories. Owner confirmed this will be the first release key; the script has not been run to create that real owner key.
- `./tools/test_android_signing.ps1 -JavaHome 'C:/Program Files/Android/Android Studio/jbr' -CheckGradleConfiguration -CheckSetup`: **14 checks passed**. Tests use disposable keys and metadata-only APK fixtures: valid signature/metadata; wrong pin; wrong version code/name; unsigned/tampered APK; debug certificate; external Gradle properties with relative keystore; missing-key rejection in Gradle and packaging; setup permissions/fingerprint; setup-generated password escaping loaded through Gradle; refusal of existing/repository directories. Temporary keys and properties were deleted after each run. No installable Hopboard APK or owner signing key was created.
- `./android/gradlew.bat -p android :app:processDebugMainManifest --offline --console=plain` with the existing JBR and `.tools/gradle` cache: **passed**, without release credentials. Explicit missing-key release rejection was also observed with `:app:assembleRelease --dry-run`. Initial checks found and corrected a Gradle `java.io.File` import issue, SDK 37 certificate-output parsing, and Windows PowerShell native-stderr handling in the test harness before the passing final checks.
- PowerShell scripts parsed successfully; signing-file/keystore ignore rules, Markdown relative file links/fences and `git diff --check` checked. Added `/android/build/` to ignore generated Gradle reports. No Flutter application logic changed in this signing work; the full application suite was not repeated.
- [Maintainer tutorial](docs/tutorial/release-signing.md) and [release preparation](docs/RELEASING.md) document manual setup, ownership, example version changes, verification and remaining gates. Owner password entry, backup/restore, an actual release-signed Hopboard build and physical install/upgrade remain unverified. No PDF export was produced; document-export dependencies are not installed.
- Reviewed current [SignPath conditions](https://signpath.org/terms). `gh repo view Azrinfreeman/hopboard --json isPrivate,url,licenseInfo` confirmed a public repository with no currently detected remote licence. MIT is still a local change. MFA/roles, licence/dependency review, verifiable CI and project acceptance remain open. No SignPath application, external message, workflow execution, commit, push, tag or publication was performed; Windows remains unsigned.

## Approved release identity and licence (4 November 2026)

- Applied `io.github.azrinfreeman.hopboard` in `android/app/build.gradle.kts`; retained Kotlin namespace/package `dev.localclipboard.local_clipboard`. Added root `LICENSE` with MIT terms and copyright `2026 Azrinfreeman`, and updated README, status, decisions and device worksheet. Earlier development APKs are a separate installation; pairings are not migrated.
- Ran `./android/gradlew.bat -p android :app:processDebugMainManifest --console=plain` using the existing Android Studio JBR, project Android SDK environment and `.tools/gradle` cache: **passed**, 2 minutes 39 seconds. The first offline attempt failed because the Kotlin DSL plugin was not cached; normal dependency resolution succeeded. No dependency versions were changed.
- Inspected `build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml`: package is `io.github.azrinfreeman.hopboard`, activity remains `dev.localclipboard.local_clipboard.MainActivity`, and generated provider authorities use the new application ID. This is manifest processing only; no APK compilation, installation or device acceptance was performed. Existing Gradle/Kotlin deprecation warnings remain.
- Checked application ID, unchanged namespace, licence holder, relative documentation file links, balanced code fences and `git diff --check`: **passed**. No gameplay or clipboard behavior changed; the full Flutter suite was not repeated for this configuration/documentation change.
- SignPath Foundation is the approved route to explore. No application was submitted, eligibility established, certificate obtained or signing configured. Android still uses development signing. Existing Windows candidate assets were not rebuilt and remain unsigned. No commit, push or publication was performed.

## Device-test candidate (4 November 2026)

- Source version advanced to `0.2.2-rc.1+7`; peer-advertised version is `0.2.2-rc.1`. This is an uncommitted local candidate based on `c17d317bb5a3e8287dd1cb5d201c8d291d08348b` plus working-tree changes, including the prior direct-paste work. It is not a clean committed release snapshot.
- Baseline `D:/flutter-3.47.6/flutter/bin/flutter.bat test --no-pub --exclude-tags large`: **126 tests passed**, 36 seconds. Baseline `flutter.bat analyze --no-pub`: **no issues**, 36.9 seconds. These checks started before the version-only change; afterward `flutter.bat test test/update_test.dart --no-pub`: **4 passed**. The large transfer was not rerun; transport behavior was not changed.
- `flutter.bat build windows --release --no-pub`: **passed**, 60.9 seconds. Executable product/file string verified as `0.2.2-rc.1+7`.
- `./tools/build_windows_installer.ps1 -SkipBuild`: **passed**, using existing Inno Setup 6.7.3. Output: `dist/Hopboard-Setup-0.2.2-rc.1-x64.exe`, **11,432,823 bytes**. SHA-256: `288e45266f42ffce38e6d6df8ec58e9582d7a9451e889ca176fefa28fc15d8ce`; recomputed hash matches the adjacent `.sha256` file. All **13** files in the release bundle match installer staging; all three required x64 Visual C++ runtime DLLs are present.
- Installer is **unsigned**. No installer launch, running-app replacement, OS clipboard manipulation, commit, tag, push or release publication was performed. Existing local scripts and dependencies were used without installation or upgrades.
- Project ADB `devices -l`: no attached Android devices. No Android build was produced in this session; final package ID and release signing remain open. No physical-device outcome can be inferred from these automated checks.
- Prepared [device-test-checklist.md](docs/testing/device-test-checklist.md); all Windows and Android rows remain **not run**. Gate G1 remains open. Both history features remain planned after that gate, with sensitive-marker preservation required through the host relay and unsupported peers handled conservatively.

## Android emulator and background receive (5 November 2026)

- Added background receive (foreground service plus a background clipboard write), phone return-apply, and three Android fixes found on the emulator: first-connection text no longer blocks automatic receive, a phone no longer echoes its own clipboard write back to the PC, and a launch-time focus refusal is retried. Version `0.2.2-rc.3+9`.
- `flutter test --no-pub --exclude-tags large`: **142 tests passed** (126 before; 16 new in `test/background_receive_test.dart`). `flutter analyze --no-pub`: **no issues**.
- Release-signed ARM64 APK built and verified with the owner key (package `io.github.azrinfreeman.hopboard`, versionCode 2009, signer SHA-256 `9a2bdc94972cbb1a2d58030056c5cf891bc97969c47d6e91ee96fcdcab305ecd`). Windows installer `Hopboard-Setup-0.2.2-rc.3-x64.exe` built; checksum matches; unsigned.
- Emulator run (Android 17, ARM64 translation, stand-in PC over the LAN): pairing, B1 and the hidden-app write passed; details and gaps are in [the checklist](docs/testing/device-test-checklist.md). **Not performed:** the Xiaomi tablet, locked-screen receive, Pause/Stop, notification denial, battery, and real Wi-Fi. The emulator shares its clipboard with this computer, so test text may have reached the host clipboard.
## Direct-paste setup and feedback (3 November 2026)

- Reproduced stale `Ready to paste` after pause and automatic-mode changes with two failing controller tests before the fix. Both pass after invalidating the old confirmation status. No fresh automatic-write failure was reproduced; the native bridge and automatic receive/write path were reused.
- Added four controller cases: two successive host copies without manual Copy (confirmed clipboard text and `applied` receipt), receiver disabled then enabled (no historical write), and pause/mode transitions followed by a fresh confirmed copy. Readiness assertions also cover a new private local copy, leaving, and failed confirmation.
- Added received-item consent coverage (cancel, keyboard activation, persisted enablement, no manual/historical copy). Extended ready/protected/failure widget coverage at 1440 and 390 logical pixels, including 2× text scaling at 390 pixels. Existing switch-consent and privacy/race tests remain green.
- `D:/flutter-3.47.6/flutter/bin/flutter.bat test --no-pub --exclude-tags large`: **126 tests passed** in 37 seconds. The unchanged large-transfer test was excluded.
- `D:/flutter-3.47.6/flutter/bin/flutter.bat analyze --no-pub`: **no issues**.
- `D:/flutter-3.47.6/flutter/bin/flutter.bat build windows --release --no-pub`: **passed** in 42.7 seconds; output `build/windows/x64/runner/Release/local_clipboard.exe`. The executable was not launched and the installed app was not replaced.
- Final `git diff --check`, Dart formatting check, relative documentation file links and balanced code fences: **passed**.
- Generated widget PNGs using `flutter test test/widget_test.dart --no-pub --plain-name "confirmed text offers" --dart-define=DASHBOARD_CAPTURE_DIR=E:/Projects/2026Projject/Hopboard/artifacts/direct-paste` and the same command with `--plain-name "received text offers"`. Inspected the desktop ready, narrow 2× ready, and narrow 2× setup captures in `artifacts/direct-paste/`. These use controlled test state, not two live PCs; the changed controls wrap without overflow. Existing header text wraps at the largest narrow scale.
- **Not performed:** installed-app/version/settings inspection, native clipboard manipulation, or physical two-PC Notepad/tray acceptance. No dependencies or package/protocol versions changed. Installer/release publication is outside this implementation.

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
