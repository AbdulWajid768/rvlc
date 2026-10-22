#!/usr/bin/env bash
# Builds "RVLC.app" and a DMG in ./dist.
#
#   scripts/package-macos.sh            # build, bundle, sign ad hoc, self-test, DMG
#   SKIP_DMG=1 scripts/package-macos.sh # app bundle only
#
# Requirements: Xcode 16+ (Swift 6 toolchain), Homebrew `mpv` and `pkgconf`.
# The bundle contains Homebrew's libmpv and its dependency closure; it runs on
# the macOS version those libraries were built for (see docs/PACKAGING.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(grep -m1 'static let string' Sources/RVLCApp/App/AppDelegate.swift | sed -E 's/.*"(.*)".*/\1/')"
APP_NAME="RVLC"
BUNDLE_ID="org.rvlc.player"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> Building release binary ($VERSION)"
swift build -c release --product RVLCPlayer
BIN="$(swift build -c release --show-bin-path)/RVLCPlayer"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN" "$CONTENTS/MacOS/RVLCPlayer"

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

echo "==> Bundling libmpv and dependencies"
python3 "$ROOT/scripts/bundle_dylibs.py" "$CONTENTS/MacOS/RVLCPlayer" "$CONTENTS/Frameworks" "$CONTENTS/Resources/THIRD_PARTY_LICENSES.md"
cp LICENSE "$CONTENTS/Resources/LICENSE.txt"

# The app can only run where every bundled binary can: use the highest minimum OS.
MIN_OS="$(for f in "$CONTENTS/MacOS/RVLCPlayer" "$CONTENTS"/Frameworks/*.dylib; do
  otool -l "$f" | awk '/minos/ {print $2; exit}'
done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
MIN_OS="${MIN_OS:-13.0}"
echo "    minimum macOS: $MIN_OS"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>RVLCPlayer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>RVLC contributors. GPL-3.0-or-later.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.movie</string><string>public.video</string><string>org.matroska.mkv</string><string>org.webmproject.webm</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Subtitles</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>srt</string><string>vtt</string><string>ass</string><string>ssa</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
find "$CONTENTS/Frameworks" -name '*.dylib' -exec codesign --force --sign - --timestamp=none {} \;
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Launch check (all bundled libraries load)"
"$CONTENTS/MacOS/RVLCPlayer" --version

echo "==> Self-test of the bundled engine"
FIXTURE="$(mktemp -d)/selftest.mp4"
if command -v ffmpeg >/dev/null; then
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=25:duration=2 \
    -f lavfi -i sine=frequency=440:duration=2 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$FIXTURE"
  "$CONTENTS/MacOS/RVLCPlayer" --self-test "$FIXTURE"
else
  echo "ffmpeg not found; skipping media self-test"
fi

if [[ "${SKIP_DMG:-0}" != "1" ]]; then
  echo "==> Creating DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="$DIST/RVLC-$VERSION-macOS-$(uname -m).dmg"
  rm -f "$DMG"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  echo "Created $DMG"
fi
du -sh "$APP"
echo "Done."
