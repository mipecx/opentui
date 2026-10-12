# FFmpeg

Native video statically links a minimal decode-only FFmpeg 8.1.1 build: MOV/MP4 demuxing, H.264 video decoding,
AAC audio decoding, file I/O, libswscale, and libswresample. On macOS it also enables VideoToolbox H.264 hardware
decoding, which playback uses only when `OPENTUI_VIDEO_HWACCEL=1` is set. GPL and nonfree components are disabled.

- Source: https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.xz
- SHA-256: `b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3`
- License: LGPL-2.1-or-later (`COPYING.LGPLv2.1`)
- zlib 1.3.1: https://zlib.net/fossils/zlib-1.3.1.tar.gz
- zlib SHA-256: `9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23`
- zlib license: `LICENSE-ZLIB`

`packages/native/scripts/build-ffmpeg.ts` holds the exact build configuration and runs before every native build. It
caches the static libraries under `packages/native/.cache/ffmpeg`. Run `bun scripts/build-ffmpeg.ts --all` in
`packages/native` to build every release target. Targets without a prebuilt FFmpeg compile video as unavailable.

The FFmpeg source is unmodified; OpenTUI integrates it only through `src/video-shim.c`. The OpenTUI source, the build
script, and the pinned FFmpeg source provide what is needed to rebuild and relink `libopentui` with a modified FFmpeg.
