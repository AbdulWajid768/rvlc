import Foundation

// MARK: - Timing convention
//
// All subtitle timestamps are integer milliseconds on the media timeline.
//
// A `TimingTransform` maps an original subtitle timestamp `t` to the time at
// which it is displayed:
//
//     displayed = scale * t + offsetMs
//
// A POSITIVE offset makes subtitles appear LATER; a negative offset makes them
// appear earlier. `scale` corrects linear drift (for example 23.976 → 25 fps)
// and is 1.0 for the common constant-offset case.
//
// Original cue timestamps are never mutated by a transform. Transforms are
// applied only when rendering a preview or exporting, so repeated offset
// adjustments cannot accumulate into the stored timestamps.

public enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case srt, vtt, ass

    public var displayName: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .ass: return "Advanced SubStation (.ass)"
        }
    }

    public var fileExtension: String { rawValue }
}

public enum SubtitleError: LocalizedError, Equatable {
    case unrecognizedFormat
    case noCues(SubtitleFormat)
    case notWebVTT
    case notASS
    case tooLarge(bytes: Int)
    case binaryFile
    case decodingFailed(encoding: String)
    case refusingToOverwriteSource
    case assExportRequiresASSSource
    case invalidTime(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "Unrecognised subtitle format. Supported formats are SRT, WebVTT and ASS/SSA."
        case .noCues(let format):
            return "No valid subtitle lines were found in this \(format.displayName) file."
        case .notWebVTT:
            return "Not a WebVTT file: the first line must start with “WEBVTT”."
        case .notASS:
            return "Not an ASS/SSA file: the [Script Info] section is missing."
        case .tooLarge(let bytes):
            return "The file is too large to be a subtitle file (\(bytes / 1_048_576) MB)."
        case .binaryFile:
            return "This looks like a binary file, not a text subtitle."
        case .decodingFailed(let encoding):
            return "The file could not be decoded as \(encoding)."
        case .refusingToOverwriteSource:
            return "RVLC never overwrites the original subtitle file. Choose a different file name."
        case .assExportRequiresASSSource:
            return "Export to ASS is only available when the source file is ASS/SSA."
        case .invalidTime(let text):
            return "“\(text)” is not a valid time."
        }
    }
}

public struct Cue: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    /// Payload in the document's own markup: plain text with `\n` line breaks
    /// for SRT/VTT (inline tags such as `<i>` kept verbatim), or the raw ASS
    /// `Text` field (override tags and `\N` kept verbatim).
    public var text: String
    /// Format-specific data preserved for lossless round trips.
    /// VTT: "identifier", "settings". ASS: "kind" (Dialogue/Comment) plus every
    /// other event field by name (Layer, Style, Name, MarginL, …).
    public var meta: [String: String]

    public init(startMs: Int, endMs: Int, text: String, meta: [String: String] = [:]) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.meta = meta
    }

    public var durationMs: Int { endMs - startMs }
    public var isComment: Bool { meta["kind"] == "Comment" }
}

public struct TimingTransform: Equatable, Codable, Sendable {
    public var scale: Double
    public var offsetMs: Int

    public static let identity = TimingTransform()

    public init(scale: Double = 1.0, offsetMs: Int = 0) {
        self.scale = scale
        self.offsetMs = offsetMs
    }

    public func apply(_ ms: Int) -> Int {
        Int((scale * Double(ms) + Double(offsetMs)).rounded())
    }

    public func invert(_ displayedMs: Int) -> Int {
        Int(((Double(displayedMs) - Double(offsetMs)) / scale).rounded())
    }

    public var hasScale: Bool { abs(scale - 1.0) >= 1e-9 }
    public var isIdentity: Bool { offsetMs == 0 && !hasScale }

    public func withOffset(_ ms: Int) -> TimingTransform { TimingTransform(scale: scale, offsetMs: ms) }

    /// Drift expressed in seconds gained or lost per hour of subtitles.
    public var driftSecondsPerHour: Double { (scale - 1.0) * 3600.0 }
}

/// Human-readable signed offset, e.g. `+1.250 s` or `−0.100 s`.
public func formatOffset(_ ms: Int) -> String {
    let sign = ms >= 0 ? "+" : "−"
    return String(format: "%@%.3f s", sign, Double(abs(ms)) / 1000.0)
}

public struct SubtitleDocument: Equatable, Sendable {
    public var format: SubtitleFormat
    public var cues: [Cue]
    /// Raw text preserved verbatim: VTT header and NOTE/STYLE/REGION blocks
    /// before the first cue; ASS sections up to and including the Events Format line.
    public var header: String
    /// ASS only: event field names from the [Events] Format line.
    public var assFields: [String]
    /// ASS only: sections after [Events] (e.g. [Fonts], [Graphics]).
    public var trailer: String
    public var sourceURL: URL?
    /// IANA charset name of the source file, e.g. "utf-8" or "windows-1252".
    public var encoding: String
    public var hadBOM: Bool
    public var warnings: [String]

    public init(
        format: SubtitleFormat,
        cues: [Cue],
        header: String = "",
        assFields: [String] = [],
        trailer: String = "",
        sourceURL: URL? = nil,
        encoding: String = "utf-8",
        hadBOM: Bool = false,
        warnings: [String] = []
    ) {
        self.format = format
        self.cues = cues
        self.header = header
        self.assFields = assFields
        self.trailer = trailer
        self.sourceURL = sourceURL
        self.encoding = encoding
        self.hadBOM = hadBOM
        self.warnings = warnings
    }

    /// Cue indices ordered by start time (stable).
    public func sortedIndices() -> [Int] {
        cues.indices.sorted { a, b in
            cues[a].startMs == cues[b].startMs ? a < b : cues[a].startMs < cues[b].startMs
        }
    }

    /// Index of the cue displayed at `mediaMs` under `transform`.
    public func cueIndex(at mediaMs: Int, transform: TimingTransform = .identity) -> Int? {
        cues.indices.first { i in
            transform.apply(cues[i].startMs) <= mediaMs && mediaMs < transform.apply(cues[i].endMs)
        }
    }

    /// Index of the cue whose displayed start is closest to `mediaMs`.
    public func nearestCueIndex(to mediaMs: Int, transform: TimingTransform = .identity) -> Int? {
        cues.indices.min { a, b in
            abs(transform.apply(cues[a].startMs) - mediaMs) < abs(transform.apply(cues[b].startMs) - mediaMs)
        }
    }
}
