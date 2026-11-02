# Automatic text replacement follow-up

Implemented 3 November 2026 against source version `0.2.0+5`, then packaged as `0.2.1+6` at the user's request. Release assets are distributed through [v0.2.1](https://github.com/Azrinfreeman/hopboard/releases/tag/v0.2.1). The running installation was not changed during verification.

## Behavior and ownership

[`lib/app/controller.dart`](lib/app/controller.dart) replaces the writable `_resumeGuard` flag with a private protection reason and clipboard revision. The existing dirty flag still tracks unpublished local changes. No preference or protocol changes are required.

- A successfully read Windows baseline containing ordinary text stays local during the initial snapshot. A later fresh remote text state may release only that startup protection. Existing epoch/sequence filtering rejects replayed or duplicate states.
- A matching publication acknowledgement releases only protection owned by that publication's current clipboard revision. A newer candidate, unread capture, private copy or explicit conflict blocks that release. The blocked item is not applied after acknowledgement; the next fresh remote copy follows normal eligibility checks.
- Baselines preserve changes made while sharing was off, paused or disconnected. Repeated baselines cannot erase that protection. Generation, connection and operation checks discard stale baseline results.
- Native expected-revision checks still preserve copies made immediately before a write. Manual Copy clears protection only after confirmed application. Send my text supplies the preserved snapshot's revision, so its acknowledgement cannot clear protection for a newer local copy.

The existing UI renders distinct reasons for inactive local edits, pending publication and unreadable clipboard state. Private content retains the neutral local-copy protection message. Startup image/file protection, category consent, limits and mobile startup policy are unchanged.

## Regression evidence

[`test/controller_test.dart`](test/controller_test.dart) reproduces both source failures: ordinary startup text blocked fresh reception in host and client roles; an overlapping remote state left protection behind after a successful local acknowledgement. All three acceptance tests failed against unchanged source and passed after the fix.

The acknowledgement test holds the host controller's response while the real loopback session continues broadcasting state. This supplies deterministic ordering without changing production transport or adding a production test hook. Additional tests cover private/image/file/unreadable startup content, reconnect and duplicate states, first enable/re-enable, paused edits, delayed baselines, stale acknowledgements before/after private-copy classification, rejected publications, and native revision rejection during startup replacement.

[`test/widget_test.dart`](test/widget_test.dart) checks protected, pending and ready statuses with Copy available at desktop and narrow widths, without writing the clipboard. Existing tests retain invitation isolation, capture/confirmation contention, no-echo behavior and write races.

## Verification

Commands use `D:/flutter-3.47.6/flutter/bin` and existing dependencies (`--no-pub`).

- Final `flutter test --no-pub --exclude-tags large`: **121 tests passed** (36 seconds), including 16 new controller regressions and one new widget test.
- `flutter analyze --no-pub`: **no issues** on the final source.
- `flutter build windows --debug --no-pub`: **passed**. Output: `build/windows/x64/runner/Debug/local_clipboard.exe`; keep the complete Debug directory together when running it.
- Earlier `flutter test --no-pub`: **121 tests passed** (2 minutes 44 seconds), including the unchanged 1 GiB relay. Final review then added a first-successful-baseline conflict check and regression, followed by the final non-large run above. The large transfer was not repeated after that controller-only refinement.

No production test hooks, new settings, dependencies or protocol changes were needed. Baseline context uses the existing observed revision and protection reason rather than a second session-history flag. The final refinement preserves an explicit typed-send conflict even when the first baseline read failed and a later read succeeds.

## Remaining acceptance

Two physical Windows devices are unavailable to this session. The real OS clipboard was not read or replaced. The source fix therefore has automated and build verification, but does not establish that it resolves the exact installed laptop incident.

Using matching candidate builds on both PCs, start with harmless old text on the receiver, connect with Automatic sharing enabled, and paste two fresh sender copies into Notepad without pressing Hopboard's Copy button. Repeat with the roles reversed and the receiver in the tray. Confirm that private copies and local copies made while disconnected/paused stay protected, then resolve deliberately with Copy or Send my text. Record versions, settings, status and pasted results without logging private content.

## Local release installer

The user subsequently requested a release installer. Version `0.2.1+6` was built with `flutter build windows --release --no-pub`, then packaged with `./tools/build_windows_installer.ps1 -SkipBuild` using Inno Setup 6.7.3. Output: `dist/Hopboard-Setup-0.2.1-x64.exe`, with an adjacent `.sha256` file. All four updater tests passed after the version change.

Verified executable version `0.2.1+6`, installer file version `0.2.1.6`, checksum equality, all 12 staged release files matching the release output, and inclusion of the three x64 Visual C++ runtime DLLs. The installer is unsigned and was not installed during verification. Quit Hopboard from its tray menu before installing; closing its window leaves it running. Use the same candidate build on both Windows PCs for the remaining manual acceptance checks.
