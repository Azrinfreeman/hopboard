# Physical-device acceptance worksheet

Status: updated 5 November 2026. The owner reports PC-to-tablet text receive working on rc.3 (text only). Full acceptance rows remain open; D20 sending needs rc.4 tablet checks.

Use the Windows candidate `0.2.2-rc.3+9` on both PCs. It includes the existing direct-paste changes; neither history feature is implemented. The final Android package ID is `io.github.azrinfreeman.hopboard`; Android D20 candidate `dist/Hopboard-Android-arm64.apk` is release-signed rc.4 (version code 2010); install it over rc.3, preserving pairing. See [the key-setup tutorial](../tutorial/release-signing.md). A debug-signed APK is not a consumer release candidate.

## Prepare

1. Copy `dist/Hopboard-Setup-0.2.2-rc.3-x64.exe` and its adjacent `.sha256` file to each PC. Check the downloaded/copied file with `Get-FileHash -Algorithm SHA256` and compare it with the checksum file. Keep both PCs on the identical candidate.
2. Record the OS version, device model, app version and settings below. Connect both devices to the same trusted Wi-Fi. Do not disable the firewall; allow Hopboard on the intended private network if Windows prompts.
3. Quit the installed Hopboard using its tray menu before installing. Closing its window leaves it running. The candidate is unsigned; record any Windows prompts accurately.
4. Use disposable test data such as `hopboard-test-A`, `hopboard-test-B`, and `hopboard-test-C`. Never put real passwords or confidential data into a test report. For privacy tests, use harmless content from a tool that marks its clipboard copy private.
5. Run Windows rows with each PC as host, then Android rows with each device as host where supported. The exact scenarios and expected results are in [the implementation matrix](../../IMPLEMENTATION.md#13-the-matrix).

PowerShell checksum check (run from the folder containing both files):

```powershell
$candidate = 'Hopboard-Setup-0.2.2-rc.3-x64.exe'
$expected = ((Get-Content -LiteralPath "$candidate.sha256" -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
if ($actual -ine $expected) { throw 'Candidate checksum mismatch' }
'Candidate checksum matches'
```

The local candidate build and checksum are recorded in [VALIDATION.md](../../VALIDATION.md). The copied-file check on a second PC, installation and the manual steps here remain untested until a tester fills in the results.

## Test run

- Date and tester: pending
- PC A model / Windows build / app version: pending
- PC B model / Windows build / app version: pending
- Android model / maker / OS / package ID / app version / certificate fingerprint: pending
- Network type / VPN enabled / isolation enabled (no addresses or network names): pending
- Automatic sharing / image consent / file consent / Windows history settings: pending
- Candidate SHA-256 on each device: pending

Use `pass`, `fail`, `limitation`, or `not run`. For each result, record host/client roles, settings, elapsed time where relevant, and a short observation without clipboard contents, personal device names, addresses or file paths. A limitation requires explicit acceptance before Gate G1 can pass.

## Windows results

| Row | Result | Roles, settings and observation |
| --- | --- | --- |
| W1 Install / upgrade | not run | |
| W2 First run / discovery / firewall | not run | |
| W3 Pairing / decline / manual address | not run | |
| W4 Two fresh direct pastes, tray and open window | not run | |
| W5 Startup / private / paused / disconnected protection | not run | |
| W6 Text limits / rapid copies / Unicode / Office | not run | |
| W7 Image and mixed content | not run | |
| W8 Files / folders / size limits | not run | |
| W9 Network loss during idle and transfer | not run | |
| W10 Disk-space refusal | not run | Use a disposable test volume; preserve normal user data. |
| W11 Clipboard contention | not run | Planned contention helper is not yet implemented. |
| W12 Sleep / resume / network changes | not run | |
| W13 Tray / Pause / Quit / second launch | not run | |
| W14 Eight hours / 500 transfers | not run | Record working set and handle count over time. |
| W15 Uninstall / retained settings | not run | Run last on a spare test installation. |
| W16 Published update | not run | Release-time check; no candidate was published. |
| W17 Current Win+V exclusion baseline | not run | No history feature is present in this candidate. |

Start with W1–W5 on two PCs; investigate any wrong content, lost content, private publication, crash or reconnect failure before continuing. W11 needs a reviewed contention helper or a controlled native integration test; do not treat it as passed from unit tests.

## Android results

| Row | Result | Roles, settings and observation |
| --- | --- | --- |
| A1 Release-signed installation | not run | Final ID chosen; waiting for release signing setup. |
| A2 Permission denial / recovery | not run | |
| A3 QR / code / discovery / manual address | not run | |
| A4 Foreground receive / paste | not run | |
| A5 Paste & Send / typed send | not run | |
| A6 Background / lock / return / tap counts | not run | |
| A7 Phone hosting / foreground requirement | not run | |
| A8 Wi-Fi / airplane-mode recovery | not run | |
| A9 Battery saver / OEM restrictions | not run | Informational. |
| A10 Mixed application versions | not run | |
| A11 Private clipboard / preview protection | not run | |
| A12 Release-signed upgrade / uninstall | not run | Needs a prior build with the same final ID and signing key. |
| A13 Rotation / split-screen / large text | not run | |

Before attaching logs, inspect them for personal information. `adb devices -l` identifies attached devices; it does not establish installation or any clipboard behavior. This session found no attached Android device on 4 November 2026.

## Triage and handoff

Record defects in [VALIDATION.md](../../VALIDATION.md), with row, device/OS/app versions, roles, steps, expected behavior, observed behavior and severity. Keep one authoritative results record there; this worksheet supports each test run.

Gate G1 remains open until the [required rows](../../IMPLEMENTATION.md#15-gate-g1) have results and zero P0 defects remain. History rows W18–W25 and H1–H5 are future acceptance checks after implementation; do not run them against this baseline candidate.


## Android background receive (candidate 0.2.2-rc.2, Xiaomi tablet, Android 14)

Install `dist/Hopboard-Android-arm64.apk`. Join your PC, turn on **Automatic clipboard sharing**, then turn on **Receive in the background** and allow notifications. Use harmless text such as `hopboard-test-A`. On Xiaomi, also open Settings > Apps > Hopboard and set Battery saver to **No restrictions**, and allow **Autostart**; record every extra permission it asks for.

| ID | Scenario | Pass when | Result |
| --- | --- | --- | --- |
| B1 | App open: copy on the PC, paste in another tablet app | Pasted without tapping Copy | |
| B2 | Close the app with Back (not Recents), copy on the PC, open the app within 5 minutes | Latest item already on the clipboard | |
| B3 | Background mode on, press Home, screen off and locked: copy on the PC, unlock, paste | Text pasted; Hopboard was never opened | |
| B4 | Swipe Hopboard from Recents, then copy on the PC | Expected to stop receiving (the notification disappears); record what happens | |
| B5 | Wi-Fi off and on, and airplane mode on and off, with the app hidden | Reconnects; no old item written | |
| B6 | Leave idle overnight, copy on the PC in the morning | Still connected or recovered; note battery percentage used | |
| B7 | Deny the notification permission when turning the mode on | Clear message; the switch stays off | |
| B8 | Tap **Pause** then **Stop** in the notification | Copying stops at once; Stop turns the mode off | |
| B9 | Copy twice quickly on the PC; copy something on the tablet, then copy on the PC | Latest PC text wins; a newer tablet copy is kept and a "waiting" notice appears | |
| B10 | Note if the item arrives while the screen is off but not when Xiaomi battery saver is on | Behaviour recorded | |

If B3 fails with the message "Android blocked copying while Hopboard is in the background", Xiaomi or Android 14 blocks background clipboard writes. Report it; the planned fallback is a notification action.


### Emulator results (5 November 2026, candidate 0.2.2-rc.3)

Run on the Android 17 emulator `Medium_Phone_API_37.0` (x86_64 image running the ARM64 APK), paired over the LAN with a stand-in PC (`tools/emulator_host_harness.dart`: the real host and controller with a fake clipboard, so no real PC clipboard was touched). This is not a substitute for the Xiaomi tablet: the emulator has no Xiaomi battery layer, and it shares its clipboard with the host computer.

| Row | Result on the emulator |
| --- | --- |
| A2 / A3 | Pairing by code and host address worked. Android 17 showed its own "Choose a device to connect" picker and a "find, connect to, and determine the relative position of nearby devices" prompt when connecting. Both are expected on this version. |
| B1 | Passed after two fixes (below). PC text reached the phone, status "Ready to paste", item shown as from the PC. |
| B3 (Home) | Passed. With the app hidden, the foreground service ran (type connectedDevice), a "Copied from Test PC" notice appeared without text, and pasting into Settings search produced the PC text. |
| B3 (screen off) | Not completed: the stand-in host reached its time limit during the test. Repeat on the tablet. |
| B4, B5, B6, B7, B8, B9, B10 | Not run on the emulator. Run on the tablet. |

Defects found by the emulator and fixed: (1) any text already on the phone clipboard blocked the first automatic receive until Copy was tapped (the Windows-only startup rule now also covers Android); (2) the phone treated its own clipboard write as a new copy and sent it back to the PC (identical received text is now recognised as its own write, and the native marker is set even if Android strips it); (3) a clipboard check refused just after launch because the window had no focus was never retried (now retried for about ten seconds).


## Android to PC: D20 acceptance on the Xiaomi tablet

Use Android rc.4 with the existing Windows rc.3 host. Follow [Android sending](../tutorial/android-send.md). These are physical-device rows; emulator and controller results do not count as tablet passes. Record the Android/Xiaomi version and the actual source apps used. D21 starts only after D20 works here.

| Row | Scenario and expected behavior | Tablet result |
| --- | --- | --- |
| E1 | Select text in Chrome and Notes; Share, then Hopboard. PC receives, clipboard stays unchanged, previous app returns. Also try Hopboard in the text-selection menu where supported. | not run |
| E2 | Enable automatic sharing, Background receive and notifications. Copy in another app, expand Hopboard's connection notification, tap Send to PC. PC receives; brief focused screen closes. | not run |
| E3 | Copy harmless text marked sensitive by a password manager. Notification sends nothing and explains why. Explicit Share can send deliberately selected text. | not run |
| E4 | PC sends to tablet; tap Send to PC without making another copy. Nothing echoes back. Then make a fresh local copy and send it; a subsequent PC copy should arrive automatically. | not run |
| E5 | PC off/disconnected; Share and notification show a clear failure, no success message, no silent queue or crash. Reconnect and send deliberately again. | not run |
| E6 | Empty text and text over 64 KiB UTF-8 are refused. Ordinary multibyte text is sent unchanged. | not run |
| E7 | Share while Hopboard was closed, then while Background receive is off. Saved-host reconnect sends once and returns. Check your manual clipboard is preserved. | not run |
| E8 | Pause removes Send to PC and refuses Share until resumed. Stop removes the service notification. Share remains a deliberate reconnect action. | not run |

Owner report, 5 November 2026: **D20 works as intended** on the Xiaomi tablet. This accepts the main flow for proceeding to D21; individual E1-E8 edge-case results were not supplied and remain unrecorded.

## Android D21 callback experiment (rc.5)

Use [the 60-second test instructions](../tutorial/android-send.md#try-the-d21-callback-test). Stay unlocked, keep the PC quiet, copy three different harmless texts in another app with Hopboard hidden for at least 15 seconds, then return and stop the test. No overlay permission or automatic focus-taking is included. Quick Settings tile D23 is not implemented.

| Row | Test | Background seconds / signals / focused / excluded | Result |
| --- | --- | --- | --- |
| S1 | Notes: three different copies; record app and Android/Xiaomi version | | not run |
| S2 | Chrome: repeat with three different copies | | not run |
| S3 | Let 60 seconds elapse; test stops and notification restores Send to PC | | not run |
| S4 | Stop test from notification, then Pause and Stop in separate runs | | not run |

Zero background signals with confirmed copies and sufficient hidden time means no trigger was observed in that configuration. Positive counts permit the overlay/focus spike but do not prove automatic sending. Delayed callbacks after returning to Hopboard count as focused, not background.

### Quick Settings tile (candidate 0.2.2-rc.6)

Turn on Receive in the background, then use **Add "Send to PC" tile** in Hopboard.

| ID | Scenario | Pass when | Result |
| --- | --- | --- | --- |
| T1 | Add the tile from the in-app button | System prompt shows the tile with an upward arrow; tile appears in Quick Settings | emulator: passed; tablet: not run |
| T2 | Copy text in Chrome or Notes, pull down the shade, tap **Send to PC** | Shade closes; "Sent to PC"; the PC has the text | emulator: passed; tablet: not run |
| T3 | Lock the tablet, tap the tile from the lock screen shade | Asks to unlock, then sends | not run |
| T4 | Stop background receive, then look at the tile | Tile is dimmed; tapping opens Hopboard | not run |
| T5 | Copy something a password manager marks private, tap the tile | Refused; nothing sent | not run |
| T6 | Tap the tile twice quickly, or with an empty clipboard | One send, or a clear message; no crash | not run |
