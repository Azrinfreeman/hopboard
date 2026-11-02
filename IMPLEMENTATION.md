# Automatic clipboard reliability

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
