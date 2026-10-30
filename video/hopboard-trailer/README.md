# Hopboard trailer

60 seconds, 1920×1080, 30 fps, English narration, original music and sound effects. Built with [Remotion](https://www.remotion.dev/).

```powershell
npm ci
npm run studio      # preview at http://localhost:3090/HopboardTrailer
npm run render      # out/Hopboard-Trailer-60s.mp4
npm run render:nobgm  # same, without music
npm run posters     # full-size stills in out/posters
```

- Scene text and timings: `src/timeline.ts`. Scene visuals: `src/scenes.tsx`. Colours and type: `src/theme.ts`. Audio mixing: `src/Main.tsx`.
- `python scripts/assets.py` regenerates the score, sound effects and narration (needs numpy, Pillow, edge-tts and ffmpeg). `audio-provenance.json` records where each audio asset comes from. Only the marketing script is sent to the narration provider.
- Screenshots in `public/textures` are real Flutter widgets with invented devices and content, not recordings of real devices. Regenerate them from the project root with `flutter test test/trailer_capture_test.dart --dart-define=TRAILER_CAPTURE_DIR=<this folder>/public/textures`.
- Windows image and file sharing is shown as a development preview; the Android scenes show foreground text sharing.
- `out/` is not committed. The published trailer is `docs/media/Hopboard-Trailer.mp4`.
