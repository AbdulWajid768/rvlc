import Foundation

public enum SubtitleIO {
    public static let fileExtensions = ["srt", "vtt", "ass", "ssa"]
    /// Subtitle files are untrusted input; refuse absurdly large files.
    public static let maxBytes = 20 * 1_048_576

    /// Encodings offered when automatic decoding produces wrong characters (IANA name, label).
    public static let commonEncodings: [(name: String, label: String)] = [
        ("utf-8", "Unicode (UTF-8)"),
        ("utf-16", "Unicode (UTF-16)"),
        ("windows-1252", "Western (Windows-1252)"),
        ("iso-8859-1", "Western (ISO Latin 1)"),
        ("iso-8859-15", "Western (ISO Latin 9)"),
        ("windows-1250", "Central European (Windows-1250)"),
        ("iso-8859-2", "Central European (ISO Latin 2)"),
        ("windows-1251", "Cyrillic (Windows-1251)"),
        ("koi8-r", "Cyrillic (KOI8-R)"),
        ("windows-1253", "Greek (Windows-1253)"),
        ("windows-1254", "Turkish (Windows-1254)"),
        ("windows-1255", "Hebrew (Windows-1255)"),
        ("windows-1256", "Arabic (Windows-1256)"),
        ("windows-874", "Thai (Windows-874)"),
        ("shift_jis", "Japanese (Shift JIS)"),
        ("gb18030", "Chinese Simplified (GB 18030)"),
        ("big5", "Chinese Traditional (Big5)"),
        ("euc-kr", "Korean (EUC-KR)"),
    ]

    public static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: Decoding

    public struct Decoded: Equatable {
        public var text: String
        public var encoding: String
        public var hadBOM: Bool
        /// True when a legacy encoding was chosen heuristically.
        public var guessed: Bool
    }

    /// Decodes subtitle bytes: explicit encoding → BOM → strict UTF-8 → UTF-16 heuristic → Windows-1252.
    public static func decode(_ data: Data, encoding: String? = nil) throws -> Decoded {
        let bytes = [UInt8](data.prefix(4))
        let utf8BOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let utf16BOM = bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
        if let encoding {
            let name = encoding.lowercased()
            if name == "utf-8", utf8BOM, let s = String(data: data.dropFirst(3), encoding: .utf8) {
                return Decoded(text: s, encoding: "utf-8", hadBOM: true, guessed: false)
            }
            guard let enc = stringEncoding(forIANAName: name), let s = String(data: data, encoding: enc) else {
                throw SubtitleError.decodingFailed(encoding: encoding)
            }
            return Decoded(text: s, encoding: name, hadBOM: false, guessed: false)
        }
        if utf8BOM {
            let s = String(decoding: data.dropFirst(3), as: UTF8.self)
            return Decoded(text: s, encoding: "utf-8", hadBOM: true, guessed: false)
        }
        if utf16BOM, let s = String(data: data, encoding: .utf16) {
            return Decoded(text: s, encoding: "utf-16", hadBOM: true, guessed: false)
        }
        // UTF-16 without a BOM must be detected before UTF-8: ASCII text in
        // UTF-16 is also valid UTF-8 (NUL is a valid byte) but full of NULs.
        let head = data.prefix(400)
        if head.filter({ $0 == 0 }).count > head.count / 5 {
            // ASCII in UTF-16LE has its NULs at odd offsets, in UTF-16BE at even offsets.
            let bytes = [UInt8](head)
            let oddNuls = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let evenNuls = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let order: [(String.Encoding, String)] =
                oddNuls >= evenNuls
                ? [(.utf16LittleEndian, "utf-16le"), (.utf16BigEndian, "utf-16be")]
                : [(.utf16BigEndian, "utf-16be"), (.utf16LittleEndian, "utf-16le")]
            for (enc, name) in order {
                if let s = String(data: data, encoding: enc) {
                    return Decoded(text: s, encoding: name, hadBOM: false, guessed: true)
                }
            }
        }
        if let s = String(data: data, encoding: .utf8) {
            return Decoded(text: s, encoding: "utf-8", hadBOM: false, guessed: false)
        }
        if let s = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: s, encoding: "windows-1252", hadBOM: false, guessed: true)
        }
        return Decoded(text: String(decoding: data, as: UTF8.self), encoding: "utf-8", hadBOM: false, guessed: true)
    }

    // MARK: Detection and parsing

    public static func detectFormat(_ text: String, filename: String? = nil) throws -> SubtitleFormat {
        var head = Substring(text.prefix(4096))
        while let first = head.first, first == "\u{FEFF}" || first.isWhitespace { head.removeFirst() }
        if head.hasPrefix("WEBVTT") { return .vtt }
        if head.range(of: "[script info]", options: .caseInsensitive) != nil { return .ass }
        if head.range(of: #"\d+:\d\d:\d\d[,.]\d+\s*-->"#, options: .regularExpression) != nil { return .srt }
        switch (filename as NSString?)?.pathExtension.lowercased() {
        case "vtt": return .vtt
        case "ass", "ssa": return .ass
        case "srt": return .srt
        default: throw SubtitleError.unrecognizedFormat
        }
    }

    public static func parse(_ text: String, filename: String? = nil) throws -> SubtitleDocument {
        switch try detectFormat(text, filename: filename) {
        case .srt: return try SRTCodec.parse(text)
        case .vtt: return try WebVTTCodec.parse(text)
        case .ass: return try ASSCodec.parse(text)
        }
    }

    /// Reads at most `maxBytes` from a regular file. Symlinks are resolved first so
    /// a link to a device, FIFO or huge file cannot bypass the limit.
    static func readLimited(_ url: URL) throws -> Data {
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SubtitleError.binaryFile }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw SubtitleError.tooLarge(bytes: size) }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw SubtitleError.tooLarge(bytes: data.count) }
        return data
    }

    public static func load(_ url: URL, encoding: String? = nil) throws -> SubtitleDocument {
        let data = try readLimited(url)
        let head = data.prefix(4096)
        let nulCount = head.filter { $0 == 0 }.count
        let looksUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) || nulCount > head.count / 4
        if nulCount > 0, !looksUTF16 { throw SubtitleError.binaryFile }
        let decoded = try decode(data, encoding: encoding)
        var document = try parse(decoded.text, filename: url.lastPathComponent)
        document.sourceURL = url
        document.encoding = decoded.encoding
        document.hadBOM = decoded.hadBOM
        if decoded.guessed {
            document.warnings.insert(
                "The file is not valid UTF-8 and was decoded as \(decoded.encoding). If characters look wrong, choose the correct encoding.",
                at: 0)
        }
        return document
    }

    // MARK: Export

    public struct Prepared {
        public var cues: [Cue]
        public var warnings: [String]
    }

    /// Applies `transform`, validates the result and converts cue text for `target`.
    /// The returned cues already include the transform.
    public static func prepare(_ document: SubtitleDocument, transform: TimingTransform, target: SubtitleFormat) -> Prepared {
        var warnings: [String] = []
        let fromASS = document.format == .ass && target != .ass
        if fromASS {
            warnings.append(
                "ASS styling (fonts, colours, positioning and effects) cannot be represented in \(target.displayName). "
                    + "\(ASSCodec.overrideTagCount(document)) override tag(s) were removed and the text was kept.")
        }
        var result: [Cue] = []
        var dropped = 0, clamped = 0, comments = 0
        for index in document.sortedIndices() {
            let cue = document.cues[index]
            if fromASS, cue.isComment { comments += 1; continue }
            var start = transform.apply(cue.startMs)
            var end = transform.apply(cue.endMs)
            if end <= 0 { dropped += 1; continue }
            if start < 0 { start = 0; clamped += 1 }
            end = max(end, start)
            var meta = fromASS ? [:] : cue.meta
            if target != .vtt {
                meta.removeValue(forKey: "identifier")
                meta.removeValue(forKey: "settings")
            }
            var text = fromASS ? ASSCodec.plainText(cue.text) : cue.text
            if document.format == .vtt {
                // Karaoke timestamps inside WebVTT cues move with the cue; other formats cannot represent them.
                text = target == .vtt ? WebVTTCodec.shiftInlineTimestamps(text, transform) : WebVTTCodec.stripInlineTimestamps(text)
            }
            result.append(Cue(startMs: start, endMs: end, text: text, meta: meta))
        }
        if dropped > 0 { warnings.append("\(dropped) line(s) would end before 0:00 with this offset and were omitted.") }
        if clamped > 0 { warnings.append("\(clamped) line(s) would start before 0:00; their start was set to 0:00.") }
        if comments > 0 { warnings.append("\(comments) ASS comment line(s) were not exported.") }
        return Prepared(cues: result, warnings: warnings)
    }

    public static func serialize(_ document: SubtitleDocument, cues: [Cue], target: SubtitleFormat) throws -> String {
        switch target {
        case .srt:
            return SRTCodec.write(cues)
        case .vtt:
            let header = document.format == .vtt && !document.header.isEmpty ? document.header : "WEBVTT"
            return WebVTTCodec.write(cues, header: header)
        case .ass:
            guard document.format == .ass else { throw SubtitleError.assExportRequiresASSSource }
            return ASSCodec.write(document: document, cues: cues)
        }
    }

    /// Renders the document with `transform` applied, e.g. for the playback preview file.
    public static func render(
        _ document: SubtitleDocument, transform: TimingTransform = .identity,
        target: SubtitleFormat? = nil
    ) throws -> (text: String, warnings: [String]) {
        let format = target ?? document.format
        let prepared = prepare(document, transform: transform, target: format)
        return (try serialize(document, cues: prepared.cues, target: format), prepared.warnings)
    }

    public struct ExportReport: Equatable {
        public var url: URL
        public var format: SubtitleFormat
        public var encoding: String
        public var cueCount: Int
        public var warnings: [String]
    }

    /// Writes a corrected copy of `document` atomically. The source file is never modified.
    @discardableResult
    public static func export(
        _ document: SubtitleDocument, to url: URL, transform: TimingTransform,
        format: SubtitleFormat, encoding: String = "utf-8"
    ) throws -> ExportReport {
        if let source = document.sourceURL, isSameFile(source, url) { throw SubtitleError.refusingToOverwriteSource }
        let prepared = prepare(document, transform: transform, target: format)
        let text = try serialize(document, cues: prepared.cues, target: format)
        var warnings = prepared.warnings
        var usedEncoding = encoding.lowercased()
        var data: Data
        if let enc = stringEncoding(forIANAName: usedEncoding), let encoded = text.data(using: enc, allowLossyConversion: false) {
            data = encoded
        } else {
            warnings.append("Some characters cannot be represented in \(encoding); the file was saved as UTF-8.")
            usedEncoding = "utf-8"
            data = Data(text.utf8)
        }
        if usedEncoding == "utf-8", document.hadBOM, document.encoding == "utf-8" {
            data = Data([0xEF, 0xBB, 0xBF]) + data
        }
        try data.write(to: url, options: .atomic)
        return ExportReport(url: url, format: format, encoding: usedEncoding, cueCount: prepared.cues.count, warnings: warnings)
    }

    /// True when both URLs name the same file, including hard links and the
    /// case-insensitive names APFS allows (`Movie.SRT` vs `movie.srt`).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let pa = a.standardizedFileURL.resolvingSymlinksInPath(), pb = b.standardizedFileURL.resolvingSymlinksInPath()
        if pa == pb { return true }
        guard FileManager.default.fileExists(atPath: pb.path),
            let ia = try? FileManager.default.attributesOfItem(atPath: pa.path),
            let ib = try? FileManager.default.attributesOfItem(atPath: pb.path)
        else { return false }
        return (ia[.systemNumber] as? NSNumber) == (ib[.systemNumber] as? NSNumber)
            && (ia[.systemFileNumber] as? NSNumber) == (ib[.systemFileNumber] as? NSNumber)
    }

    public static func suggestedExportURL(for source: URL?, format: SubtitleFormat) -> URL {
        guard let source else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("subtitles.\(format.fileExtension)")
        }
        let stem = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent().appendingPathComponent("\(stem).synced.\(format.fileExtension)")
    }
}
