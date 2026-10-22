import Foundation

/// Editing operations on subtitle documents.
public enum SubtitleEditing {
    public struct SearchOptions: Equatable, Sendable {
        public var caseSensitive = false
        public var wholeWord = false
        public var regularExpression = false
        public init(caseSensitive: Bool = false, wholeWord: Bool = false, regularExpression: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.regularExpression = regularExpression
        }
    }

    static func pattern(_ query: String, _ options: SearchOptions) throws -> NSRegularExpression {
        var body = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { body = "\\b(?:\(body))\\b" }
        return try NSRegularExpression(pattern: body, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    /// Indices of cues whose text matches `query`.
    public static func find(_ query: String, in document: SubtitleDocument, options: SearchOptions = .init()) throws -> [Int] {
        guard !query.isEmpty else { return [] }
        let regex = try pattern(query, options)
        return document.cues.indices.filter { i in
            let text = document.cues[i].text
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    /// Replaces matches in every cue (or only `indices`). Returns the number of replacements.
    @discardableResult
    public static func replaceAll(
        _ query: String, with replacement: String, in document: inout SubtitleDocument,
        options: SearchOptions = .init(), indices: [Int]? = nil
    ) throws -> Int {
        guard !query.isEmpty else { return 0 }
        let regex = try pattern(query, options)
        let template = options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        var total = 0
        for i in indices ?? Array(document.cues.indices) {
            let text = document.cues[i].text
            let range = NSRange(location: 0, length: (text as NSString).length)
            let count = regex.numberOfMatches(in: text, range: range)
            if count > 0 {
                document.cues[i].text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
                total += count
            }
        }
        return total
    }

    /// Moves one line by `deltaMs`, keeping its duration (never before 0:00).
    public static func shift(cue index: Int, by deltaMs: Int, in document: inout SubtitleDocument) {
        let delta = max(deltaMs, -document.cues[index].startMs)
        document.cues[index].startMs += delta
        document.cues[index].endMs += delta
    }

    public static func setTimes(cue index: Int, startMs: Int, endMs: Int, in document: inout SubtitleDocument) throws {
        guard startMs >= 0 else { throw SubtitleError.invalidTime("negative start") }
        guard endMs >= startMs else { throw SubtitleError.invalidTime("end before start") }
        document.cues[index].startMs = startMs
        document.cues[index].endMs = endMs
    }
}
