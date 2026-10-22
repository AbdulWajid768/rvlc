import Foundation

/// A pairing of a subtitle line's original start with the media time at which
/// that line is actually spoken.
public struct SyncPoint: Equatable, Codable, Sendable {
    public var subtitleMs: Int
    public var mediaMs: Int
    public var label: String

    public init(subtitleMs: Int, mediaMs: Int, label: String = "") {
        self.subtitleMs = subtitleMs
        self.mediaMs = mediaMs
        self.label = label
    }

    public var offsetMs: Int { mediaMs - subtitleMs }
}

public struct SyncSuggestion: Equatable, Sendable {
    public enum Method: String, Sendable { case offset, linear }

    public var transform: TimingTransform
    public var method: Method
    public var rmsErrorMs: Double
    public var pointCount: Int
    public var notes: [String]
    public var ratioName: String?

    public var summary: String {
        let direction = transform.offsetMs >= 0 ? "later" : "earlier"
        var text = String(format: "Shift subtitles %.3f s %@", Double(abs(transform.offsetMs)) / 1000.0, direction)
        if method == .linear {
            text += String(format: " and correct drift (×%.6f", transform.scale)
            text += ratioName.map { ", \($0))" } ?? ")"
        }
        return text
    }
}

/// Reference-point synchronisation.
///
/// One point determines a constant offset. Two or more points spread across
/// the file can also determine a linear drift correction `a·t + b`; the simpler
/// constant model is kept unless the linear model fits clearly better.
public enum SyncFit {
    /// Frame-rate conversions are the most common cause of drift.
    public static let knownRatios: [(name: String, ratio: Double)] = [
        ("23.976 → 25 fps", 25.0 / (24000.0 / 1001.0)),
        ("25 → 23.976 fps", (24000.0 / 1001.0) / 25.0),
        ("24 → 25 fps", 25.0 / 24.0),
        ("25 → 24 fps", 24.0 / 25.0),
        ("23.976 → 24 fps", 24.0 / (24000.0 / 1001.0)),
        ("24 → 23.976 fps", (24000.0 / 1001.0) / 24.0),
        ("29.97 → 25 fps", 25.0 / (30000.0 / 1001.0)),
        ("25 → 29.97 fps", (30000.0 / 1001.0) / 25.0),
    ]

    static let scaleRange = 0.8...1.25
    /// Below this drift (≈0.36 s per hour) the constant model is used.
    static let negligibleDrift = 0.0001
    static let minimumSpanMs = 60_000
    /// Maximum distance between a fitted scale and a known ratio for snapping.
    static let snapTolerance = 0.0003

    static func rms(_ points: [SyncPoint], _ t: TimingTransform) -> Double {
        guard !points.isEmpty else { return 0 }
        let sum = points.reduce(0.0) { acc, p in
            let e = Double(t.apply(p.subtitleMs) - p.mediaMs)
            return acc + e * e
        }
        return (sum / Double(points.count)).squareRoot()
    }

    /// Median offset: robust to a single mis-clicked point.
    static func constantFit(_ points: [SyncPoint]) -> TimingTransform {
        let offsets = points.map(\.offsetMs).sorted()
        let mid = offsets.count / 2
        let median = offsets.count % 2 == 1 ? Double(offsets[mid]) : Double(offsets[mid - 1] + offsets[mid]) / 2
        return TimingTransform(scale: 1, offsetMs: Int(median.rounded()))
    }

    static func leastSquares(_ points: [SyncPoint]) -> (a: Double, b: Double) {
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + Double($1.subtitleMs) } / n
        let my = points.reduce(0.0) { $0 + Double($1.mediaMs) } / n
        var sxx = 0.0, sxy = 0.0
        for p in points {
            let dx = Double(p.subtitleMs) - mx
            sxx += dx * dx
            sxy += dx * (Double(p.mediaMs) - my)
        }
        guard sxx > 0 else { return (1, my - mx) }
        let a = sxy / sxx
        return (a, my - a * mx)
    }

    public static func fit(_ points: [SyncPoint], allowDrift: Bool = true) -> SyncSuggestion? {
        guard !points.isEmpty else { return nil }
        var notes: [String] = []
        let constant = constantFit(points)
        let constantRMS = rms(points, constant)
        func constantResult() -> SyncSuggestion {
            SyncSuggestion(transform: constant, method: .offset, rmsErrorMs: constantRMS, pointCount: points.count, notes: notes)
        }
        guard points.count > 1, allowDrift else { return constantResult() }

        let span = (points.map(\.subtitleMs).max() ?? 0) - (points.map(\.subtitleMs).min() ?? 0)
        guard span >= minimumSpanMs else {
            notes.append("Sync points are less than a minute apart, so drift cannot be measured; only an offset is applied.")
            return constantResult()
        }
        let (a, b) = leastSquares(points)
        guard scaleRange.contains(a) else {
            notes.append("The sync points are inconsistent (implausible speed difference). Check that each point uses the right line.")
            return constantResult()
        }
        guard abs(a - 1) >= negligibleDrift else { return constantResult() }

        var linear = TimingTransform(scale: a, offsetMs: Int(b.rounded()))
        var linearRMS = rms(points, linear)
        var ratioName: String?
        // Snap to the closest common frame-rate ratio, but only when it is
        // genuinely close and does not make the fit worse. Some ratios are
        // only ~0.001 apart (23.976→25 vs 24→25), so the tolerance is tight.
        if let known = knownRatios.min(by: { abs(a - $0.ratio) < abs(a - $1.ratio) }), abs(a - known.ratio) < snapTolerance {
            let n = Double(points.count)
            let mx = points.reduce(0.0) { $0 + Double($1.subtitleMs) } / n
            let my = points.reduce(0.0) { $0 + Double($1.mediaMs) } / n
            let snapped = TimingTransform(scale: known.ratio, offsetMs: Int((my - known.ratio * mx).rounded()))
            let snappedRMS = rms(points, snapped)
            if snappedRMS <= linearRMS + 50 {
                linear = snapped
                linearRMS = snappedRMS
                ratioName = known.name
            }
        }
        // Accept the extra parameter only when it materially improves the fit.
        if constantRMS - linearRMS < 100 { return constantResult() }
        return SyncSuggestion(
            transform: linear, method: .linear, rmsErrorMs: linearRMS, pointCount: points.count,
            notes: notes, ratioName: ratioName)
    }
}
