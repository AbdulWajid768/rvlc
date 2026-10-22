# Changelog

## 0.1.0 — 2026-10-20

First release.

- Native macOS (AppKit) player on libmpv 0.41 with OpenGL render API and VideoToolbox hardware decoding.
- Subtitle Studio: SRT/WebVTT/ASS import with encoding detection, live offset, reference-point sync with drift correction, audio-based auto-sync suggestions, preview/apply/discard, appearance controls, export.
- Subtitle editor with search & replace, per-line timing, undo/redo and live preview.
- Audio Sync Lab: independent audio delay remembered per file, external audio tracks.
- Library (recent, favourites, resume, search, sort, file info) and persistent playlist with repeat modes.
- Picture & Sound: aspect, scaling, video equalizer, rotation, EQ presets, loudness normalisation, amplification with limiter, output device.
- Light/dark/system themes, configurable keyboard shortcuts, responsive control bar, full-screen auto-hiding controls.
- Packaging script producing a self-contained, ad-hoc-signed app bundle and DMG with third-party license notice.
- End-to-end test (`scripts/run-e2e.sh`) that drives the packaged app through the Accessibility API.

### Fixed before release (review and end-to-end testing)

- Drift correction could snap to the wrong frame-rate ratio (24→25 vs 23.976→25); drift is now also remembered per file.
- Unexported subtitle edits are no longer discarded silently (opening another file, end of playlist item, replacing/removing the subtitle, quitting).
- Rapid successive file loads could attribute one file's events and metadata to another.
- Video drawing could enter libmpv from two threads during resizing and full screen.
- Audio auto-sync now streams the audio (constant memory) and no longer favours small offsets on short clips.
- Subtitle loading resolves symlinks, reads only regular files and bounds the read; editor times are range-checked (no crash on huge values).
- UTF-16 files without a BOM, ASS files with lower-case field names, SRT dialogue containing “-->”, and WebVTT karaoke timestamps on export are handled correctly.
- Export can no longer overwrite the source through a hard link or a differently-cased name.
- The same file opened through different paths (e.g. `/var` vs `/private/var`) shares history, resume position and sync settings.
- “Dismiss” on the error screen returns to the empty state; Escape is only consumed in full screen; typing an exact offset hands the keyboard back to the player.
- Closing the player window quits instead of leaving audio playing; Reset All Settings reaches the running player; menus, tooltips and labels follow shortcut and setting changes.
- Simultaneous on-screen messages are stacked instead of replacing each other; long messages wrap.
- Lists support Return (play) and Delete (remove); the remaining-time toggle and control bar are accessible to VoiceOver; the timeline slider seeks when adjusted with assistive technology.
- A damaged library entry no longer discards the whole library, and earlier backups are never overwritten.
- Packaging computes the minimum macOS from every bundled binary, always launch-tests the bundle, and fails on unresolved or colliding libraries.
- Stopping while a file is still loading no longer leaves the player stuck in “loading”.
- An editor cell left open while another subtitle file was loaded can no longer write the old text into the new file; encoding changes ask before discarding edits and keep drift correction.
- Speech detection keeps its filter state across chunks; BOM-less UTF-16BE subtitles are detected; a single possible alignment is never reported as high confidence.
- The main menu is no longer rebuilt every few seconds during playback; list Return/Delete keys respect modifiers.
- Timeline: the hover time sits above the bar instead of covering it and the pointer, appears immediately even after a quick movement onto the bar, and clicking jumps to exactly the time it showed.
- New: Go to Time… (⌘J, or click the elapsed time) accepts 83, 1:23 or 1:02:03 and rejects times beyond the end.
- The sidebar keeps the width you give it on every tab: long text wraps, pop-up menus truncate, the offset buttons sit in two rows (−100 −250 −500 / +100 +250 +500), and “Find Current Line” and “Remove External Audio” became icon buttons.
- Timeline hover bubble redesigned: larger time, distance from the current position (e.g. “+1:05”), an arrow pointing at the exact spot, and a preview of that span with a marker on the bar.
- Every button, pop-up menu, checkbox and segment has a tooltip, and tooltips appear after half a second; buttons with icons are read by VoiceOver by their title.
- One click on the video plays or pauses (after 0.25 s, so a quick double-click never pauses); a slower double-click undoes its first click.
- Full screen is instant (the window covers the screen, Dock and menu bar auto-hide) instead of the macOS Spaces animation, during which macOS drops clicks and keys; two quick double-clicks now zoom in and straight back out. The green window button still uses native full screen.
