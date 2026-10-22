import Foundation

/// Audio enhancement settings translated into an mpv `af` filter chain.
///
/// All filters are FFmpeg libavfilter filters available through mpv's `lavfi`
/// wrapper; nothing here re-implements DSP.
public struct AudioEffects: Equatable, Sendable {
    public enum Equalizer: String, CaseIterable, Sendable {
        case flat, voice, bass, treble, night

        public var title: String {
            switch self {
            case .flat: return "Flat"
            case .voice: return "Dialogue boost"
            case .bass: return "Bass boost"
            case .treble: return "Treble boost"
            case .night: return "Night mode (compressed)"
            }
        }

        /// (frequency Hz, gain dB) peaking bands.
        var bands: [(Int, Double)] {
            switch self {
            case .flat, .night: return []
            case .voice: return [(250, -2), (1000, 2), (2500, 4), (4000, 3), (8000, -1)]
            case .bass: return [(60, 6), (150, 4), (400, 1)]
            case .treble: return [(4000, 2), (8000, 4), (12000, 4)]
            }
        }
    }

    /// Dynamic normalisation evens out quiet dialogue and loud effects.
    public var normalize: Bool
    public var equalizer: Equalizer
    /// Insert a limiter so amplification above 100 % does not clip.
    public var limiter: Bool

    public init(normalize: Bool = false, equalizer: Equalizer = .flat, limiter: Bool = false) {
        self.normalize = normalize
        self.equalizer = equalizer
        self.limiter = limiter
    }

    public var filterChain: String {
        var filters: [String] = []
        for (freq, gain) in equalizer.bands {
            filters.append("lavfi=[equalizer=f=\(freq):t=q:w=1:g=\(gain)]")
        }
        if equalizer == .night {
            filters.append("lavfi=[acompressor=threshold=0.1:ratio=4:attack=10:release=200:makeup=2]")
        }
        if normalize {
            filters.append("lavfi=[dynaudnorm=f=250:g=15:p=0.9]")
        }
        if limiter || equalizer != .flat {
            // Boosted bands and amplification can exceed full scale; limit just below 0 dBFS.
            filters.append("lavfi=[alimiter=limit=0.97:level=disabled]")
        }
        return filters.joined(separator: ",")
    }
}

/// Video picture settings applied through mpv properties.
public struct VideoAdjustments: Equatable, Sendable {
    public enum Aspect: String, CaseIterable, Sendable {
        case auto = "no", r16x9 = "16:9", r4x3 = "4:3", r21x9 = "2.33:1", r235 = "2.35:1", r1x1 = "1:1"
        public var title: String { self == .auto ? "Automatic" : rawValue }
    }

    public enum Fit: String, CaseIterable, Sendable {
        case fit, fill, stretch
        public var title: String {
            switch self {
            case .fit: return "Fit (letterbox)"
            case .fill: return "Fill (crop)"
            case .stretch: return "Stretch"
            }
        }
    }

    public var aspect: Aspect = .auto
    public var fit: Fit = .fit
    public var brightness = 0
    public var contrast = 0
    public var saturation = 0
    public var gamma = 0
    public var rotation = 0

    public init() {}

    /// mpv property assignments for this configuration.
    public var properties: [(String, String)] {
        [
            ("video-aspect-override", aspect.rawValue),
            ("panscan", fit == .fill ? "1.0" : "0.0"),
            ("keepaspect", fit == .stretch ? "no" : "yes"),
            ("brightness", String(brightness)),
            ("contrast", String(contrast)),
            ("saturation", String(saturation)),
            ("gamma", String(gamma)),
            ("video-rotate", String(rotation)),
        ]
    }

    public var isDefault: Bool { self == VideoAdjustments() }
}

public extension MPVPlayer {
    func apply(_ adjustments: VideoAdjustments) {
        for (name, value) in adjustments.properties { try? setProperty(name, value) }
    }

    func apply(_ effects: AudioEffects) throws {
        try setAudioFilters(effects.filterChain)
    }
}
