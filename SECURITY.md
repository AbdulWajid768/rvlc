# Security and privacy

## Privacy model

RVLC is local-first:

- **No account, no telemetry, no analytics, no crash upload.**
- **No network requests.** libmpv is configured with `ytdl=no`, user mpv config
  and scripts are not loaded (`config=no`, `load-scripts=no`), and the app has
  no online features.
- Media, subtitles and audio analysis never leave the Mac. Audio analysis
  writes a temporary PCM file to the system temp folder and deletes it
  immediately after reading.
- Stored locally:
  - preferences in `UserDefaults`;
  - history, resume positions, favourites, per-file sync settings and the
    playlist in `~/Library/Application Support/RVLC/library.json`;
  - temporary subtitle preview files in `~/Library/Caches/RVLC`.
  History can be cleared in Settings › General, and position memory can be
  turned off.
- Logs use Apple's unified logging; file paths and libmpv messages are logged
  as *private* and subtitle text is never logged.

If an online feature is ever added it must be opt-in and this document must
state exactly what is sent and to whom.

## Handling untrusted input

- Media files are demuxed and decoded by libmpv/FFmpeg. Keep the bundled
  libraries up to date — most media-player vulnerabilities are in decoders.
- Subtitle files are parsed by RVLC's own Swift code: symlinks are
  resolved, only regular files are read (no devices or FIFOs), reads are
  bounded to 20 MB, binary files are rejected, invalid entries are skipped with
  warnings and user-typed times are range-checked.
- Exports refuse to overwrite the source file, including through hard links or
  differently-cased names on case-insensitive volumes.
- RVLC never executes downloaded files, never modifies source subtitle
  files, and writes exports atomically.
- Only local file paths are passed to libmpv.

## Supported versions

Security fixes target the latest release.

## Reporting a vulnerability

Please report vulnerabilities privately using GitHub's *Report a
vulnerability* (security advisories) on this repository rather than opening a
public issue. Include affected versions, steps to reproduce and, if possible, a
minimal test file. We aim to acknowledge reports within 7 days.
