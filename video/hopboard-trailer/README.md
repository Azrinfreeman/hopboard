# Hopboard trailer

60 seconds · 1920×1080 · 30fps · English narration · original music and SFX.

```powershell
npm ci
npm run studio
```

Open http://localhost:3090/HopboardTrailer and press Space to play. The complete composition is available in Studio. Final video rendering awaits preview and destination approval, as required by the requested remotion-marketing-video skill.

After approval, `npm run render` and `npm run render:nobgm` generate H.264/AAC MP4s in `out/`. The second version retains narration and SFX. Final delivery must probe video frame count/duration, trim AAC mux padding to exactly60seconds if present, check audio peak, and extract frames from both outputs.

Text and scene timings: `src/timeline.ts`. Scene visuals: `src/scenes.tsx`. Brand tokens: `src/theme.ts`. Audio: `src/Main.tsx`, `audio-provenance.json`, `narration.json`. Optional subtitle file: `Hopboard-Trailer.srt`. Editable shotcraft manifest: `src/workbench.ts`.

`npm run check` checks TypeScript. `npm run stills` captures two keyframes per shot. Short QA motion renders, browser evidence, source-correlation audio timing measurements and frame captures live in `out/qa/`. `REVIEW.md` is the independent preview review.

Screenshots are actual Flutter widgets with fictional state, not physical-device recordings. Regenerate from project root:

```powershell
& 'D:\flutter-3.47.6\flutter\bin\flutter.bat' test --no-pub test/trailer_capture_test.dart --dart-define=TRAILER_CAPTURE_DIR=E:/Projects/2026Projject/LocalClipboard/video/hopboard-trailer/public/textures
```

`python scripts/assets.py` regenerates image crops, the original score and missing narration assets (requires numpy, Pillow, edge-tts and ffmpeg/ffprobe). Only the marketing script is sent to the narration provider. Product runtime code is unchanged.

Windows rich-content is explicitly marked development preview; Android demonstrations cover foreground text sharing. See `DESIGN-SPEC.md` for product boundaries and storyboard.
