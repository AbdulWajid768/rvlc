import AppKit

/// The RVLC icon, drawn in code so the runtime icon and the packaged
/// `.icns` come from one source (see `scripts/package-macos.sh`).
///
/// Motif ("Warp"): nested play shapes twisting into a tunnel around a bright
/// play core. The twist totals 120°, so the core points the same way as the
/// outer ring. Geometry matches `brand/generate.py` (1024-point grid, y down).
enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    private struct Artwork {
        let rings: Int
        let outerRadius: CGFloat
        let decay: CGFloat
        let width: (base: CGFloat, extra: CGFloat)
        let coreRadius: CGFloat
        let stars: Int
    }

    private static let full = Artwork(rings: 11, outerRadius: 340, decay: 0.84, width: (3, 15), coreRadius: 62, stars: 70)
    /// Fewer, heavier rings that stay legible at 16 and 32 px.
    private static let compact = Artwork(rings: 5, outerRadius: 350, decay: 0.72, width: (14, 22), coreRadius: 74, stars: 0)

    private static let center = CGPoint(x: 490, y: 512)

    private typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    private static let purple: RGB = (0x8B, 0x5C, 0xF6)
    private static let blue: RGB = (0x3B, 0x82, 0xF6)
    private static let ice: RGB = (0xE0, 0xE7, 0xFF)
    private static let navy: RGB = (0x0B, 0x0F, 0x1A)
    private static let deepSlate: RGB = (0x14, 0x18, 0x28)
    private static let white: RGB = (0xFF, 0xFF, 0xFF)

    private static func color(_ c: RGB, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
            locations: stops.map(\.0))!
    }

    static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = rect.width
        let art = s <= 32 ? compact : full
        let unit = s / 1024

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: unit, y: -unit)

        // Body: macOS icon grid, artwork inset ~10 % with a rounded square.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        if s >= 64 {
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 32 * unit, color: color((0, 0, 0), 0.45))
        }
        ctx.addPath(shape)
        ctx.setFillColor(color(navy))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, color(deepSlate)), (1, color(navy))]), start: CGPoint(x: 0, y: body.minY),
            end: CGPoint(x: 0, y: body.maxY), options: [])
        func glow(_ at: CGPoint, _ radius: CGFloat, _ stops: [(CGFloat, CGColor)]) {
            ctx.drawRadialGradient(gradient(stops), startCenter: at, startRadius: 0, endCenter: at, endRadius: radius, options: [])
        }
        glow(center, 520, [(0, color(purple, 0.2)), (0.6, color(purple, 0.05)), (1, color(purple, 0))])
        glow(CGPoint(x: 860, y: 900), 420, [(0, color(blue, 0.22)), (1, color(blue, 0))])
        glow(center, 380, [(0, color(blue, 0.35)), (0.5, color(purple, 0.18)), (1, color(navy, 0))])

        for star in stars(art.stars) {
            ctx.setFillColor(color(white, star.opacity))
            ctx.fillEllipse(in: CGRect(x: star.x - star.r, y: star.y - star.r, width: star.r * 2, height: star.r * 2))
        }

        // Tunnel: each ring is drawn once with a coloured glow, then crisp on top.
        ctx.setLineJoin(.round)
        for i in 0..<art.rings {
            let t = CGFloat(i) / CGFloat(art.rings - 1)
            let r = art.outerRadius * pow(art.decay, CGFloat(i))
            let rgb = t < 0.62 ? mix(purple, blue, min(1, t * 1.6)) : mix(blue, ice, (t - 0.62) / 0.38)
            let ring = roundedTriangle(playPoints(radius: r, rotation: CGFloat(i) * 120 / CGFloat(art.rings)), radius: r * 0.16)
            let opacity = 0.35 + 0.65 * t
            ctx.setLineWidth(art.width.base + art.width.extra * pow(1 - t, 1.2))
            ctx.setStrokeColor(color(rgb, opacity))
            for glowing in [true, false] {
                ctx.saveGState()
                if glowing { ctx.setShadow(offset: .zero, blur: 44 * unit, color: color(rgb, 0.9)) }
                ctx.addPath(ring)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        let core = roundedTriangle(playPoints(radius: art.coreRadius, rotation: 0), radius: art.coreRadius * 0.2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14 * unit, color: color(white))
        ctx.addPath(core)
        ctx.setFillColor(color(white))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
        ctx.setStrokeColor(color(white, 0.1))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Right-pointing equilateral triangle around the tunnel centre; angles run clockwise from 12 o'clock.
    private static func playPoints(radius r: CGFloat, rotation: CGFloat) -> [CGPoint] {
        (0..<3).map { k in
            let a = (90 + rotation + CGFloat(k) * 120) * .pi / 180
            return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
        }
    }

    /// Deterministic starfield; the LCG matches `stars()` in `brand/generate.py`.
    private static func stars(_ count: Int) -> [(x: CGFloat, y: CGFloat, r: CGFloat, opacity: CGFloat)] {
        var state: UInt64 = 7
        func next() -> CGFloat {
            state = (state &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            return CGFloat(state) / CGFloat(0x7FFF_FFFF)
        }
        let sizes: [CGFloat] = [1.2, 1.6, 2.2, 3.0]
        return (0..<count).map { _ in
            let x = 110 + next() * 804, y = 110 + next() * 804
            let r = sizes[min(3, Int(next() * 4))]
            return (x, y, r, 0.15 + 0.45 * next())
        }
    }

    private static func roundedTriangle(_ points: [CGPoint], radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        for i in 0...n {
            let v = points[i % n], prev = points[(i + n - 1) % n], next = points[(i + 1) % n]
            let dp = hypot(prev.x - v.x, prev.y - v.y), dn = hypot(next.x - v.x, next.y - v.y)
            let a = CGPoint(x: v.x + (prev.x - v.x) * r / dp, y: v.y + (prev.y - v.y) * r / dp)
            let b = CGPoint(x: v.x + (next.x - v.x) * r / dn, y: v.y + (next.y - v.y) * r / dn)
            if i == 0 {
                path.move(to: b)
            } else {
                path.addLine(to: a)
                path.addQuadCurve(to: b, control: v)
            }
        }
        path.closeSubpath()
        return path
    }

    /// Writes PNGs for an `.iconset` (used by the packaging script).
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0)
                else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
