#!/usr/bin/env bash
# End-to-end test of the packaged app, driven through the Accessibility API.
#
#   scripts/run-e2e.sh                 # package (no DMG) then run
#   APP="dist/RVLC.app" scripts/run-e2e.sh   # use an existing bundle
#
# Requirements: Accessibility permission for the terminal (System Settings ›
# Privacy & Security › Accessibility), ffmpeg. The app runs with an isolated
# profile (RVLC_DATA_DIR) and never touches your library or settings. The test
# takes over the keyboard focus for about two minutes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${APP:-}"
if [[ -z "$APP" ]]; then
  SKIP_DMG=1 scripts/package-macos.sh >/dev/null
  APP="$ROOT/dist/RVLC.app"
fi

WORK="$(mktemp -d)"
FIX="$WORK/fixtures"
DATA="$WORK/data"
mkdir -p "$FIX" "$DATA"
trap 'defaults delete org.rvlc.player.isolated >/dev/null 2>&1 || true' EXIT

echo "==> Generating fixtures in $FIX"
# Irregular 440 Hz “speech” bursts (WAV) and subtitles for the same bursts authored 1.2 s early.
# Bursts must be irregular: a periodic pattern would make any sync offset ambiguous.
python3 - "$FIX" <<'PY'
import math, random, struct, sys, wave
fix = sys.argv[1]
rng = random.Random(7)
bursts, t = [], 1.0
while t < 28:
    length = rng.uniform(0.7, 2.0)
    bursts.append((t, min(t + length, 29.5)))
    t += length + rng.uniform(0.6, 2.2)
rate = 48000
frames = bytearray()
for i in range(rate * 30):
    x = i / rate
    on = any(a <= x < b for a, b in bursts)
    v = 0.4 * math.sin(2 * math.pi * 440 * x) if on else 0.0
    frames += struct.pack("<h", int(v * 32767))
with wave.open(f"{fix}/tone.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frames))
def ts(t):
    ms = int(round(max(0.0, t) * 1000))
    return f"{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d},{ms%1000:03d}"
cues = [(a - 1.2, b - 1.2) for a, b in bursts if b - 1.2 > 0]
with open(f"{fix}/E2E Clip.srt", "w") as f:
    f.write("\n".join(f"{k+1}\n{ts(a)} --> {ts(b)}\nLINE {k} WHITE TEXT\n" for k, (a, b) in enumerate(cues)))
with open(f"{fix}/cues.txt", "w") as f:
    f.write("\n".join(f"{a:.3f} {b:.3f}" for a, b in cues))
PY
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x202830:size=960x540:rate=25:duration=30" -i "$FIX/tone.wav" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest "$FIX/E2E Clip.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=10" -f lavfi -i "sine=frequency=300:duration=10" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest "$FIX/Second Clip.mp4"
head -c 65536 /dev/urandom > "$FIX/Broken.mp4"

echo "==> Building driver"
swiftc -O -o "$WORK/E2EDriver" "$ROOT/scripts/e2e/E2EDriver.swift"

echo "==> Running end-to-end scenario"
"$WORK/E2EDriver" "$APP" "$FIX" "$DATA"
