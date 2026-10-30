# Project status

Last updated 30 October 2026. Current source: **0.2.0-dev**. Published: [v0.2.0-dev pre-release](https://github.com/Azrinfreeman/hopboard/releases/tag/v0.2.0-dev) (Windows installer) and v0.1.2.

## Done

- Text sharing over the local network: pinned TLS, six-digit SRP pairing, host approval, mDNS discovery, automatic sync with conflict handling (Windows and Android; iPhone source included but never built).
- Windows images, mixed text and image copies, files, folders and ZIP packaging, with a separate data connection, per-kind consent, a cleaned-up receive cache and automatic downloads up to 256 MiB.
- Update notice for older devices, and an Update button on Windows.
- 60-second trailer ([`video/hopboard-trailer`](video/hopboard-trailer), published at `docs/media/Hopboard-Trailer.mp4`).

Automated tests cover the protocol, real loopback TLS, controller races and widget layouts. Results and commands are in [VALIDATION.md](VALIDATION.md).

## Not verified

No physical-device testing of the new features yet:

- Two-PC Explorer and Office paste, transfer over real Wi-Fi with disconnects, disk full during a write, clipboard contention, and long-running endurance.
- Installing and upgrading from the 0.2.0-dev installer.
- Anything on a real phone, including the Android APK.

The installer is unsigned, so Windows SmartScreen warns. There has been no independent security audit.

## Next: Phase 4, phones

1. **Android:** image and mixed clipboard items (read only while the app is in front); **Send files…** and **Send folder…** pickers; a "Share to Hopboard" target; downloads go to the app cache, then **Save…**, **Share…** or **Copy** for a single file; receipts report `saved`, not "Ready to paste"; downloads pause when the app leaves the foreground and resume from where they stopped; Update button opens the APK download.
2. **iPhone:** Paste & Send accepts images, Copy puts a received image on the clipboard; document pickers to send; **Save to Files…** and **Share…** to receive. Needs a Mac, Xcode and a real iPhone.
3. Test on real phones: switching apps mid-transfer, a large file, and mixed versions in one session.

## Later

- Windows virtual files, so pasting streams the files without a full download first.
- iOS share extension.
- Code-signing the Windows installer and a signed Android release key.
- Rewrite the first section of `VALIDATION.md` for the current version.
