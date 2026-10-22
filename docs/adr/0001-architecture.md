# ADR 0001 — Swift + AppKit UI with libmpv as the media engine

- Status: accepted (2026-10-20)
- Deciders: project maintainers

## Context

RVLC needs reliable playback of common formats, precise control over
subtitle and audio timing, track selection, full screen, packaging and
automated tests. The main differentiator — Smart Subtitle Sync — requires
programmatic access to subtitle delay, audio delay, the currently displayed
subtitle text and the decoded audio.

The development machine is macOS 26 (Apple silicon) with Xcode 26.3, Swift 6.2,
Homebrew, Node 22 and Python 3.13 available; Rust, Qt and CMake are not
installed.

## Decision

1. **Language/UI: Swift 6 toolchain (Swift 5 language mode) with AppKit**,
   built with Swift Package Manager. The UI is written programmatically with
   Auto Layout and system semantic colours.
2. **Media engine: libmpv 0.41** (Homebrew `mpv`), accessed through its C API
   via a `systemLibrary` target found with pkg-config. Video is drawn with the
   libmpv **OpenGL render API** into a `CAOpenGLLayer`.
3. **Supported OS for the first release: macOS** (built and tested on macOS 26,
   source compatible with macOS 13+).
4. **License: GPL-3.0-or-later**, compatible with the GPL build of libmpv and
   FFmpeg that is bundled.

A first prototype used PySide6 + libmpv; the project switched to Swift + AppKit
at the maintainers' request to favour a native, polished macOS experience over
cross-platform reach. The subtitle/sync logic was kept in a Foundation-only
module (`RVLCCore`) so a later port remains possible.

## Why libmpv

- Mature, actively maintained engine built on FFmpeg with a documented,
  stable client API; used by IINA, Celluloid and many others.
- Provides exactly the primitives the product needs, with documented semantics
  (verified in the installed mpv 0.41 manual):
  - `sub-delay` — "Delays primary subtitles by <sec> seconds" (positive = later);
  - `audio-delay` — "Positive values delay the audio, and negative values delay
    the video";
  - `sub-add` / `sub-remove` / `audio-add`, `track-list`, `sub-text`;
  - `af` (libavfilter chains), video equalizer properties, `hwdec`.
- A second, headless libmpv instance with `ao=pcm` decodes audio to PCM for
  automatic sync, so no separate FFmpeg executable is required at run time.

## Alternatives considered

| Option | Strengths | Why not chosen |
|---|---|---|
| **AVFoundation / AVPlayer** | Native, Metal/EDR HDR output, PiP | No MKV, no ASS, limited codecs; no subtitle or audio delay for external files |
| **libVLC (VLCKit)** | Mature, LGPL, wide format support | Weaker subtitle-timing API surface for live preview; heavier bundle; less control over rendering in a custom AppKit layout |
| **Qt (C++/PySide6) + libmpv** | Cross-platform | Less native macOS feel, larger bundle (Python + Qt); first prototype replaced at maintainer request |
| **Electron/Tauri + mpv** | Web UI skills | Embedding native video is awkward; Chromium media stack lacks MKV/HEVC and audio delay; Rust not installed for Tauri |

## How the stack supports synchronisation

- **Subtitle offset** → libmpv `sub-delay` (instant, no file rewrite).
- **Drift (scale)** and **line edits** → a preview file rendered from the
  parsed document and attached with `sub-add`; the previous preview track is
  removed so tracks never accumulate.
- **Export** applies the same `scale × t + offset` transform in Swift, so the
  saved file matches the preview.
- **Audio delay** → libmpv `audio-delay`, set per file via `loadfile` options so
  it can never leak into the next file, and persisted in the local library.
- **Verification**: integration tests read libmpv's `sub-text` at specific
  timestamps to prove offset direction through the real engine.

## Consequences

- OpenGL is deprecated by Apple but functional; a future Metal path depends on
  libmpv gaining a Metal render API or on a different embedding approach.
- Packaged builds that bundle Homebrew bottles inherit their minimum macOS
  version. A dedicated libmpv build is needed to target older systems.
- Distributing builds requires honouring GPL obligations for bundled
  components (see `docs/PACKAGING.md`).
