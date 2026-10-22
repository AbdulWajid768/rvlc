import Foundation

/// Parsing and formatting of subtitle and player timestamps.
public enum Timecode {
    struct Spec {
        var fractionSeparators: Set<Character>
        var fractionDigits: ClosedRange<Int>
        var fractionRequired: Bool
        var hoursOptional: Bool
        var maxHourDigits: Int
        var twoDigitMinutesSeconds: Bool
    }

    static let srtSpec = Spec(
        fractionSeparators: [",", "."], fractionDigits: 1...3, fractionRequired: false,
        hoursOptional: false, maxHourDigits: 3, twoDigitMinutesSeconds: false)
    static let vttSpec = Spec(
        fractionSeparators: ["."], fractionDigits: 3...3, fractionRequired: true,
        hoursOptional: true, maxHourDigits: 3, twoDigitMinutesSeconds: true)
    static let assSpec = Spec(
        fractionSeparators: ["."], fractionDigits: 1...3, fractionRequired: false,
        hoursOptional: false, maxHourDigits: 2, twoDigitMinutesSeconds: false)

    static func parse(_ raw: Substring, _ spec: Spec) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 || (spec.hoursOptional && parts.count == 2) else { return nil }
        if parts.count == 2 { parts.insert("0", at: 0) }
        let last = parts[2]
        var secondsPart = Substring(last)
        var fraction: Substring = ""
        if let sepIndex = last.firstIndex(where: { spec.fractionSeparators.contains($0) }) {
            secondsPart = last[..<sepIndex]
            fraction = last[last.index(after: sepIndex)...]
            guard spec.fractionDigits.contains(fraction.count) else { return nil }
        } else if spec.fractionRequired {
            return nil
        }
        func digits(_ s: Substring, maxLen: Int, exactLen: Int? = nil) -> Int? {
            guard !s.isEmpty, s.count <= maxLen, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber) else { return nil }
            if let exactLen, s.count != exactLen { return nil }
            return Int(s)
        }
        let exact = spec.twoDigitMinutesSeconds ? 2 : nil
        guard let h = digits(parts[0], maxLen: spec.maxHourDigits),
            let m = digits(parts[1], maxLen: 2, exactLen: exact),
            let s = digits(secondsPart, maxLen: 2, exactLen: exact),
            m < 60, s < 60
        else { return nil }
        var ms = 0
        if !fraction.isEmpty {
            guard let f = digits(fraction, maxLen: 3) else { return nil }
            // "5" → 500 ms, "05" → 50 ms, "005" → 5 ms
            ms = f * [1, 100, 10, 1][fraction.count]
        }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    public static func parseSRT(_ s: Substring) -> Int? { parse(s, srtSpec) }
    public static func parseVTT(_ s: Substring) -> Int? { parse(s, vttSpec) }
    public static func parseASS(_ s: Substring) -> Int? { parse(s, assSpec) }

    static func split(_ ms: Int) -> (Int, Int, Int, Int) {
        let v = max(0, ms)
        return (v / 3_600_000, (v / 60_000) % 60, (v / 1000) % 60, v % 1000)
    }

    public static func formatSRT(_ ms: Int) -> String {
        let (h, m, s, f) = split(ms)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, f)
    }

    public static func formatVTT(_ ms: Int) -> String {
        let (h, m, s, f) = split(ms)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, f)
    }

    /// ASS has centisecond precision; values are rounded to the nearest centisecond.
    public static func formatASS(_ ms: Int) -> String {
        let cs = Int((Double(max(0, ms)) / 10.0).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
    }

    /// Player clock, e.g. `4:07` or `1:02:03`.
    public static func formatClock(seconds: Double?, forceHours: Bool = false) -> String {
        var value = seconds ?? 0
        if !value.isFinite || value < 0 { value = 0 }
        let total = Int(value)
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        if h > 0 || forceHours { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Editor format with millisecond precision: `H:MM:SS.mmm`.
    public static func formatEditor(_ ms: Int) -> String {
        let (h, m, s, f) = split(ms)
        return String(format: "%d:%02d:%02d.%03d", h, m, s, f)
    }

    /// Lenient parser for times typed by the user: `H:MM:SS.mmm`, `M:SS.mmm`, `SS.mmm`, `,` as decimal mark.
    /// Largest time accepted from user input (999 hours).
    public static let maxEditorMs = 999 * 3_600_000

    public static func parseEditor(_ input: String) throws -> Int {
        let text = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        // Only digits, ':' and one decimal point: rejects exponents, signs, "inf", "nan".
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }),
            text.filter({ $0 == "." }).count <= 1
        else { throw SubtitleError.invalidTime(input) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 12 }),
            let sec = Double(parts[parts.count - 1]), sec.isFinite
        else { throw SubtitleError.invalidTime(input) }
        var minutes = 0, hours = 0
        if parts.count >= 2 {
            guard let m = Int(parts[parts.count - 2]), sec < 60 else { throw SubtitleError.invalidTime(input) }
            minutes = m
        }
        if parts.count == 3 {
            guard let h = Int(parts[0]), minutes < 60 else { throw SubtitleError.invalidTime(input) }
            hours = h
        }
        let total = ((Double(hours) * 60 + Double(minutes)) * 60 + sec) * 1000
        guard total <= Double(maxEditorMs) else { throw SubtitleError.invalidTime(input) }
        return Int(total.rounded())
    }

    public enum GoToTimeError: LocalizedError, Equatable {
        case invalid(String)
        case beyondEnd(duration: Double)

        public var errorDescription: String? {
            switch self {
            case .invalid(let text):
                return "“\(text)” is not a time. Use seconds (83), minutes:seconds (1:23) or hours:minutes:seconds (1:02:03)."
            case .beyondEnd(let duration):
                return "The video is only \(Timecode.formatClock(seconds: duration)) long."
            }
        }
    }

    /// Parses a time typed in “Go to Time…”: `83`, `83.5`, `1:23`, `1:02:03`, `1:02:03.250`.
    /// The result must lie within `0…duration` (when the duration is known).
    public static func parseGoTo(_ input: String, duration: Double?) throws -> Double {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ms = try? parseEditor(text) else { throw GoToTimeError.invalid(text) }
        let seconds = Double(ms) / 1000
        if let duration, duration > 0, seconds > duration { throw GoToTimeError.beyondEnd(duration: duration) }
        return seconds
    }
}
