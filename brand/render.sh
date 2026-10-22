#!/usr/bin/env bash
# Regenerates every brand asset in ./brand from brand/generate.py.
# Requirements: Python 3, Google Chrome, Xcode command-line tools (iconutil),
# and network access on first run (pillow/fonttools and the Unbounded and
# Michroma fonts, both SIL Open Font License, are cached outside the repo).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rvlc-brand"
VENV="$CACHE/venv"
export FONT_DIR="$CACHE/fonts"

if [ ! -x "$VENV/bin/python" ]; then
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q pillow fonttools
fi
mkdir -p "$FONT_DIR"
fetch() {
  [ -f "$FONT_DIR/$2" ] || curl -sSfL -o "$FONT_DIR/$2" "https://github.com/google/fonts/raw/main/ofl/$1"
}
fetch "unbounded/Unbounded%5Bwght%5D.ttf" "Unbounded[wght].ttf"
fetch "michroma/Michroma-Regular.ttf" "Michroma-Regular.ttf"

"$VENV/bin/python" "$HERE/generate.py"
