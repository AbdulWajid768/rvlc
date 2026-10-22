# Research notes

Summary of the investigation behind RVLC's scope and technology choices
(October 2026). Statements marked *(manual)* were checked in the mpv 0.41
manual installed with Homebrew; others come from the sources linked at the end
or from general product knowledge, and should be re-verified before being
quoted elsewhere.

## Existing players

| Player | Strengths | Gaps RVLC targets |
|---|---|---|
| **VLC** (3.x stable; 4.0 still in beta per a July 2026 report, with early betas first on Apple platforms) | Plays almost anything, cross-platform, open source | Subtitle/audio delay hidden in menus and hotkeys; no guided sync workflow; dated macOS UI |
| **mpv** | Excellent playback quality, scriptable, `sub-delay`/`audio-delay`, `sub-step` to align the next line *(manual)* | Minimal UI by design; sync is keyboard-only and invisible to beginners |
| **IINA** (macOS, Swift + libmpv) | Native macOS UI on top of mpv | Sync controls are numeric fields; no reference-point or audio-based sync |
| **PotPlayer** (Windows) | Huge feature set, fine-grained sync | Windows-only, overwhelming settings, closed source |
| **MPC-HC** (Windows, community fork) | Lightweight, classic UI | Windows-only, dated UI |
| **CyberLink PowerDVD** | Polished, disc/streaming features | Commercial, subscription features, not open source |
| **Subtitle tools** (Subtitle Edit, Aegisub, ffsubsync, alass) | Powerful editing; ffsubsync aligns subtitles to speech using VAD + FFT cross-correlation; alass uses dynamic programming | Separate apps — fixing timing means leaving the player |

Opportunity: put the *fix* inside the player, make it understandable (clear
sign conventions, live preview, accept/discard), and keep the original file
untouched.

## Media engine findings

- On macOS, embedding mpv via `--wid` is not documented (the manual lists X11,
  Windows and Android) *(manual)*; the libmpv render API is the supported
  route (also used by IINA).
- `sub-delay` delays subtitles (positive = later); `audio-delay` positive
  values delay audio *(manual)*.
- `sub-add`/`sub-remove`/`sub-reload` operate on external subtitle tracks;
  `sub-reload` works by unloading and re-adding *(manual)* — RVLC adds a
  new preview track and removes the old one explicitly.
- `sub-text` returns the current subtitle text regardless of visibility
  *(manual)*, which enables engine-level tests of offset direction.
- `--sub-speed` multiplies text-subtitle timestamps *(manual)*; RVLC
  bakes drift into the preview file instead so preview and export share one
  code path.
- `ao=pcm` with `ao-pcm-file` and `ao-pcm-waveheader=no` produces raw PCM
  *(manual)*, used for audio analysis without an external FFmpeg binary.
- `hwdec=auto-safe` enables VideoToolbox on macOS; verified active in the app
  ("hardware (videotoolbox)").
- `volume-max` defaults to 130 % *(manual)*; RVLC exposes 100 % or 200 %
  with an `alimiter` safeguard.

## UI references

macOS Human Interface Guidelines patterns: inspector-style sidebar with
segmented navigation, semantic colours for automatic light/dark, SF Symbols,
toolbar-style settings, sheets for confirmations. Controls auto-hide only in
full screen to keep windowed playback predictable.

## Sources

- mpv manual, version 0.41.0 (installed man page `mpv.1`), https://mpv.io/manual/stable/
- python-mpv README (render API overview; used in the first prototype), https://github.com/jaseg/python-mpv
- ffsubsync documentation, https://github.com/smacke/ffsubsync and https://pypi.org/project/ffsubsync/
- VLC 4.0 status (July 2026), https://www.digitec.ch/en/page/open-source-tip-vlc-the-player-for-just-about-anything-43212
- Homebrew `mpv` formula metadata (`brew info mpv`): version 0.41.0, license GPL-2.0-or-later AND LGPL-2.1-or-later
