import Foundation

/// Advanced SubStation Alpha (.ass/.ssa) reader and writer.
///
/// Only the Start/End/Text fields of events are interpreted. Every other
/// section (script info, styles, fonts, graphics) and every other event field
/// is preserved verbatim so styling survives an ASS → ASS round trip.
public enum ASSCodec {
    public static let defaultFields = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
    static let overrideTag = try! NSRegularExpression(pattern: #"\{[^}]*\}"#)

    static func sectionName(_ line: Substring) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]"), t.count > 2 else { return nil }
        return String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ text: String) throws -> SubtitleDocument {
        let lines = normalizedLines(text)
        guard lines.prefix(80).contains(where: { sectionName($0)?.lowercased() == "script info" }) else {
            throw SubtitleError.notASS
        }
        var header: [Substring] = []
        var trailer: [Substring] = []
        var fields: [String] = []
        var cues: [Cue] = []
        var warnings: [String] = []
        var section = ""
        var afterEvents = false

        for (offset, line) in lines.enumerated() {
            let lineNo = offset + 1
            if let name = sectionName(line) {
                if section.lowercased() == "events" { afterEvents = true }
                section = name
                if afterEvents { trailer.append(line) } else { header.append(line) }
                continue
            }
            guard section.lowercased() == "events", !afterEvents else {
                if afterEvents { trailer.append(line) } else { header.append(line) }
                continue
            }
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.lowercased().hasPrefix("format:") {
                fields = stripped.dropFirst("format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                header.append(line)
                continue
            }
            guard let colon = stripped.firstIndex(of: ":") else {
                if !stripped.isEmpty, !stripped.hasPrefix(";") { warnings.append("Line \(lineNo): ignored unknown event line") }
                continue
            }
            let kind = String(stripped[..<colon])
            guard kind == "Dialogue" || kind == "Comment" else {
                if !stripped.hasPrefix(";") { warnings.append("Line \(lineNo): ignored “\(kind)” event") }
                continue
            }
            let names = fields.isEmpty ? defaultFields : fields
            let rest = stripped[stripped.index(after: colon)...].drop(while: { $0 == " " })
            let values = rest.split(separator: ",", maxSplits: names.count - 1, omittingEmptySubsequences: false)
            guard values.count == names.count else {
                warnings.append("Line \(lineNo): event has \(values.count) fields, expected \(names.count)")
                continue
            }
            var record: [String: String] = [:]
            for (name, value) in zip(names, values) { record[canonicalField(name)] = String(value) }
            guard let start = Timecode.parseASS(Substring(record["Start"] ?? "")),
                var end = Timecode.parseASS(Substring(record["End"] ?? ""))
            else {
                warnings.append("Line \(lineNo): invalid timestamp")
                continue
            }
            if end < start {
                warnings.append("Line \(lineNo): end time before start time; end set to start")
                end = start
            }
            let textValue = record.removeValue(forKey: "Text") ?? ""
            record.removeValue(forKey: "Start")
            record.removeValue(forKey: "End")
            record["kind"] = kind
            cues.append(Cue(startMs: start, endMs: end, text: textValue, meta: record))
        }
        if fields.isEmpty {
            fields = defaultFields
            warnings.append("No [Events] Format line found; assumed the ASS v4+ default.")
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues(.ass) }
        while let last = header.last, isBlank(last) { header.removeLast() }
        while let first = trailer.first, isBlank(first) { trailer.removeFirst() }
        while let last = trailer.last, isBlank(last) { trailer.removeLast() }
        return SubtitleDocument(
            format: .ass, cues: cues, header: header.joined(separator: "\n"),
            assFields: fields, trailer: trailer.joined(separator: "\n"), warnings: warnings)
    }

    public static func write(document: SubtitleDocument, cues: [Cue], transform: TimingTransform = .identity) -> String {
        let fields = document.assFields.isEmpty ? defaultFields : document.assFields
        var header = document.header
        if !header.lowercased().contains("[events]") {
            header += "\n\n[Events]\nFormat: " + fields.joined(separator: ", ")
        }
        var out = [header.trimmingCharacters(in: .newlines)]
        for cue in cues {
            var record = cue.meta
            let kind = record.removeValue(forKey: "kind") ?? "Dialogue"
            record["Start"] = Timecode.formatASS(transform.apply(cue.startMs))
            record["End"] = Timecode.formatASS(transform.apply(cue.endMs))
            record["Text"] = cue.text.replacingOccurrences(of: "\n", with: "\\N")
            out.append("\(kind): " + fields.map { record[canonicalField($0)] ?? "" }.joined(separator: ","))
        }
        var text = out.joined(separator: "\n") + "\n"
        if !document.trailer.isEmpty { text += "\n" + document.trailer + "\n" }
        return text
    }

    /// Field names are case-insensitive (as in libass); timing and text fields use one canonical spelling.
    static func canonicalField(_ name: String) -> String {
        switch name.lowercased() {
        case "start": return "Start"
        case "end": return "End"
        case "text": return "Text"
        case "style": return "Style"
        default: return name
        }
    }

    /// Converts an ASS text field to plain text (override tags removed).
    public static func plainText(_ text: String) -> String {
        let stripped = overrideTag.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        return stripped.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
    }

    public static func overrideTagCount(_ document: SubtitleDocument) -> Int {
        document.cues.reduce(0) { total, cue in
            total + overrideTag.numberOfMatches(in: cue.text, range: NSRange(location: 0, length: (cue.text as NSString).length))
        }
    }
}
