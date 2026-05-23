# HLS + TS Playback Teaching Video

This directory contains the teaching video source for `HLS + TS` playback flow.

Files:

- `DESIGN.md`: visual identity used by the composition.
- `index.html`: self-contained 1920x1080 video composition with HyperFrames-style metadata.
- `scripts/render-webm.mjs`: renders the canvas composition to `renders/hls-ts-playback.webm` using bundled Playwright.
- `renders/hls-ts-playback.mp4`: H.264 MP4 generated from the WebM with Homebrew FFmpeg.
- `renders/`: generated video output.

The Codex shell `PATH` did not include `/opt/homebrew/bin`, so `ffmpeg` was not found by `which ffmpeg` until called through its absolute Homebrew path. The local environment still does not provide `npx hyperframes`, so the render script uses browser `MediaRecorder` as a fallback. If HyperFrames CLI is installed later, `index.html` remains the source composition to port or preview.

Render:

```sh
/Users/leon/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node \
articles/hls-ts-playback-video/scripts/render-webm.mjs
```

If the rendered WebM shows an unknown duration in a player, patch the EBML
duration metadata:

```sh
/Users/leon/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node \
articles/hls-ts-playback-video/scripts/fix-webm-duration.mjs \
articles/hls-ts-playback-video/renders/hls-ts-playback.webm 124
```

Transcode to MP4:

```sh
/opt/homebrew/bin/ffmpeg -y \
  -i articles/hls-ts-playback-video/renders/hls-ts-playback.webm \
  -c:v libx264 -pix_fmt yuv420p -preset medium -crf 20 \
  -movflags +faststart -an \
  articles/hls-ts-playback-video/renders/hls-ts-playback.mp4
```
