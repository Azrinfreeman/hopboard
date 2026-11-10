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

## Not verified

- Two-PC Explorer and Office paste, transfer over real Wi-Fi with disconnects, disk full during a write, clipboard contention and long-running endurance.
- Android background callback counts, background receive endurance and locked-screen cases on real devices.
- The rebuilt installer and APK on physical devices.
- No independent security audit. The Windows installer has no Authenticode signature, so SmartScreen warns.

## Next

1. Android image and file sharing (pickers, share target, receive to app cache).
2. iPhone support (needs a Mac, Xcode and a real iPhone).
3. Windows code signing (SignPath) and an iOS share extension.
