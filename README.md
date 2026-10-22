# RVLC

[![CI](https://github.com/AbdulWajid768/rvlc/actions/workflows/ci.yml/badge.svg)](https://github.com/AbdulWajid768/rvlc/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](#requirements)

**Reimagined VLC.** Play anything. Fix everything.

RVLC (Reimagined VLC) is a free, open-source desktop media player for macOS with a
signature feature: **Smart Subtitle Sync**. Subtitles that appear too early or
too late, drift over a film, or audio that runs ahead of the picture can be
fixed in seconds — and a corrected subtitle file can be exported without ever
touching the original.

Playback is powered by [libmpv](https://mpv.io) (FFmpeg underneath), so it
plays the same wide range of formats as mpv. The interface is a native AppKit
app written in Swift. Everything runs locally: no account, no telemetry, no
network requests.

> Status: **0.1.0, early release.** Built and tested on macOS 26 (Apple
> silicon). See [Verified capabilities](#verified-capabilities) and
> [Limitations](#limitations) for exactly what has been checked.
>
> Contributions are welcome. Please read [Contributing](CONTRIBUTING.md),
> the [code of conduct](CODE_OF_CONDUCT.md) and
> [Security & privacy](SECURITY.md) before opening an issue or pull request.

## Highlights

- **Subtitle Studio** (sidebar, ⌘3)
  - Import SRT, WebVTT and ASS/SSA; automatic encoding detection with a manual
    override (UTF-8/16, Windows code pages, ISO-8859, KOI8-R, Shift JIS, GB18030,
    Big5, EUC-KR…); invalid files are rejected with a clear message.
  - Live timing offset: ±100/250/500 ms buttons, exact millisecond entry,
    reset, and keyboard shortcuts (Z / X, ⇧Z).
  - **Sync to speech**: pause on a spoken line, pick it, click *Sync Line to
    Now* (Y). One point fixes an offset; two or more spread across the film also
    fix drift (e.g. 23.976 ↔ 25 fps), with a fit-quality readout.
  - **Automatic sync from audio**: compares speech activity in the audio
    with subtitle timing and *suggests* an offset (and frame-rate drift) with a
    confidence level. Runs entirely on the Mac.
  - Every suggestion can be **previewed, applied or discarded**.
  - Subtitle editor (⌘E): edit text and timings, search & replace (case,
    whole word, regex), nudge lines, "set start to now", undo/redo, live preview.
  - Export corrected SRT / WebVTT (and ASS for ASS sources, styling preserved);
    conversion from ASS warns about dropped styling; the source file is never
    overwritten.
- **Audio Sync Lab** (⌘4): independent audio delay (C / V, ⇧C), external audio
  tracks (e.g. a dub), track selection, remembered per file.
- **Player**: play/pause (Space or one click on the video), stop, previous/next,
  seek (step, 1 s, 30 s, frame), scrubbable timeline whose hover bubble shows
  exactly where a click will go and how far that is from now,
  Go to Time… (⌘J or click the elapsed time), volume/mute, speed 0.25–4×, full screen
  with auto-hiding controls, subtitle & audio track menus, drag & drop.
- **Library & playlist**: recently played with resume positions, favourites,
  search and sorting, file info; a persistent, reorderable play queue with
  repeat modes; open whole folders.
- **Picture & Sound**: aspect override, fit/fill/stretch, brightness, contrast,
  saturation, gamma, rotation, hardware decoding toggle with live decoder
  status, equalizer presets, loudness normalisation, amplification to 200 %
  with a limiter, output device selection.
- **Native macOS design**: light, dark and system themes; responsive layout;
  accessibility labels on controls (not yet audited with VoiceOver);
  configurable keyboard shortcuts that never interfere with
  typing.

## Requirements

- macOS 13 or later to build from source (tested on macOS 26.0.1, Apple silicon)
- Xcode 16 or later (Swift 6 toolchain; tested with Xcode 26.3 / Swift 6.2)
- Homebrew packages: `mpv` (libmpv) and `pkgconf`
- `ffmpeg` (optional) — only needed to generate test media for the test suite

```bash
brew install mpv pkgconf ffmpeg
```

## Run the development version

```bash
swift run RVLCPlayer
```

Pass files to open them directly:

```bash
swift run RVLCPlayer ~/Movies/example.mkv
```

## Test, lint and build

```bash
swift test
```

```bash
swift format lint -r Sources Tests Package.swift
```

```bash
swift build -c release
```

The test suite has three layers:

| Target | What it covers |
|---|---|
| `RVLCCoreTests` | Parsing (SRT/VTT/ASS), encodings, Unicode, invalid input, offsets, drift fitting, audio auto-sync on synthetic signals, export accuracy, source preservation, library, playlist, preferences, key bindings |
| `RVLCEngineTests` | The **real libmpv backend** (headless): state transitions, seeking, duration/position, end of file, error states, subtitle offset direction verified through libmpv's `sub-text`, independence of audio/subtitle offsets across seeks and track switches, external audio, audio extraction + auto-sync end to end |
| `RVLCAppTests` | Controller and UI behaviour: button independence, focus safety, keyboard routing vs. text fields/tables, theme switching and persistence, responsive control bar, empty/error states, Subtitle Studio workflows (preview/accept/reject, live edits, undo, export) |

Test media is generated with FFmpeg at test time; no copyrighted media is stored
in the repository.

### End-to-end test of the packaged app

```bash
scripts/run-e2e.sh
```

This packages the app, launches it with an isolated profile (`RVLC_DATA_DIR`,
so your library and settings are untouched) and drives it like a user through
the macOS Accessibility API: buttons, keyboard shortcuts, menus, Finder “Open
With”, the save panel, full screen, window resizing, quitting and relaunching.
It checks what is visible (labels, on-screen messages, window state) and
detects drawn subtitles in screenshots to verify offset direction. It needs
Accessibility permission for the terminal and takes over the keyboard for about
two minutes.

## Build a release

```bash
scripts/package-macos.sh
```

This produces `dist/RVLC.app` and a DMG. The script bundles libmpv and
its dependencies into the app, rewrites library paths so nothing is loaded from
Homebrew at run time, signs ad hoc, generates
`THIRD_PARTY_LICENSES.md`, and runs a headless self-test of the bundled engine.
See [docs/PACKAGING.md](docs/PACKAGING.md) before distributing builds.

## How subtitle synchronisation works

Convention: **a positive offset shows subtitles later; a negative offset shows
them earlier.** Audio uses the same idea: **a positive audio delay plays the
audio later relative to the video.**

Original timestamps are never modified. Timing is a transform
`displayed = scale × original + offset` that is applied for preview (offset via
libmpv's `sub-delay`, scale baked into a temporary preview file) and on export.
Because the transform is stored separately, pressing a key ten times cannot
accumulate rounding into the cues. Details, including the auto-sync algorithm
and its limits, are in [docs/SUBTITLE_SYNC.md](docs/SUBTITLE_SYNC.md).

## Verified capabilities

Verified on macOS 26.0.1 (arm64), libmpv 0.41.0, FFmpeg 9.0.2:

- H.264/AAC MP4 playback with VideoToolbox hardware decoding through the
  embedded OpenGL renderer (visually checked) and headless playback in tests.
- External SRT loading and rendering; subtitle offset direction; audio delay;
  external AAC audio tracks; ASS round-trips (parser tests).
- Audio extraction through a private libmpv instance and audio-based auto-sync
  on synthetic media.
- The packaged app loads only bundled libraries (checked with
  `DYLD_PRINT_LIBRARIES`) and passes its self-test.

Format support otherwise follows libmpv/FFmpeg; other containers and codecs
(MKV, HEVC, VP9, AV1, Opus, FLAC, …) are expected to work but are not covered by
this project's automated tests.

## Limitations

- **macOS only.** The UI is AppKit. The subtitle/sync core (`RVLCCore`) is
  Foundation-only and could be reused by a future port.
- **Packaged builds require the macOS version the bundled libraries were built
  for** (macOS 26 with current Homebrew bottles). Supporting older macOS needs a
  libmpv built with an older deployment target.
- Rendering uses libmpv's OpenGL render API (Apple deprecates OpenGL but it
  remains functional). HDR content is tone-mapped to SDR; there is no HDR/EDR
  output or audio passthrough UI yet.
- Automatic sync detects speech by energy in the speech band; music-heavy or
  effects-heavy soundtracks can mislead it. Results are always suggestions with
  a confidence label.
- Subtitle edits live in the app until exported; RVLC asks before an
  action (opening another file, quitting…) would discard them.
- Closing the player window quits the app.
- Embedded subtitle tracks can be shifted but not edited or exported.
- No online subtitle search, metadata lookup or AI features (by design for now).
- The app is signed ad hoc, not notarised; Gatekeeper will warn on other Macs.

## Repository layout

| Path | Contents |
|---|---|
| [`Sources/RVLCCore`](Sources/RVLCCore) | Subtitles, sync maths, library and preferences. Foundation only, so it can be tested without AppKit or libmpv. |
| [`Sources/RVLCEngine`](Sources/RVLCEngine) | libmpv playback, the OpenGL video view and audio extraction. |
| [`Sources/RVLCApp`](Sources/RVLCApp) | Native AppKit interface. |
| [`Sources/RVLCPlayer`](Sources/RVLCPlayer) | Thin executable entry point (`swift run RVLCPlayer`). |
| [`Tests/`](Tests) | Core, engine and UI tests, plus shared FFmpeg fixtures. |
| [`scripts/`](scripts) | macOS packaging and the Accessibility end-to-end driver. |
| [`docs/`](docs/README.md) | Architecture, sync, shortcuts, packaging, research and the roadmap. |

## Documentation

- [Architecture decision record](docs/adr/0001-architecture.md)
- [Architecture overview](docs/ARCHITECTURE.md)
- [Subtitle & audio sync](docs/SUBTITLE_SYNC.md)
- [Keyboard shortcuts](docs/SHORTCUTS.md)
- [Packaging & licensing](docs/PACKAGING.md)
- [Research notes](docs/RESEARCH.md)
- [Roadmap](docs/ROADMAP.md)
- [Implementation checklist](docs/IMPLEMENTATION_CHECKLIST.md)
- [Contributing](CONTRIBUTING.md) · [Security & privacy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md)

## License

RVLC is free software licensed under the **GNU General Public License
v3.0 or later** (see [LICENSE](LICENSE)). It links libmpv, which is GPL-2.0-or-later
in the Homebrew build, and bundles FFmpeg and other libraries whose licenses are
listed in the generated `THIRD_PARTY_LICENSES.md`.
