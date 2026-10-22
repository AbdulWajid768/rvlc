#!/usr/bin/env python3
"""Generates every RVLC brand asset from one set of geometry.

    brand/render.sh            # sets up dependencies and runs this script

Requirements: Python packages pillow and fonttools, Google Chrome (headless
rendering keeps the SVG glow filters), `iconutil`, and the Unbounded and
Michroma fonts (SIL Open Font License) in $FONT_DIR. Text is converted to
outlines, so the generated SVGs do not depend on installed fonts.

Motif ("Warp"): nested play shapes twisting into a tunnel around a bright
play core. The twist totals 120 degrees, so the core points the same way as
the outer ring. `Sources/RVLCApp/Theme/AppIcon.swift` draws the same artwork.
"""

import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
SVG, PNG, WEB, MACOS = ROOT / "svg", ROOT / "png", ROOT / "web", ROOT / "macos"
FONTS = Path(os.environ.get("FONT_DIR", Path.home() / ".cache/rvlc-brand/fonts"))
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

PURPLE, BLUE, NAVY, SLATE, TEXT, MUTED = "#8B5CF6", "#3B82F6", "#0B0F1A", "#1A1F2E", "#F8FAFC", "#94A3B8"
ICE = "#E0E7FF"

# 1024 grid. The macOS icon body is inset ~10 % with a rounded square.
BODY = (100, 100, 824, 185)
CENTER = (490, 512)  # tunnel centroid; offset left so the play shape sits optically centred

FULL = dict(rings=11, r0=340, decay=0.84, width=(3, 15), core=62, stars=70)
COMPACT = dict(rings=5, r0=350, decay=0.72, width=(14, 22), core=74, stars=0)


# ---------------------------------------------------------------- geometry

def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def play_points(cx, cy, r, rot=0.0):
    """Right-pointing equilateral triangle around its centroid."""
    return [polar(cx, cy, r, 90 + rot + k * 120) for k in range(3)]


def rounded(points, r):
    n, segs = len(points), []
    for i in range(n):
        (vx, vy), (px, py), (nx, ny) = points[i], points[i - 1], points[(i + 1) % n]
        dp, dn = math.hypot(px - vx, py - vy), math.hypot(nx - vx, ny - vy)
        segs.append(((vx + (px - vx) * r / dp, vy + (py - vy) * r / dp), (vx, vy),
                     (vx + (nx - vx) * r / dn, vy + (ny - vy) * r / dn)))
    d = f"M{segs[0][2][0]:.2f},{segs[0][2][1]:.2f}"
    for a, v, b in segs[1:] + segs[:1]:
        d += f" L{a[0]:.2f},{a[1]:.2f} Q{v[0]:.2f},{v[1]:.2f} {b[0]:.2f},{b[1]:.2f}"
    return d + " Z"


def mix(a, b, t):
    ca, cb = ([int(h[i:i + 2], 16) for i in (1, 3, 5)] for h in (a, b))
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(ca, cb))


def rings(geo):
    """(points, corner radius, colour, opacity, stroke width) per ring, outer first."""
    n = geo["rings"]
    lo, hi = geo["width"]
    out = []
    for i in range(n):
        t = i / (n - 1)
        r = geo["r0"] * geo["decay"] ** i
        col = mix(PURPLE, BLUE, min(1, t * 1.6)) if t < 0.62 else mix(BLUE, ICE, (t - 0.62) / 0.38)
        out.append((play_points(*CENTER, r, rot=i * 120 / n), r * 0.16, col, 0.35 + 0.65 * t, lo + hi * (1 - t) ** 1.2))
    return out


def stars(n):
    """Deterministic starfield (same LCG as AppIcon.swift)."""
    state, out = 7, []

    def rnd():
        nonlocal state
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        return state / 0x7FFFFFFF

    for _ in range(n):
        x, y = 110 + rnd() * 804, 110 + rnd() * 804
        r = (1.2, 1.6, 2.2, 3.0)[min(3, int(rnd() * 4))]
        out.append((x, y, r, 0.15 + 0.45 * rnd()))
    return out


# ---------------------------------------------------------------- SVG pieces

def lin(id, x1, y1, x2, y2, *stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<linearGradient id="{id}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def rad(id, cx, cy, r, *stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<radialGradient id="{id}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}">{s}</radialGradient>'


def blur(id, sd):
    return f'<filter id="{id}" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="{sd}"/></filter>'


def doc(w, h, defs, body, view=None):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{view or f"0 0 {w} {h}"}">\n'
            f"<defs>{defs}</defs>\n{body}\n</svg>\n")


def warp(p, geo=FULL, mode="color"):
    """The tunnel mark. mode: color | light | dark (single-colour inks)."""
    rs = rings(geo)
    core = rounded(play_points(*CENTER, geo["core"]), geo["core"] * 0.2)
    if mode == "color":
        paths = "".join(f'<path d="{rounded(pts, cr)}" fill="none" stroke="{col}" stroke-opacity="{op:.2f}" '
                        f'stroke-width="{w:.1f}" stroke-linejoin="round"/>' for pts, cr, col, op, w in rs)
        defs = blur(f"{p}glow", 22) + blur(f"{p}core", 6)
        body = (f'<g filter="url(#{p}glow)" opacity="0.9">{paths}</g>{paths}'
                f'<path d="{core}" fill="#FFFFFF" filter="url(#{p}core)"/><path d="{core}" fill="#FFFFFF"/>')
        return defs, body
    ink = TEXT if mode == "light" else NAVY
    paths = "".join(f'<path d="{rounded(pts, cr)}" fill="none" stroke="{ink}" stroke-opacity="{0.25 + 0.75 * op:.2f}" '
                    f'stroke-width="{w:.1f}" stroke-linejoin="round"/>' for pts, cr, _, op, w in rs)
    return "", paths + f'<path d="{core}" fill="{ink}"/>'


def background(p, radius=BODY[3], shadow=True, geo=FULL):
    x = y = BODY[0]
    s = BODY[2]
    shape = f'x="{x}" y="{y}" width="{s}" height="{s}" rx="{radius}"'
    defs = (f'<clipPath id="{p}clip"><rect {shape}/></clipPath>'
            + lin(f"{p}bg", 0, y, 0, y + s, (0, "#141828", 1), (1, NAVY, 1))
            + rad(f"{p}glowA", *CENTER, 520, (0, PURPLE, 0.2), (0.6, PURPLE, 0.05), (1, PURPLE, 0))
            + rad(f"{p}glowB", 860, 900, 420, (0, BLUE, 0.22), (1, BLUE, 0))
            + rad(f"{p}tunnel", *CENTER, 380, (0, BLUE, 0.35), (0.5, PURPLE, 0.18), (1, NAVY, 0))
            + lin(f"{p}rim", 0, y, 0, y + s, (0, "#FFFFFF", 0.22), (0.5, "#FFFFFF", 0.04), (1, BLUE, 0.25))
            + f'<filter id="{p}shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" '
              f'stdDeviation="16" flood-color="#000" flood-opacity="0.45"/></filter>')
    fill = "".join(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" fill="url(#{p}{g})"/>' for g in ("bg", "glowA", "glowB", "tunnel"))
    fill += "".join(f'<circle cx="{sx:.0f}" cy="{sy:.0f}" r="{r}" fill="#FFFFFF" fill-opacity="{o:.2f}"/>' for sx, sy, r, o in stars(geo["stars"]))
    under = f'<rect {shape} fill="{NAVY}" filter="url(#{p}shadow)"/>' if shadow else ""
    rim = (f'<rect x="{x + 1.5}" y="{y + 1.5}" width="{s - 3}" height="{s - 3}" rx="{max(0, radius - 1.5)}" '
           f'fill="none" stroke="url(#{p}rim)" stroke-width="3"/>')
    return defs, under, fill, rim


def icon_svg(geo=FULL, full_bleed=False, radius=BODY[3]):
    bd, under, fill, rim = background("b", radius, shadow=not full_bleed, geo=geo)
    wd, wb = warp("w", geo)
    view = f"{BODY[0]} {BODY[0]} {BODY[2]} {BODY[2]}" if full_bleed else None
    return doc(1024, 1024, bd + wd, f'{under}<g clip-path="url(#bclip)">{fill}{wb}</g>{rim}', view)


# ---------------------------------------------------------------- type

class Font:
    def __init__(self, file, wght=None):
        self.font = TTFont(FONTS / file)
        self.glyphs = self.font.getGlyphSet(location={"wght": wght} if wght else None)
        self.cmap = self.font.getBestCmap()
        self.upm = self.font["head"].unitsPerEm
        b = BoundsPen(self.glyphs)
        self.glyphs[self.cmap[ord("H")]].draw(b)
        self.cap = b.bounds[3] / self.upm

    def layout(self, s, size, x, baseline, tracking=0.0):
        k, out, cur = size / self.upm, [], 0.0
        for ch in s:
            g = self.cmap[ord(ch)]
            pen = SVGPathPen(self.glyphs)
            self.glyphs[g].draw(TransformPen(pen, (k, 0, 0, -k, x + cur * k, baseline)))
            out.append(pen.getCommands())
            cur += self.glyphs[g].width + tracking * self.upm
        return " ".join(out), (cur - tracking * self.upm) * k


DISPLAY = WIDE = None
DESCRIPTOR = "REIMAGINED VLC"


def wordmark(p, x, base, size, mode="color", speed=False):
    """'RVLC' in Unbounded ExtraBold. mode: color | color-dark | light | dark."""
    path, w = DISPLAY.layout("RVLC", size, x, base, 0.05)
    if mode == "color":
        defs, fill = lin(f"{p}word", x, 0, x + w, 0, (0, "#C4B5FD", 1), (0.45, TEXT, 1), (1, "#93C5FD", 1)), f"url(#{p}word)"
    elif mode == "color-dark":
        defs, fill = lin(f"{p}word", x, 0, x + w, 0, (0, "#5B21B6", 1), (0.45, NAVY, 1), (1, "#1D4ED8", 1)), f"url(#{p}word)"
    else:
        defs, fill = "", TEXT if mode == "light" else NAVY
    body = f'<path d="{path}" fill="{fill}"/>'
    if speed:
        lead = x - size * 0.2
        defs += lin(f"{p}speed", lead - size * 0.95, 0, lead, 0, (0, PURPLE, 0), (1, PURPLE if mode.startswith("color") else fill, 1))
        body = "".join(
            f'<rect x="{lead - L * size:.1f}" y="{base - size * f:.1f}" width="{L * size:.1f}" height="{size * 0.05:.1f}" '
            f'rx="{size * 0.025:.1f}" fill="url(#{p}speed)"/>' for L, f in ((0.6, 0.62), (0.95, 0.4), (0.46, 0.18))) + body
    return defs, body, w


def lockup(variant):
    """Icon + wordmark + descriptor. variant: dark | light | mono-light | mono-dark."""
    tile, gap, size = 256, 64, 118
    x0 = tile + gap
    k = tile / BODY[2]
    place = f'translate({-BODY[0] * k:.3f} {-BODY[0] * k:.3f}) scale({k:.5f})'
    if variant.startswith("mono"):
        ink_mode = "light" if variant == "mono-light" else "dark"
        sd, sb = warp("s", FULL, ink_mode)
        defs, mark = sd, f'<g transform="{place}">{sb}</g>'
        wd, wb, ww = wordmark("w", x0, 150, size, ink_mode)
        sub = TEXT if ink_mode == "light" else NAVY
    else:
        bd, _, fill, rim = background("t", shadow=False)
        sd, sb = warp("s", FULL)
        defs, mark = bd + sd, f'<g transform="{place}"><g clip-path="url(#tclip)">{fill}{sb}</g>{rim}</g>'
        wd, wb, ww = wordmark("w", x0, 150, size, "color" if variant == "dark" else "color-dark")
        sub = MUTED if variant == "dark" else "#64748B"
    sp, sw = WIDE.layout(DESCRIPTOR, 26, x0 + 4, 214, 0.32)
    W = math.ceil(x0 + max(ww, sw) + 24)
    return doc(W, 256, defs + wd, f'{mark}{wb}<path d="{sp}" fill="{sub}"/>')


def wordmark_svg(mode):
    size = 200
    wd, wb, ww = wordmark("w", 240, 180, size, mode, speed=True)
    return doc(math.ceil(240 + ww + 10), 220, wd, wb, f"20 20 {math.ceil(220 + ww + 10)} 180")


def social_preview():
    W, H = 1280, 640
    rs = rings(FULL)
    big = 1.55
    cx, cy = CENTER
    tx, ty = 1010 - cx * big, 320 - cy * big
    paths = "".join(f'<path d="{rounded(pts, cr)}" fill="none" stroke="{col}" stroke-opacity="{op:.2f}" '
                    f'stroke-width="{w:.1f}" stroke-linejoin="round"/>' for pts, cr, col, op, w in rs)
    core = rounded(play_points(cx, cy, FULL["core"]), FULL["core"] * 0.2)
    defs = (blur("g", 22) + blur("gc", 6)
            + rad("t", 1010, 320, 620, (0, BLUE, 0.3), (0.5, PURPLE, 0.14), (1, NAVY, 0))
            + rad("l", 260, 200, 600, (0, PURPLE, 0.16), (1, PURPLE, 0)))
    st = "".join(f'<circle cx="{x * 1.25:.0f}" cy="{y * 0.62:.0f}" r="{r}" fill="#FFFFFF" fill-opacity="{o:.2f}"/>' for x, y, r, o in stars(110))
    tunnel = (f'<g transform="translate({tx:.1f} {ty:.1f}) scale({big})"><g filter="url(#g)" opacity="0.9">{paths}</g>{paths}'
              f'<path d="{core}" fill="#FFF" filter="url(#gc)"/><path d="{core}" fill="#FFF"/></g>')
    wd, wb, _ = wordmark("w", 96, 280, 150, "color")
    body = [f'<rect width="{W}" height="{H}" fill="{NAVY}"/>', f'<rect width="{W}" height="{H}" fill="url(#t)"/>',
            f'<rect width="{W}" height="{H}" fill="url(#l)"/>', st, tunnel, wb]
    sp, _ = WIDE.layout(DESCRIPTOR, 26, 102, 336, 0.32)
    body.append(f'<path d="{sp}" fill="{MUTED}"/>')
    tp, _ = WIDE.layout("PLAY ANYTHING. FIX EVERYTHING.", 24, 102, 430, 0.08)
    body.append(f'<path d="{tp}" fill="{TEXT}"/>')
    x = 100
    for label in ("SMART SUBTITLE SYNC", "NATIVE MACOS", "PRIVATE"):
        lp, lw = WIDE.layout(label, 15, 0, 0, 0.16)
        w = lw + 44
        body.append(f'<rect x="{x}" y="472" width="{w:.1f}" height="42" rx="21" fill="{SLATE}" stroke="#FFFFFF" stroke-opacity="0.08"/>')
        body.append(f'<path transform="translate({x + 22} 499)" d="{lp}" fill="{MUTED}"/>')
        x += w + 12
    return doc(W, H, defs + wd, "\n".join(body))


# ---------------------------------------------------------------- rendering

def render_many(jobs):
    """jobs: list of (svg text, output path, width, height). Renders with headless Chrome."""
    with tempfile.TemporaryDirectory() as tmp:
        for i, (svg, out, w, h) in enumerate(jobs):
            (Path(tmp) / f"{i}.svg").write_text(svg)
            page = Path(tmp) / f"{i}.html"
            page.write_text(f'<html><body style="margin:0;background:transparent">'
                            f'<img src="{i}.svg" width="{w}" height="{h}" style="display:block"></body></html>')
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                            f"--user-data-dir={tmp}/profile", "--default-background-color=00000000",
                            f"--window-size={w},{h}", f"--screenshot={out}", page.as_uri()],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def downscale(src, dst, px):
    Image.open(src).convert("RGBA").resize((px, px), Image.LANCZOS).save(dst)


def width_of(svg):
    return int(svg.split('width="')[1].split('"')[0])


def main():
    global DISPLAY, WIDE
    DISPLAY = Font("Unbounded[wght].ttf", 800)
    WIDE = Font("Michroma-Regular.ttf")
    for d in (SVG, PNG, WEB, MACOS):
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)

    sd, sb = warp("s")
    crop = "160 152 720 720"
    svgs = {
        "icon.svg": icon_svg(),
        "icon-compact.svg": icon_svg(COMPACT),
        "tile.svg": icon_svg(full_bleed=True),
        "symbol.svg": doc(720, 720, sd, sb, crop),
        "symbol-mono-light.svg": doc(720, 720, *warp("s", FULL, "light"), crop),
        "symbol-mono-dark.svg": doc(720, 720, *warp("s", FULL, "dark"), crop),
        "logo-dark.svg": lockup("dark"),
        "logo-light.svg": lockup("light"),
        "logo-mono-light.svg": lockup("mono-light"),
        "logo-mono-dark.svg": lockup("mono-dark"),
        "wordmark.svg": wordmark_svg("color"),
        "wordmark-dark.svg": wordmark_svg("color-dark"),
        "social-preview.svg": social_preview(),
    }
    for name, text in svgs.items():
        (SVG / name).write_text(text)

    favicon = icon_svg(COMPACT, full_bleed=True)
    square = icon_svg(full_bleed=True, radius=0)
    (WEB / "favicon.svg").write_text(favicon)
    jobs = [
        (svgs["icon.svg"], PNG / "icon-1024.png", 1024, 1024),
        (svgs["icon-compact.svg"], PNG / "icon-compact-1024.png", 1024, 1024),
        (svgs["symbol.svg"], PNG / "symbol-512.png", 512, 512),
        (svgs["symbol-mono-light.svg"], PNG / "symbol-mono-light-512.png", 512, 512),
        (svgs["symbol-mono-dark.svg"], PNG / "symbol-mono-dark-512.png", 512, 512),
        (svgs["social-preview.svg"], PNG / "social-preview.png", 1280, 640),
        (favicon, WEB / "favicon-256.png", 256, 256),
        (svgs["tile.svg"], WEB / "icon-512.png", 512, 512),
        (square, WEB / "avatar-512.png", 512, 512),
    ]
    for name in ("logo-dark", "logo-light", "logo-mono-light", "logo-mono-dark"):
        w = width_of(svgs[f"{name}.svg"])
        jobs.append((svgs[f"{name}.svg"].replace(f'width="{w}" height="256"', f'width="{w * 2}" height="512"', 1),
                     PNG / f"{name}@2x.png", w * 2, 512))
    render_many(jobs)

    # Raster sizes: full artwork from 64 px up, compact artwork below.
    for px in (16, 32, 64, 128, 256, 512):
        downscale(PNG / ("icon-compact-1024.png" if px <= 32 else "icon-1024.png"), PNG / f"icon-{px}.png", px)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = base * scale
                src = PNG / ("icon-compact-1024.png" if px <= 32 else "icon-1024.png")
                downscale(src, iconset / f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png", px)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(MACOS / "AppIcon.icns")], check=True)

    fav = Image.open(WEB / "favicon-256.png").convert("RGBA")
    fav.resize((48, 48), Image.LANCZOS).save(WEB / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    fav.resize((32, 32), Image.LANCZOS).save(WEB / "favicon-32.png")
    (WEB / "favicon-256.png").unlink()
    Image.open(WEB / "avatar-512.png").convert("RGB").resize((180, 180), Image.LANCZOS).save(WEB / "apple-touch-icon.png")
    Image.open(WEB / "icon-512.png").convert("RGBA").resize((192, 192), Image.LANCZOS).save(WEB / "icon-192.png")

    board()
    print("Wrote", sum(1 for f in ROOT.rglob("*") if f.is_file()), "files to", ROOT)


def board():
    """Overview sheet of the identity, for review."""
    W, H = 2000, 1500
    img = Image.new("RGB", (W, H), NAVY)
    d = ImageDraw.Draw(img)
    wide = lambda s: ImageFont.truetype(str(FONTS / "Michroma-Regular.ttf"), s)
    d.text((80, 60), "RVLC  /  BRAND IDENTITY  /  WARP", font=wide(40), fill=TEXT)
    d.text((80, 124), "Nested play shapes twisting into a tunnel around a bright play core.", font=wide(18), fill=MUTED)

    def paste(path, box, height=None, width=None):
        im = Image.open(path).convert("RGBA")
        if height:
            im = im.resize((int(im.width * height / im.height), height), Image.LANCZOS)
        if width:
            im = im.resize((width, int(im.height * width / im.width)), Image.LANCZOS)
        img.paste(im, box, im)

    d.rounded_rectangle((80, 180, 680, 780), 28, fill=SLATE)
    paste(PNG / "icon-1024.png", (110, 210), height=540)
    d.rounded_rectangle((720, 180, 1920, 470), 28, fill=SLATE)
    paste(PNG / "logo-dark@2x.png", (790, 245), height=160)
    d.rounded_rectangle((720, 490, 1920, 780), 28, fill=TEXT)
    paste(PNG / "logo-light@2x.png", (790, 555), height=160)

    x, y = 80, 830
    for px in (16, 32, 64, 128, 256):
        paste(PNG / f"icon-{px}.png", (x, y + 256 - px))
        d.text((x, y + 272), f"{px}", font=wide(16), fill=MUTED)
        x += max(px, 32) + 40
    for name, bg in (("symbol-mono-light-512.png", SLATE), ("symbol-mono-dark-512.png", TEXT)):
        d.rounded_rectangle((x, y, x + 256, y + 256), 24, fill=bg)
        paste(PNG / name, (x + 18, y + 18), height=220)
        x += 280
    paste(PNG / "social-preview.png", (1380, 830), width=540)
    sw = [("PURPLE", PURPLE), ("ELECTRIC BLUE", BLUE), ("NAVY-BLACK", NAVY), ("DARK SLATE", SLATE), ("OFF-WHITE", TEXT), ("COOL GRAY", MUTED)]
    for i, (label, hexv) in enumerate(sw):
        cx, cy = 80 + i * 310, 1190
        d.rounded_rectangle((cx, cy, cx + 280, cy + 200), 22, fill=hexv, outline="#2A3142", width=2)
        ink = NAVY if hexv in (TEXT, MUTED) else TEXT
        d.text((cx + 22, cy + 120), label, font=wide(18), fill=ink)
        d.text((cx + 22, cy + 152), hexv, font=wide(16), fill=ink)
    img.save(ROOT / "board.png")


if __name__ == "__main__":
    main()
