import Foundation

/// WebVTT (.vtt) reader and writer.
public enum WebVTTCodec {
    static let inlineTimestamp = try! NSRegularExpression(pattern: #"<((?:\d{1,3}:)?[0-5]\d:[0-5]\d\.\d{3})>"#)

    /// Splits text into blocks separated by one or more blank lines.
    static func blocks(_ lines: [Substring]) -> [[Substring]] {
        var result: [[Substring]] = []
        var current: [Substring] = []
        for line in lines {
            if isBlank(line) {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func parse(_ text: String) throws -> SubtitleDocument {
        let blocks = blocks(normalizedLines(text))
        guard let first = blocks.first, first[0].hasPrefix("WEBVTT") else { throw SubtitleError.notWebVTT }
        var headerParts = [first.joined(separator: "\n")]
        var cues: [Cue] = []
        var warnings: [String] = []
        for var block in blocks.dropFirst() {
            let head = block[0]
            if !head.contains("-->"), head.hasPrefix("NOTE") || head.hasPrefix("STYLE") || head.hasPrefix("REGION") {
                // Header blocks before the first cue are preserved; NOTE comments between cues are dropped.
                if cues.isEmpty { headerParts.append(block.joined(separator: "\n")) }
                continue
            }
            var identifier = ""
            if !head.contains("-->") {
                identifier = String(head)
                block.removeFirst()
            }
            guard let timing = block.first else {
                warnings.append("Ignored block without timing: “\(identifier.prefix(40))”")
                continue
            }
            guard let (a, b, settings) = splitTimingLine(timing) else {
                warnings.append("Ignored block with malformed timing line: “\(timing.prefix(60))”")
                continue
            }
            guard let start = Timecode.parseVTT(a), var end = Timecode.parseVTT(b) else {
                warnings.append("Ignored cue with invalid timestamp: “\(timing.prefix(60))”")
                continue
            }
            if end < start {
                warnings.append("Cue at \(a): end time before start time; end set to start")
                end = start
            }
            var meta: [String: String] = [:]
            if !identifier.isEmpty { meta["identifier"] = identifier }
            let trimmedSettings = settings.trimmingCharacters(in: .whitespaces)
            if !trimmedSettings.isEmpty { meta["settings"] = trimmedSettings }
            cues.append(Cue(startMs: start, endMs: end, text: block.dropFirst().joined(separator: "\n"), meta: meta))
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues(.vtt) }
        return SubtitleDocument(format: .vtt, cues: cues, header: headerParts.joined(separator: "\n\n"), warnings: warnings)
    }

    /// Karaoke-style inline timestamps (`<00:01.500>`) move together with their cue.
    static func shiftInlineTimestamps(_ text: String, _ transform: TimingTransform) -> String {
        guard !transform.isIdentity, text.contains("<") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in inlineTimestamp.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let inner = ns.substring(with: match.range(at: 1))
            if let ms = Timecode.parseVTT(Substring(inner)) {
                result += "<\(Timecode.formatVTT(transform.apply(ms)))>"
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Removes karaoke timestamps (for export to formats that cannot represent them).
    static func stripInlineTimestamps(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return inlineTimestamp.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    public static func write(_ cues: [Cue], transform: TimingTransform = .identity, header: String = "WEBVTT") -> String {
        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = [trimmedHeader.isEmpty ? "WEBVTT" : trimmedHeader, ""]
        for cue in cues {
            if let id = cue.meta["identifier"], !id.isEmpty { out.append(id) }
            var timing = "\(Timecode.formatVTT(transform.apply(cue.startMs))) --> \(Timecode.formatVTT(transform.apply(cue.endMs)))"
            if let settings = cue.meta["settings"], !settings.isEmpty { timing += " " + settings }
            out.append(timing)
            // "-->" is not allowed inside cue text and blank lines would end the cue.
            let body = shiftInlineTimestamps(cue.text, transform).replacingOccurrences(of: "-->", with: "→")
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).filter { !isBlank($0) }
            out.append(lines.isEmpty ? " " : lines.joined(separator: "\n"))
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
