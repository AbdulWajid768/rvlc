# Implementation checklist — 0.1.0

Legend: ✅ done and verified · 🟡 partial · ⏭ planned (see ROADMAP.md)

## Foundation
- ✅ Architecture decision (Swift + AppKit + libmpv), ADR and architecture docs
- ✅ Swift package with layered modules (`RVLCCore`, `RVLCEngine`, `RVLCApp`, `CMpv`)
- ✅ Real playback through libmpv's OpenGL render API (visually verified)
- ✅ Explicit playback state machine driven by libmpv events
- ✅ Light / dark / system themes, persisted (unit + UI tests)

## Playback
- ✅ Open files/folders, drag & drop, Finder “Open With” document types
- ✅ Play/pause, stop, previous/next, seek (step, 1 s, 30 s, frames), timeline scrubbing with hover time
- ✅ Volume, mute, amplification to 200 % with limiter, speed 0.25–4×
- ✅ Full screen with auto-hiding overlay controls (hidden only while playing)
- ✅ Subtitle and audio track selection, external audio tracks
- ✅ Error states (unsupported, missing, broken files), end of file, playlist advance, repeat modes
- ✅ Resume position, per-file audio delay and subtitle choice/offset
- ✅ Hardware decoding (VideoToolbox, `auto-safe`) with live status
- 🟡 HDR: tone-mapped to SDR only; no EDR output
- ⏭ Audio passthrough UI, timeline thumbnails, Picture-in-Picture

## Subtitle Studio
- ✅ SRT, WebVTT, ASS/SSA import; encoding detection + manual override; invalid/binary file rejection
- ✅ Live offset (±100/250/500 ms, exact entry, reset, shortcuts); direction verified through libmpv `sub-text`
- ✅ Reference-point sync (“Sync Line to Now”), constant and linear drift fitting with frame-rate snapping
- ✅ Audio-based auto-sync suggestion with confidence; preview / apply / discard
- ✅ Editor: text, start/end, search & replace (case, word, regex), nudge, set start to now, undo/redo, live preview
- ✅ Appearance: size, position, background box
- ✅ Export SRT/WebVTT (+ASS for ASS sources), validation, warnings for dropped styling, source never overwritten
- 🟡 Embedded subtitle tracks: offset only (no editing/export)

## Audio Sync Lab
- ✅ Independent audio delay (verified independent of subtitle offset across seeks and track switches)
- ✅ External audio, active track display, per-file persistence, shortcuts

## Library & playlist
- ✅ Recent, favourites, search, sort, resume progress, file info, remove from history, clear history
- ✅ Persistent, reorderable playlist with repeat modes; corrupt store backed up, never discarded

## Enhancements
- ✅ Aspect override, fit/fill/stretch, brightness/contrast/saturation/gamma, rotation
- ✅ Equalizer presets, loudness normalisation, output device selection
- ⏭ AI upscaling, frame interpolation (out of scope for 0.1)

## Settings, shortcuts, accessibility
- ✅ Settings window (General, Playback, Subtitles, Audio, Shortcuts) with persistence
- ✅ Configurable shortcuts with conflict detection; reference window; never interfere with typing (tests)
- ✅ Buttons never keep focus after a click; responsive control bar (tests)
- 🟡 Accessibility labels on controls; not yet audited with VoiceOver

## Open-source readiness
- ✅ README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY (privacy model), LICENSE (GPL-3.0-or-later), CHANGELOG
- ✅ Issue templates, PR template, CI workflow (macOS: lint, build, test, package)
- 🟡 CI workflow written but not yet run on GitHub (no remote configured)
- ✅ End-to-end test of the packaged app via the Accessibility API (`scripts/run-e2e.sh`, 71 checks)
- ✅ Independent code review of all modules; every verified finding fixed with a regression test
- ✅ Packaging: self-contained app bundle + DMG, third-party license notice, bundled-engine self-test
- ⏭ Developer ID signing and notarisation; libmpv built for older macOS versions
