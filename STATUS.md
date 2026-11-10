# Project status

Current source: **0.3.1+16**. Published: Windows installer and release-signed Android ARM64 APK on the [v0.3.1 release](https://github.com/Azrinfreeman/hopboard/releases/tag/v0.3.1).

## Done

- Text sharing over the local network: pinned TLS, six-digit SRP pairing, host approval, mDNS discovery, automatic sync with conflict handling (Windows and Android; iPhone source included but never built).
- Windows images, mixed text and image copies, files, folders and ZIP packaging, with per-kind consent and a cleaned-up receive cache.
- Windows seamless clipboard: newest copy wins in both directions, virtual files that stream while Explorer pastes, and HTML/RTF formatted text.
- Android explicit send (Share, Send to PC, Paste & Send). A background callback diagnostic exists for automatic sending.
- Security hardening and signed in-app updates for Windows (see the README).
- Android release signing with an owner-held key.
- 60-second trailer (`video/hopboard-trailer`, published at `docs/media/Hopboard-Trailer.mp4`).

Automated tests (176) cover the protocol, real loopback TLS, controller races and widget layouts.

## Physical testing

- Windows 0.3.1 installer and Android 0.3.1 release APK verified on physical hardware.

## Remaining & unverified

- Multi-PC continuous endurance, disk-full edge cases, and broad multi-device transfers.
- Extended Android background receive endurance across varied OEM battery optimizations.
- iPhone platform integration (source exists, needs Mac/Xcode and real device).
- No independent security audit. The Windows installer has no Authenticode signature, so SmartScreen warns.

## Roadmap & next milestones

1. **Android file and image sharing:** pickers, system share target, and receiving to app cache.
2. **In-app update cycle:** verify end-to-end signed update workflow when the next version (0.3.2) is published.
3. **Windows Authenticode code signing:** complete SignPath application to remove SmartScreen warnings.
4. **iOS / iPhone support:** Mac build pipeline, iPhone testing, and iOS share extension.
