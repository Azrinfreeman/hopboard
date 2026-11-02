# Automatic text replacement: protected local-copy follow-up

Status: implemented in source, 3 November 2026. Final 121-test run excluding `large`, static analysis and Windows debug build pass. An earlier full 121-test run also passed the 1 GiB relay; one subsequent controller regression was added. Physical two-PC acceptance remains open. See [IMPLEMENTATION.notes.md](IMPLEMENTATION.notes.md). The completed 0.2.0 plan below is retained as historical context.

Contents: [Findings](#current-findings) · [Proposed behavior](#proposed-behavior) · [Work](#planned-work) · [Verification](#follow-up-verification) · [Limits](#limits-and-completion)

## Outcome

With automatic sharing enabled on both Windows devices, a fresh text copy on the PC should replace ordinary old clipboard text on the connected laptop and become ready to paste without pressing Copy. Keep genuine unresolved local changes protected.

The user's screenshot shows: “Your local copy is protected. Copy to replace it.” This confirms the receiving UI is reporting a protection decision. It does not identify which guard caused it or establish the installed versions and settings. The investigation below is grounded in checkout `5e6de46` (0.2.0+5), not a live trace from the laptop.

## Current findings

### Startup clipboard content can block every later incoming item

Before this follow-up, [`lib/app/controller.dart`](lib/app/controller.dart) used this in `_baseline()`:

```dart
_resumeGuard =
    _localDirty ||
    (_observedRevision == null
        ? snapshot.hasContent
        : snapshot.revision != _observedRevision);
```

Both `startHost()` and `_connect()` call `_baseline()`. Previously, existing startup text made `_resumeGuard` true, blocking incoming writes indefinitely. The new controller tracks the reason and revision, preserving the initial snapshot while allowing later fresh remote text to release ordinary startup protection. Tests reproduced the old failure in both receiving roles.

Consequently, ordinary text already on the laptop when it connects can prevent subsequent automatic replacement indefinitely. `_copyReceived()` clears both flags after a verified write, explaining why pressing Copy restores automatic reception. This is a confirmed source path and a likely explanation of the screenshot; it has not been reproduced on the user's laptop.

### A temporary local-send conflict can leave a stale guard

Previously, the incoming `state` handler set `_resumeGuard = true` when `_localDirty`, `_pending`, or `_candidate` was present. The matching `ack` handler cleared `_localDirty` without clearing that guard.

A controlled held-ack test reproduced this stale guard against unchanged source. The fix releases only protection owned by the acknowledged clipboard revision, with no newer candidate or unresolved capture. Rejected publications and newer private copies remain protected. The previously blocked remote item is not applied retroactively.

### The same message also covers legitimate protection

`_manualCopyReason()` reports the same text for several states. Private copies, invitation copies, offline local edits, pending publication, native revision rejection, and an unreadable baseline can all require protection. `_clipboardChanged()` marks an external revision dirty before checking privacy, connection readiness, and publishability. These paths must remain distinguishable from harmless startup content.

The 0.2.0 fix addressed capture contention and verification retries; it deliberately preserved these guards. More retries alone will not resolve the startup policy. No evidence currently implicates transport loss or Windows focus handling in this screenshot.

## Proposed behavior

The following Windows policy was approved by the user's instruction to proceed and is implemented in source. It has not been deployed to the user's devices.

| Receiving state | Proposed result |
| --- | --- |
| Ordinary text already present before first connection | Keep it during the initial session snapshot; allow a later fresh remote text item to replace it automatically. Never publish the old text automatically. |
| Initial snapshot or duplicate/replayed state | Do not use it to release startup protection. |
| Matching local publication successfully acknowledged, with unchanged local revision and no newer candidate or explicit conflict | Release only protection caused by that publication. Permit the next fresh eligible remote item. |
| Private content, pairing invitation, offline/paused local edit, rejected publication, or simultaneous-send conflict | Preserve local content until an existing deliberate resolution or a valid later local publication resolves that specific protection. |
| Local revision changes during incoming preparation/write/confirmation | Preserve the newer local copy. Keep native expected-revision checks. |
| Clipboard cannot be classified/read | Retain protection and show a read/confirmation reason; a successful retry may resolve uncertainty only after classification. |

Apply the startup relaxation only to confirmed ordinary text on Windows. Keep current mobile behavior, image/file consent, file limits, and protections for other baseline content. Automatic mode already authorizes replacement by new remote copies; do not add another setting or clear all protections whenever a message arrives.

First-time enabling of Automatic sharing follows the same ordinary-text policy. If already connected, preserve the clipboard and currently displayed item at enable time; only a later live state newer than the captured epoch/sequence boundary can release ordinary-baseline protection. Re-enabling after a local change while automatic mode was off must preserve that offline-style local protection; classify the revision change before resetting any dirty flag. Unpausing and reconnecting retain the existing offline-local-copy policy.

## Planned work

### 1. Reproduce the two guard paths

- [x] In [`test/controller_test.dart`](test/controller_test.dart), build a startup case with non-empty ordinary text before the first host/join baseline. The current fixture pairs two initially empty `FakeClipboard` instances and misses this condition. Reuse [`test/support.dart`](test/support.dart); add only narrowly needed controls.
- [x] Verify that startup text is not sent, the initial snapshot leaves it intact, and a later PC copy currently produces the protected status instead of updating the laptop clipboard. Test both host/client receiving roles.
- [x] Add controlled publication/ack ordering to reproduce an incoming remote item while a local send is pending, followed by a matching ack. Avoid delay-based guesses. Verify the guard remains stale only when no actual publication conflict remains.

Verification completed: both startup acceptance cases and the controlled acknowledgement overlap failed against unchanged source and pass with the fix.

### 2. Give protection a reason and revision

Location: guard fields, `_baseline()`, `_clipboardChanged()`, `state`/`ack` handling, `_queueApply()`, `_copyReceived()`, `copyInvitation()`, `sendMine()`, and lifecycle/settings transitions in [`lib/app/controller.dart`](lib/app/controller.dart).

- [x] Introduce a small private protection reason and associated clipboard revision where needed. Distinguish ordinary startup text, unresolved local copy/publication, explicit conflict, private/invitation content, and unknown clipboard state. Audit every existing assignment to `_resumeGuard` and `_localDirty`; avoid a second competing guard mechanism.
- [x] Capture first-baseline versus reconnect/resume context explicitly. Preserve offline changes across repeated baselines; a second baseline with the same revision must not accidentally erase a real guard. A failed read must not be classified as ordinary startup text.
- [x] Classify ordinary startup text from a successful snapshot: non-empty text, no image/files, not sensitive, and no existing explicit protection. Do not send that snapshot. Retain its protection for the initial session state.
- [x] For a genuinely newer live remote text state, release only ordinary-startup protection. Use the existing `initial`, epoch and display-sequence handling to reject snapshots, duplicates and stale states. Preserve native expected-revision checks against the baseline revision, including if a local event is still being read.
- [x] On matching publication acknowledgement, release only publication-owned protection for the acknowledged current revision, with no newer candidate, unresolved capture, or explicit conflict. A stale ack cannot release a newer private/local guard. Do not automatically apply the previously blocked remote item after ack; the next fresh remote item exercises normal receive eligibility.
- [x] Ensure manual Copy and Send my text resolve only the intended current conflict. Preserve cancellation checks across pause, leave, mode changes, expiry and disposal. Baseline reads must not commit stale results after such transitions.

Verification: startup regression and confirmed overlap regression pass; existing privacy, offline-copy, invitation, contention, and revision-race tests continue to pass. No echo publication or older clipboard overwrite is introduced.

### 3. Show an actionable reason for remaining manual cases

Location: `_manualCopyReason()` and receive status handling in [`lib/app/controller.dart`](lib/app/controller.dart); existing presentation in [`lib/app/ui.dart`](lib/app/ui.dart) only if necessary.

- [x] Report the actual reason without exposing clipboard contents: for example, “Local copy made while disconnected. Copy to replace it.” Use a neutral protection message for private content, and a separate message for clipboard read failure.
- [x] For a pending ordinary publication, show that it is waiting for the local send rather than implying a permanent conflict. Clear stale status when that specific condition resolves.
- [x] Extend [`test/widget_test.dart`](test/widget_test.dart) for remaining protected states and Copy availability using the existing layouts and scaling checks. Successful fresh reception must show Ready to paste.

Verification: automatic startup reception needs no click; deliberately protected content retains Copy and the existing explicit conflict actions, with accurate status.

### 4. Record validation and update behavior documentation

- [x] Update [`README.md`](README.md) to distinguish preserving the initial clipboard from accepting later fresh remote text. Explain the remaining deliberate manual cases.
- [x] Update [`VALIDATION.md`](VALIDATION.md) with actual test commands/results and remaining device checks. Update [`STATUS.md`](STATUS.md) when implementation status changes. Keep this plan's checkboxes evidence-based.
- [x] Record material deviations and the final verification outcome in [`IMPLEMENTATION.notes.md`](IMPLEMENTATION.notes.md).

## Follow-up verification

Regression checks, static analysis and the Windows debug build have run using the existing SDK at `D:/flutter-3.47.6/flutter`. Final commands and results are recorded in [IMPLEMENTATION.notes.md](IMPLEMENTATION.notes.md) and [VALIDATION.md](VALIDATION.md). The physical checks below remain open.

```powershell
flutter test test/controller_test.dart test/widget_test.dart --no-pub
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --debug --no-pub
```

Required regression scenarios and expected results:

- Start the receiver with ordinary old text: initial state preserves it; two subsequent fresh remote copies each reach the clipboard without Copy; old text is never published.
- Enable Automatic sharing for the first time while connected with old text and an existing displayed item: neither is copied/sent at enable time; the next fresh remote text applies. Disable automatic mode, make a local copy, then re-enable: preserve that intervening local copy.
- Start with an existing host item, then reconnect and replay/duplicate it: it cannot be mistaken for a fresh live copy that releases startup protection.
- Copy locally while disconnected or paused, resume/reconnect, and receive new text: retain local protection and explicit resolution.
- Exercise sensitive text, copied invitation, images/files at startup, disabled automatic mode, and category consent: retain existing behavior.
- Delay a local publication ack and interleave a remote state: after a matching successful ack, the next remote copy applies only when no genuine conflict/newer local copy remains. Repeat with a stale ack and a newer private copy: private content survives.
- Change the clipboard immediately before the native write or during confirmation: the newer local copy survives; the item is not falsely reported as applied.
- Make baseline reads busy/fail or delay them across lifecycle changes: retain protection without misclassifying startup content or committing a stale baseline.
- Retain the existing 600 ms capture/confirmation recovery and no-echo tests from 0.2.0.

On two Windows PCs using matching candidate builds, start the laptop with harmless pre-existing Notepad text, connect with Automatic sharing enabled, then copy two new texts on the PC. Paste each into Notepad on the laptop without touching Hopboard's Copy button. Repeat with receiver roles reversed and the receiver minimized/in the tray. Repeat the offline-local-copy and private-copy preservation cases. Record both versions, settings, sequence, status and pasted result; do not log private clipboard contents.

## Limits and completion

This follow-up changes the controller, regression tests and behavior/validation documentation, and produces a local Windows debug build. No installer, commit, push, release or installed app was updated.

Subsequent packaging/distribution request: a `0.2.1+6` release installer was built and verified for [v0.2.1](https://github.com/Azrinfreeman/hopboard/releases/tag/v0.2.1). See [IMPLEMENTATION.notes.md](IMPLEMENTATION.notes.md#local-release-installer). It was not installed during verification.

Both source failures were reproduced and fixed with controlled adapters over real loopback TLS. The exact laptop trigger remains unverified because the screenshot does not expose protection state or timing. Private/offline content and rejected publications retain protection in the regression checks.

This change affects how old ordinary Windows text is treated after first connection. No preference, protocol or pairing migration is required. Automated implementation checks are complete; physical acceptance remains open:

- [ ] Run the two-PC copy/paste checks above with matching candidate builds, including reversed roles, tray operation and private/offline-copy preservation.

---

# Previous plan: automatic clipboard reliability (0.2.0)

Status: implemented in source; automated checks pass. Native contention and two-PC validation remain open. Investigation and implementation date: 3 November 2026.

Contents: [Objective](#objective) · [Findings](#investigation-findings) · [Behavior](#intended-behavior-and-boundaries) · [Implementation](#implementation-steps) · [Commands](#verification-commands) · [Physical checks](#physical-acceptance-checks) · [Risks and completion](#risks-recovery-and-completion)

## Objective

Fix intermittent automatic sharing between a Windows PC and a Windows laptop so supported new copies reach the receiving Windows clipboard without clicking Hopboard's Copy button, when automatic sharing is enabled and no local-copy conflict exists.

The reported symptom can occur at two boundaries: capturing the source clipboard and applying an item already visible in the receiving app. This plan covers both. It assumes both devices run Windows; their installed versions, settings, and exact failure sequence have not been inspected.

## Investigation findings

The findings below describe the original `0.2.0-dev+4` source before this fix. The two transient failure paths were subsequently reproduced with controllable adapters, not on the user's devices. References use function names so they remain useful as line numbers change.

### 1. A transient capture failure can lose the only notification

In [`lib/app/controller.dart`](lib/app/controller.dart), `_clipboardChanged()` attempts a read four times, with delays of 30, 60, 90, and 120 milliseconds after failures. If every read fails, it returns without explaining the failure or scheduling further recovery. `_clipboardReadAgain` only helps when another event arrived during the read.

In [`windows/runner/clipboard_bridge.cpp`](windows/runner/clipboard_bridge.cpp), `readClipboard` reports `busy` when the clipboard cannot be opened or an image conversion is already active. `WM_CLIPBOARDUPDATE` forwards events, but there is no later reconciliation for an exhausted capture attempt. A source application holding the clipboard beyond this short retry window can therefore leave a copy unsent until another event or a manual send.

Confirmed: this failure path exists. Unverified: whether it caused the reported incident.

### 2. Write and verification retries share an obsolete revision

In `_queueApply()`, `_writeItem(current, expectedRevision)` and `_readApplied(current)` run inside the same retry block. If the write succeeds but the verification read throws, the next iteration repeats the write with the revision from before the successful write. The native write methods reject that stale revision. `_queueApply()` then sets `_resumeGuard = true` and leaves manual Copy as the recovery path.

`_copyReceived()` also needs a transient-safe verification read, although its write and verification are already outside one shared retry loop.

Confirmed: a successful write followed by a transient verification failure can take this path. Unverified: its frequency on real PCs. The clipboard may already contain the received item even when Hopboard reports that it needs attention.

### 3. Some manual-copy requirements are deliberate

`_baseline()` protects pre-existing clipboard content at connection/startup and local copies made while disconnected. `_clipboardChanged()` marks external copies as `_localDirty` before deciding whether they are publishable. Private content, Cut operations, unsupported content, and disabled content categories can leave local content protected. Incoming items cannot automatically replace it until the conflict is resolved. `_copyReceived()` clears those guards after an explicit, verified replacement.

These protections can explain why manual Copy restores subsequent automatic operation. They must not be removed wholesale. Their current status messages often say only “Tap Copy,” without identifying the actual reason.

`setForeground()` only changes lifecycle state for mobile devices. Losing Windows window focus alone is not established as the cause; Windows tray sharing is intended to continue.

### 4. Content settings and limits also affect automatic operation

`_autoAccepts()` requires automatic sharing plus separate consent for images or files. Files additionally require a positive auto-download threshold and a size within both that threshold and the item limit. The default auto-download threshold is 256 MiB; the default item limit is 4 GiB. A larger video can therefore appear in Hopboard and legitimately wait for Download/Copy.

Explorer-copied video files use the existing file-transfer path. Copying a video link shares text. Arbitrary embedded video objects and virtual clipboard files are not supported by the current Windows adapter. Images support PNG/DIB conversion; rich application formats are not reproduced with full original formatting.

## Intended behavior and boundaries

- Recover from temporary clipboard contention without requiring another copy or a manual button click.
- Verify a successful write without rewriting the same item using an obsolete revision.
- Preserve the newest local clipboard revision, private-copy exclusions, invitation-copy isolation, explicit conflict resolution, and existing consent/size limits.
- Never republish Hopboard's own writes or publish pre-existing content simply because the app starts, reconnects, resumes, or enables automatic mode.
- Give a specific reason when an item remains available only in the app: local copy protected, automatic category disabled, manual download threshold exceeded, unsupported content, or exhausted transient recovery.

No transport redesign, new clipboard-format support, mobile background access, dependency installation, installer execution, or release publication is included. The phrase “everything on the PC” is bounded by the formats and limits above.

## Implementation steps

Implementation was authorized with “proceed.” Checked tasks are implemented and supported by the verification record below; device-only checks remain open.

### 1. Reproduce transient failures with the existing test adapter

- [x] Extend [`test/support.dart`](test/support.dart) with controlled one-shot/count-based read and write failures and gates for delayed reads. Distinguish ordinary reads from verification reads. Keep the default fake behavior unchanged.
- [x] Add regressions in [`test/controller_test.dart`](test/controller_test.dart): a single copy whose read remains busy beyond the current retry window; an incoming write that succeeds followed by a busy verification read; and a later incoming copy that must still apply automatically.
- [x] Exercise the sequence with text first through the existing paired loopback controllers. Repeat the relevant cases for images and files after the text path works.

Verification: establish that the regressions fail against current behavior for the expected reason, then pass with the fixes. A successful write followed by a failed read must not be mistaken for a new user copy or trigger an echo publication.

### 2. Recover failed capture without sharing stale content

Location: `_clipboardChanged()`, capture state, and lifecycle cleanup in [`lib/app/controller.dart`](lib/app/controller.dart); error handling in [`lib/platform/clipboard_bridge.dart`](lib/platform/clipboard_bridge.dart) where needed.

- [x] Retry recognized transient native `busy` failures. Report permanent validation, size, and unsupported-content failures without retrying them as contention.
- [x] Keep the existing immediate attempts, followed by one cancellable recovery schedule with increasing delays and a proposed five-second overall deadline. Use one active capture worker; coalesce intervening events into a request to read the latest clipboard.
- [x] Associate recovery with the original eligible clipboard-change event and controller/connection generation. A fresh read determines the current revision; do not reuse an old payload. Recheck consent, pause state, connection readiness, own-write status, and privacy before publication.
- [x] Cancel obsolete recovery on newer events, pause, automatic-mode changes, leave, connection-generation changes, and disposal. Preserve existing offline/startup protection instead of turning recovery into a backlog uploader.
- [x] On exhaustion, expose a concise capture error and allow the next eligible copy to proceed normally. Clear only the recovered transient error after success.

Verification: a clipboard held busy for 600 milliseconds after one copy recovers within the proposed five-second deadline without another event. A newer copy supersedes the failed copy. Private or disabled-category content is never sent during recovery. Continued contention stops retrying at the deadline without a busy loop.

### 3. Separate clipboard writing from confirmation

Location: `_queueApply()`, `_copyReceived()`, `_readApplied()`, and `_fallbackMixed()` in [`lib/app/controller.dart`](lib/app/controller.dart).

- [x] Separate the write retry phase from the verification-read phase. After a write reports success, retry only verification reads for transient contention; never repeat that successful write with its pre-write expected revision.
- [x] Preserve native compare-and-set for every actual automatic write. A rejected revision requires re-reading/classifying the clipboard, not silently adopting the new revision and overwriting it.
- [x] Recheck current item ID, expiry, operation generation, sharing settings, and local-copy guards after asynchronous preparation and before writes or final status updates. An older queued operation must not update a newer item's status or receipts.
- [x] Confirm the existing own-write/content match before reporting “Ready to paste.” If a genuinely newer local copy appears, preserve it, classify its change, and report the conflict.
- [x] If verification remains unavailable after bounded recovery, report that clipboard confirmation failed. Do not latch a local-conflict guard solely because a read was busy. Reconcile before a later automatic write so an unknown intervening local copy remains protected.
- [x] Apply the same bounded verification handling to manual Copy. Keep mixed text/image fallback guarded against newer local copies.

Verification: inject failure only after a successful write, then allow reads. Expect one successful write, a confirmed `applied` receipt, no echo, and successful automatic application of the next item. A real user copy during verification must survive. Pause, Clear, expiry, and supersession must cancel stale work.

### 4. Explain protected or intentionally manual items

Location: receive eligibility in `_message()` and `_queueApply()` in [`lib/app/controller.dart`](lib/app/controller.dart), with presentation in [`lib/app/ui.dart`](lib/app/ui.dart) only where existing status presentation needs adjustment.

- [x] Preserve `_baseline()`, private-content protection, and intentional conflict guards. Audit their transitions with regressions rather than clearing `_resumeGuard` or `_localDirty` on a timer or on every incoming item.
- [x] Choose a specific status from the actual gating condition. Examples: “Your local copy is protected. Copy to replace it,” “Automatic image sharing is off,” and “Above your automatic download limit. Download to use files.” Keep the existing Copy/Download actions.
- [x] Distinguish capture failure, download failure, write failure, and verification failure. Reuse current error/status presentation; avoid new settings or a diagnostic dashboard.
- [x] Keep diagnostic messages free of clipboard text, image bytes, file names, and full paths.

Verification: extend [`test/widget_test.dart`](test/widget_test.dart) for the displayed reasons and actions. Check compact layouts and text scaling using existing test patterns. After explicit conflict resolution, a later eligible copy must apply automatically; the protected item itself must never be overwritten without that action.

### 5. Validate native behavior and document results

- [ ] Extend the existing Windows integration coverage where practical: real listener delivery, stale-revision preservation, and native busy error classification. Use controlled contention outside the app process for a real clipboard-lock test; a fake-only result does not establish native recovery.
- [ ] Run focused controller/widget tests, then the normal suite, static analysis, and a Windows debug build. Run native tests on a test desktop with Hopboard's existing instance closed deliberately; do not stop the user's running app automatically.
- [ ] Test on two Windows PCs with matching builds, recording versions, consent settings, auto-download threshold, host/client roles, and whether the failed item appeared in the receiving app before manual Copy.
- [x] Update [`VALIDATION.md`](VALIDATION.md) with actual commands/results and remaining physical checks. Update [`README.md`](README.md) for the new recovery behavior and manual-action explanations, and [`STATUS.md`](STATUS.md) only when the implementation status changes.

Existing local changes were present in `.gitignore`, `README.md`, and `VALIDATION.md` during inspection. Preserve those changes when implementation is authorized.

## Verification commands

Commands used for verification, with native commands retained for the controlled-device follow-up:

```powershell
flutter test test/controller_test.dart test/widget_test.dart --no-pub
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --debug --no-pub
flutter test integration_test/windows_smoke_test.dart -d windows --no-pub
flutter test integration_test/windows_files_test.dart -d windows --no-pub
```

Native clipboard tests can replace clipboard contents. Run them with disposable data in a controlled session. The existing file integration test restores supported formats, which is not a guarantee of restoring every application-specific format. Add the command for any new native test to this section when its file exists.

## Physical acceptance checks

- Copy text from Notepad and a browser, screenshots from Snipping Tool/Paint, and Explorer files/folders including a small video. Repeat in both directions with the apps visible, unfocused, minimized, and hidden in the tray. Eligible items must become ready to paste without manual Copy; paste them into an appropriate application and verify contents.
- Hold the clipboard busy for 600 milliseconds around capture and around incoming application, then release it. Eligible transfers must recover within the proposed deadline. Repeat with contention beyond the deadline: show an actionable status, stop automatic retries, and recover on the next eligible copy.
- Copy rapidly while image conversion or file preparation is pending. The newest eligible copy must win; no older payload may replace a newer local clipboard.
- Make a private copy, copy an invitation, disconnect and copy locally, then reconnect. Verify the local copy remains protected and Hopboard explains the required action.
- Disable image/file consent separately and test below, at, and above the configured file auto-download limit. Videos above the threshold must continue to require deliberate download.
- Pause, clear, expire, change consent, and disconnect during recovery/download/verification. No cancelled work may later replace the clipboard or report a stale item as applied.

## Risks, recovery, and completion

The main risks are sharing stale content during capture recovery and overwriting a newer local copy during apply recovery. Bound retries, cancel by generation, read the current revision, preserve native compare-and-set, and retain explicit privacy/conflict guards. Prefer focused controller changes; modify native contracts only if a reproduced case demonstrates that the existing result cannot distinguish the required outcome.

The five-second retry deadline is a proposed implementation default, to be checked against native contention tests. Installed-version mismatch, actual settings, and application-specific delayed rendering remain possible contributing factors until checked on the devices. Revisit the diagnosis if failures persist after the identified regression cases pass.

No preferences or protocol migration is planned. Roll back the focused code changes if they regress local-copy protection; users can pause automatic sharing and use manual actions while investigating. Do not delete received files or reset pairings as a troubleshooting step.

Completion of physical validation requires the two-PC acceptance checks above. The source fix and automated verification are complete; physical validation remains open.

### Implementation record

- Capture uses a single worker with cancellable generation checks and increasing busy-only retry delays, bounded to five seconds. Pending publication waits for classification of a newer clipboard event. Permanent failures are reported immediately.
- Automatic and manual writes have separate confirmation retries. Unconfirmed successful writes are reconciled before later automatic writes. Native revision checks, private-copy exclusions, existing consent, and local conflict guards remain in place.
- Existing status presentation now identifies protected local copies, disabled sharing categories, automatic download thresholds, and capture/write/confirmation failures. No new settings, dependencies, or native bridge contracts were needed.
- The original capture and text-confirmation regressions both failed before the fix. Final code passes 104 tests excluding the large transfer, static analysis, and the Windows debug build. An earlier full 99-test run also passed the unchanged 1 GiB relay; see [VALIDATION.md](VALIDATION.md) for exact scope.
- The native file test now includes listener delivery, but native tests were not run while the user's installed Hopboard process was open. No real clipboard access, external contention test, two-PC test, installer execution, or release publication was performed.
