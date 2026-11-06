# Project status

Last updated 5 November 2026. Current source: **0.2.2-rc.5+11**. Android candidate: `dist/Hopboard-Android-arm64.apk`, release-signed, version code 2011. Windows can keep using `dist/Hopboard-Setup-0.2.2-rc.3-x64.exe`; Windows was not rebuilt for this Android feature. Published Windows release remains v0.2.1.

D20 is accepted by the owner: Android sending works as intended on the Xiaomi tablet. Individual E1-E8 edge-case results were not supplied. The owner also confirmed PC-to-tablet **text-only** receive on rc.3. D21 now has a 60-second callback diagnostic in the Clipboard tab, with memory-only counts, separate stopped-activity/foreground events and a visible, stoppable notification. **162 Flutter tests and 5 native JVM tests passed** (Flutter excludes `large`); direct Dart analysis of `lib` and `test` is clean. The signed rc.5 APK's package, version, certificate and checksum were verified. Actual tablet callback counts and the later overlay/focus phase remain pending. See [the tutorial](docs/tutorial/android-send.md#try-the-d21-callback-test) and [validation](VALIDATION.md#android-d21-callback-diagnostic-5-november-2026). No overlay permission or automatic focus-taking was added: the experiment must first establish a usable trigger.

## Current work

- Seamless clipboard (Windows, not yet on two physical PCs): newest copy wins in both directions, one consent for text, images and files, virtual files that paste immediately and stream from Explorer, and HTML/RTF formatted text. 169 tests and a native paste harness pass. See [IMPLEMENTATION.md](IMPLEMENTATION.md#seamless-clipboard-newest-copy-wins-virtual-files-formatted-text) and [validation](VALIDATION.md#seamless-clipboard-7-november-2026).
- Both Windows Win+V integration and a separate Hopboard history are approved, with opt-in consent and sensitive-item exclusion. The app list is planned as text-first, memory-only and subject to original five-minute expiry. Neither feature is implemented; both follow physical acceptance Gate G1 in [IMPLEMENTATION.md](IMPLEMENTATION.md).
- Baseline rerun: **126 tests passed**, static analysis clean; candidate Windows release build and installer passed; **4 updater tests passed** after the version change. Exact checks and checksum are in [VALIDATION.md](VALIDATION.md#device-test-candidate-4-november-2026).
- [Physical-device worksheet](docs/testing/device-test-checklist.md) prepared; every row remains not run. No Android device was attached through the project ADB. Final Android ID `io.github.azrinfreeman.hopboard` and MIT licence are applied. SignPath Foundation is selected for eligibility review; Android release-key setup, SignPath application and signing integration remain open. No commits, publication, global git configuration or installed-app changes were made.
- Android release-signing support implemented: missing credentials stop release builds; packaging verifies the expected certificate, package, version and ARM64 ABI before copying an APK to `dist/`. A [first-key setup script](tools/setup_android_signing.ps1) and [maintainer tutorial](docs/tutorial/release-signing.md) are available. The owner confirmed this will be the first release key; the real key, backups, signed Hopboard APK and phone testing are still required. SignPath readiness is recorded in [RELEASING.md](docs/RELEASING.md).

## Done

- Direct-paste setup and feedback in the working source: Windows receivers can enable automatic sharing beside received text, consent explains enablement on both PCs, and confirmed text shows Ctrl+V guidance with optional **Copy again**. Fixed stale ready status across pause/automatic-mode changes. All 126 tests excluding `large`, static analysis and the Windows release build pass; physical two-PC acceptance remains open. This change is not in the published v0.2.1 installer. See [IMPLEMENTATION.md](IMPLEMENTATION.md#direct-paste-work).
- Text sharing over the local network: pinned TLS, six-digit SRP pairing, host approval, mDNS discovery, automatic sync with conflict handling (Windows and Android; iPhone source included but never built).
- Windows images, mixed text and image copies, files, folders and ZIP packaging, with a separate data connection, per-kind consent, a cleaned-up receive cache and automatic downloads up to 256 MiB.
- Update notice for older devices, and an Update button on Windows.
- Automatic clipboard contention recovery and separate write confirmation, with clearer manual-copy reasons. Version 0.2.0+5 passes 104 tests excluding the large transfer, static analysis, and the Windows release build. The user reports the preceding development installer works. Native contention and two-PC validation remain open.
- Automatic text replacement fix included in 0.2.1: ordinary Windows startup text accepts later fresh remote copies; matching publication acknowledgements release only their own temporary protection. Private/offline copies and real conflicts stay protected. Final 121 tests excluding `large`, static analysis and debug/release builds pass; an earlier full run also passed the 1 GiB relay. See [IMPLEMENTATION.notes.md](IMPLEMENTATION.notes.md) for validation and remaining two-PC checks.
- 60-second trailer ([`video/hopboard-trailer`](video/hopboard-trailer), published at `docs/media/Hopboard-Trailer.mp4`).

Automated tests cover the protocol, real loopback TLS, controller races and widget layouts. Results and commands are in [VALIDATION.md](VALIDATION.md).

## Not verified

Full physical-device acceptance remains incomplete:

- Two-PC Explorer and Office paste, transfer over real Wi-Fi with disconnects, disk full during a write, clipboard contention, and long-running endurance.
- Installing and upgrading from the 0.2.0-dev installer.
- Android D20 edge-case worksheet detail, D21 background callback counts on the Xiaomi tablet, background receive endurance and locked-screen cases. The owner reports D20's main flow and ordinary PC-to-tablet text receive working.

The installer is unsigned, so Windows SmartScreen warns. There has been no independent security audit.

## Next: Phase 4, phones

1. **Android:** image and mixed clipboard items (read only while the app is in front); **Send files…** and **Send folder…** pickers; a "Share to Hopboard" target; downloads go to the app cache, then **Save…**, **Share…** or **Copy** for a single file; receipts report `saved`, not "Ready to paste"; downloads pause when the app leaves the foreground and resume from where they stopped; Update button opens the APK download.
2. **iPhone:** Paste & Send accepts images, Copy puts a received image on the clipboard; document pickers to send; **Save to Files…** and **Share…** to receive. Needs a Mac, Xcode and a real iPhone.
3. Test on real phones: switching apps mid-transfer, a large file, and mixed versions in one session.

## Later

- iOS share extension.
- Code-signing the Windows installer and a signed Android release key.
- Rewrite the first section of `VALIDATION.md` for the current version.
