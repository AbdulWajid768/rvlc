# RVLC documentation

RVLC (Reimagined VLC) is a free, open-source macOS media player. These notes
describe how it is built, how subtitle sync works, and how to package it.
The [project README](../README.md) covers installing, running and testing.

## Start here

| Document | Read it for |
|---|---|
| [Architecture overview](ARCHITECTURE.md) | Module layout, data flow and where new code belongs. |
| [ADR 0001](adr/0001-architecture.md) | Why the player is Swift, AppKit and libmpv. |
| [Subtitle and audio sync](SUBTITLE_SYNC.md) | Offset direction, drift fitting and the limits of automatic sync. |
| [Keyboard shortcuts](SHORTCUTS.md) | Default keys. Users can change them in Settings. |
| [Packaging and licensing](PACKAGING.md) | How `RVLC.app` and the DMG are built, and what the GPL requires when you distribute binaries. |
| [Roadmap](ROADMAP.md) | What 0.1 includes and what is planned next. |
| [Research notes](RESEARCH.md) | The comparison that set the scope. Treat unchecked claims as notes, not guarantees. |
| [Implementation checklist](IMPLEMENTATION_CHECKLIST.md) | What was verified for 0.1.0. |

## Contributing

Behaviour changes belong with tests. The layering rule is short: `RVLCCore`
must not import AppKit or libmpv. See [Contributing](../CONTRIBUTING.md) for
the setup, the test commands and the pull-request checklist.

Please report vulnerabilities privately, as described in
[Security and privacy](../SECURITY.md).

## License

Documentation in this tree is part of RVLC and is covered by
[GPL-3.0-or-later](../LICENSE), the same license as the code.
