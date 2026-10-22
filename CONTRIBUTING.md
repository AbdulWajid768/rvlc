# Contributing to RVLC

Thanks for helping! Bug reports, fixes, documentation and features are welcome.

## Set up

```bash
brew install mpv pkgconf ffmpeg
```

```bash
swift build
```

```bash
swift run RVLCPlayer
```

Xcode users can open `Package.swift` directly.

## Before opening a pull request

```bash
swift format lint -r Sources Tests Package.swift
```

```bash
swift test
```

- Run `swift format format -i -r Sources Tests Package.swift` to apply the
  project style (`.swift-format`).
- For UI or playback changes, also run the end-to-end test of the packaged app:
  `scripts/run-e2e.sh` (needs Accessibility permission for your terminal; uses
  an isolated profile). Extend `scripts/e2e/E2EDriver.swift` for new user-facing
  behaviour.
- `RVLC_DATA_DIR=/some/folder swift run RVLCPlayer` runs the app with an
  isolated library, cache and settings (`RVLC_RESET=1` starts clean).
- Add tests: pure logic in `RVLCCoreTests`, anything touching libmpv in
  `RVLCEngineTests` (real engine, headless), UI/controller behaviour in
  `RVLCAppTests`. Generate media with FFmpeg in the test (see
  `Tests/RVLCTestSupport/Fixtures.swift`); do not commit copyrighted media.
- Keep the layering: `RVLCCore` must not import AppKit or libmpv.
- Implement player actions once in `PlayerController`; buttons, menus and
  shortcuts call it.
- Every visible control must work. Do not add settings that do nothing.
- Never modify user files; write corrected copies.
- Keep network access out of the core experience. Any future online feature must
  be opt-in and documented in `SECURITY.md`.

## Commit and PR style

- Small, focused commits with descriptive messages.
- Describe user-visible changes and how you tested them in the PR template.
- UI changes: include screenshots in light and dark appearance.

## Reporting bugs

Use the bug report template. Include macOS version, RVLC version, how
you installed libmpv, and the container/codec of the file (File › File Info).
Please do not attach copyrighted media.

## Code of conduct

Participation is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

By contributing you agree that your contributions are licensed under
GPL-3.0-or-later.
