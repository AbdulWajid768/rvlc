import Foundation

func normalizedLines(_ text: String) -> [Substring] {
    var t = text
    if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
    t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    return t.split(separator: "\n", omittingEmptySubsequences: false)
}

func isBlank(_ s: Substring) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

/// Splits `a --> b rest` into its parts.
func splitTimingLine(_ line: Substring) -> (Substring, Substring, Substring)? {
    guard let arrow = line.range(of: "-->") else { return nil }
    let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
    let right = line[arrow.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
    guard !left.isEmpty, !right.isEmpty else { return nil }
    let endToken = right.prefix(while: { $0 != " " && $0 != "\t" })
    let rest = right[endToken.endIndex...].drop(while: { $0 == " " || $0 == "\t" })
    return (Substring(left), endToken, rest)
}

/// SubRip (.srt) reader and writer.
///
/// The reader is tolerant of real-world files: missing or non-numeric indices,
/// `.` instead of `,`, short fractions and missing blank lines between cues are
/// accepted. Blocks with invalid timestamps are skipped and reported as warnings.
public enum SRTCodec {
    public static func parse(_ text: String) throws -> SubtitleDocument {
        let lines = normalizedLines(text)
        var cues: [Cue] = []
        var warnings: [String] = []
        var i = 0
        let n = lines.count
        while i < n {
            if isBlank(lines[i]) { i += 1; continue }
            var timingIndex: Int?
            if lines[i].contains("-->") {
                timingIndex = i
            } else if i + 1 < n, lines[i + 1].contains("-->") {
                timingIndex = i + 1
            }
            guard let t = timingIndex else {
                warnings.append("Line \(i + 1): ignored unexpected text")
                i += 1
                continue
            }
            var body: [Substring] = []
            var j = t + 1
            while j < n, !isBlank(lines[j]) {
                // Only a line with two valid timestamps ends the text; dialogue such as
                // "Me --> You" stays part of the cue.
                if let (a, b, _) = splitTimingLine(lines[j]), Timecode.parseSRT(a) != nil, Timecode.parseSRT(b) != nil {
                    // Next cue without a blank separator; its index line may already be in `body`.
                    if let last = body.last, !last.isEmpty, last.trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) {
                        body.removeLast()
                        j -= 1
                    }
                    break
                }
                body.append(lines[j])
                j += 1
            }
            defer { i = max(j, t + 1) }
            guard let (a, b, _) = splitTimingLine(lines[t]) else {
                warnings.append("Line \(t + 1): malformed timing line")
                continue
            }
            guard let start = Timecode.parseSRT(a), var end = Timecode.parseSRT(b) else {
                warnings.append("Line \(t + 1): invalid timestamp “\(lines[t].prefix(60))”")
                continue
            }
            if end < start {
                warnings.append("Line \(t + 1): end time before start time; end set to start")
                end = start
            }
            cues.append(Cue(startMs: start, endMs: end, text: body.joined(separator: "\n")))
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues(.srt) }
        return SubtitleDocument(format: .srt, cues: cues, warnings: warnings)
    }

    public static func write(_ cues: [Cue], transform: TimingTransform = .identity) -> String {
        var out: [String] = []
        for (index, cue) in cues.enumerated() {
            out.append(String(index + 1))
            out.append("\(Timecode.formatSRT(transform.apply(cue.startMs))) --> \(Timecode.formatSRT(transform.apply(cue.endMs)))")
            // Blank lines inside text would terminate the cue for other readers.
            // "-->" inside text would be read as a timing line by other players.
            let text = cue.text.replacingOccurrences(of: "-->", with: "→").split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !isBlank($0) }.joined(separator: "\n")
            out.append(text.isEmpty ? " " : text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
