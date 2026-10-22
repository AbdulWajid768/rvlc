# Roadmap

## 0.1 — first release (this version)

Native macOS player on libmpv; Subtitle Studio (offset, reference-point sync
with drift correction, audio-based auto-sync suggestions, editor, export);
Audio Sync Lab; library, playlist, resume; picture & sound adjustments; themes;
configurable shortcuts; packaging script.

## Next

- Build libmpv with an older deployment target to support macOS 13–15 builds.
- Developer ID signing and notarisation in CI.
- Thumbnail previews on the timeline hover (second headless libmpv instance).
- Extract embedded text subtitle tracks into Subtitle Studio for editing/export.
- Multiple sync points shown on the timeline; per-segment (piecewise) sync for
  files with cuts or ad breaks.
- Better speech detection for auto-sync (e.g. a small on-device VAD model) and
  a confidence visualisation.
- Secondary subtitles (two languages at once) for language learners.
- A–B loop and slow-repeat for language learning and lectures.
- Picture-in-Picture and Now Playing / media key integration.

## Later (optional, never required for playback)

- Opt-in online subtitle search with a clear statement of what is sent.
- Metadata and artwork for the library.
- HDR/EDR output when the rendering path allows it.
- Ports of `RVLCCore` to other platforms.
