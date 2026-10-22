import AppKit

/// The RVLC icon, drawn in code so the runtime icon and the packaged
/// `.icns` come from one source (see `scripts/package-macos.sh`).
///
/// Motif: a play symbol above two subtitle bars, the lower one shifted — the
/// act of moving subtitles into sync.
enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let s = rect.width
        // macOS icon grid: artwork inset ~10 % with a continuous-corner rounded square.
        let inset = s * 0.098
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = body.width * 0.225
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor(srgbRed: 0.12, green: 0.14, blue: 0.33, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.29, green: 0.36, blue: 0.95, alpha: 1),
            ending: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.42, alpha: 1))
        gradient?.draw(in: body, angle: -70)
        NSGraphicsContext.restoreGraphicsState()

        // Play triangle with rounded corners.
        let cx = body.midX + body.width * 0.035
        let cy = body.minY + body.height * 0.6
        let h = body.height * 0.34
        let w = h * 0.9
        let p1 = NSPoint(x: cx - w * 0.45, y: cy + h / 2)
        let p2 = NSPoint(x: cx - w * 0.45, y: cy - h / 2)
        let p3 = NSPoint(x: cx + w * 0.55, y: cy)
        let triangle = NSBezierPath()
        triangle.move(to: p1)
        triangle.line(to: p2)
        triangle.line(to: p3)
        triangle.close()
        triangle.lineJoinStyle = .round
        triangle.lineWidth = s * 0.05
        NSColor.white.setFill()
        NSColor.white.setStroke()
        triangle.fill()
        triangle.stroke()

        // Subtitle bars: the second one is offset — being synchronised.
        let barH = body.height * 0.065
        let bar1 = NSRect(x: body.minX + body.width * 0.2, y: body.minY + body.height * 0.25, width: body.width * 0.6, height: barH)
        let bar2 = NSRect(x: body.minX + body.width * 0.3, y: body.minY + body.height * 0.13, width: body.width * 0.4, height: barH)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: bar1, xRadius: barH / 2, yRadius: barH / 2).fill()
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar2, xRadius: barH / 2, yRadius: barH / 2).fill()
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
