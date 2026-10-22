# Packaging and licensing

## Building the app bundle

```bash
scripts/package-macos.sh
```

Steps performed:

1. `swift build -c release --product RVLCPlayer`
2. Assemble `dist/RVLC.app` (`Info.plist` with document types for video,
   audio and subtitle files).
3. Render the icon from code (`RVLCPlayer --export-iconset`) and convert it with
   `iconutil`.
4. `scripts/bundle_dylibs.py` copies libmpv and its non-system dependency
   closure into `Contents/Frameworks`, rewrites install names to `@rpath`,
   removes rpaths that point outside the bundle, fails if any external reference
   remains, and writes `Contents/Resources/THIRD_PARTY_LICENSES.md`.
5. Ad-hoc code signing of every dylib and the app; `codesign --verify --strict`.
6. `RVLCPlayer --version` proves the bundle launches (every library loads), then
   `RVLCPlayer --self-test <generated clip>` plays a file headlessly through the
   bundled engine and checks audio/subtitle delays. The bundler fails on
   unresolved `@rpath` references and on two different libraries with the same
   name.
7. A compressed DMG with an Applications shortcut.

Verified on the development machine: the bundle is ~65 MB, contains 50
libraries, and `DYLD_PRINT_LIBRARIES` shows every non-system library loaded
from inside the bundle (none from Homebrew).

## Minimum macOS version

Homebrew bottles are built for the macOS version of the machine they were
installed on. The packaging script takes the highest `minos` of the executable
and every bundled library and writes it to `LSMinimumSystemVersion` (26.0 on
the current build machine). To
support older systems, build libmpv and its dependencies with
`MACOSX_DEPLOYMENT_TARGET` set accordingly (as IINA does) and point pkg-config
at that build.

## Signing and notarisation

The script signs ad hoc, which is enough for local use. Public distribution
needs a Developer ID certificate, hardened runtime and notarisation:

```bash
codesign --force --options runtime --timestamp --sign "Developer ID Application: …" "dist/RVLC.app"
xcrun notarytool submit dist/RVLC-*.dmg --keychain-profile <profile> --wait
```

These steps are documented but **have not been performed** for this release.

## Licensing considerations

- RVLC's own code is **GPL-3.0-or-later** (`LICENSE`).
- Homebrew's `mpv` is declared as `GPL-2.0-or-later AND LGPL-2.1-or-later`;
  Homebrew's FFmpeg is built with GPL components (declared
  `GPL-3.0-or-later`), e.g. x264 and x265. The combined bundle must therefore
  be distributed under the GPL.
- When distributing binaries you must provide (or offer in writing) the
  **corresponding source** of RVLC and of every bundled GPL/LGPL
  component, keep their license texts, and not add further restrictions.
  `THIRD_PARTY_LICENSES.md` lists every bundled component, version and declared
  license as a starting point; verify it before each release.
- For an LGPL-only distribution, libmpv must be built with `-Dgpl=false` and
  FFmpeg without GPL components — RVLC itself would still be GPL.
- SF Symbols are used as UI icons under Apple's terms for apps on Apple
  platforms; they are not used in the app icon. The app icon is drawn in code
  (`Sources/RVLCApp/Theme/AppIcon.swift`) and is part of this project.
- No codec patents are licensed by this project; distributors are responsible
  for any patent obligations in their jurisdiction.
