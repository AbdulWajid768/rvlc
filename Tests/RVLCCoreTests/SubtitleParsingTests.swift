import XCTest

@testable import RVLCCore

final class TimecodeTests: XCTestCase {
    func testSRTTimestamps() {
        XCTAssertEqual(Timecode.parseSRT("00:00:01,500"), 1500)
        XCTAssertEqual(Timecode.parseSRT("01:02:03,004"), 3_723_004)
        XCTAssertEqual(Timecode.parseSRT("0:00:01.5"), 1500, "short fraction and dot separator are tolerated")
        XCTAssertEqual(Timecode.parseSRT("00:00:02"), 2000, "missing fraction is tolerated")
        XCTAssertNil(Timecode.parseSRT("00:61:00,000"), "minutes must be < 60")
        XCTAssertNil(Timecode.parseSRT("00:00:1x,000"))
        XCTAssertNil(Timecode.parseSRT("garbage"))
        XCTAssertNil(Timecode.parseSRT("00:00:01,5000"))
    }

    func testVTTTimestamps() {
        XCTAssertEqual(Timecode.parseVTT("00:01.250"), 1250)
        XCTAssertEqual(Timecode.parseVTT("01:00:00.000"), 3_600_000)
        XCTAssertNil(Timecode.parseVTT("00:01,250"), "WebVTT requires a dot")
        XCTAssertNil(Timecode.parseVTT("0:1.250"), "WebVTT requires two-digit minutes and seconds")
        XCTAssertNil(Timecode.parseVTT("00:01.25"), "WebVTT requires three fraction digits")
    }

    func testASSTimestamps() {
        XCTAssertEqual(Timecode.parseASS("0:00:01.50"), 1500)
        XCTAssertEqual(Timecode.formatASS(1504), "0:00:01.50")
        XCTAssertEqual(Timecode.formatASS(1505), "0:00:01.51", "rounds to nearest centisecond")
    }

    func testFormatting() {
        XCTAssertEqual(Timecode.formatSRT(3_723_004), "01:02:03,004")
        XCTAssertEqual(Timecode.formatVTT(3_723_004), "01:02:03.004")
        XCTAssertEqual(Timecode.formatSRT(-50), "00:00:00,000", "negative times clamp to zero")
        XCTAssertEqual(Timecode.formatClock(seconds: 65), "1:05")
        XCTAssertEqual(Timecode.formatClock(seconds: 3723), "1:02:03")
        XCTAssertEqual(Timecode.formatClock(seconds: .nan), "0:00")
        XCTAssertEqual(Timecode.formatClock(seconds: nil), "0:00")
    }

    func testEditorTimeParsing() throws {
        XCTAssertEqual(try Timecode.parseEditor("1:02:03.500"), 3_723_500)
        XCTAssertEqual(try Timecode.parseEditor("2:03,5"), 123_500)
        XCTAssertEqual(try Timecode.parseEditor("12.25"), 12_250)
        XCTAssertThrowsError(try Timecode.parseEditor("1:75"))
        XCTAssertThrowsError(try Timecode.parseEditor("abc"))
        XCTAssertThrowsError(try Timecode.parseEditor(""))
    }
}

final class SRTTests: XCTestCase {
    let sample = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello, world!

        2
        00:00:04,000 --> 00:00:06,000
        <i>Second</i> line
        with two rows

        """

    func testParsesCues() throws {
        let doc = try SRTCodec.parse(sample)
        XCTAssertEqual(doc.cues.count, 2)
        XCTAssertEqual(doc.cues[0], Cue(startMs: 1000, endMs: 3500, text: "Hello, world!"))
        XCTAssertEqual(doc.cues[1].text, "<i>Second</i> line\nwith two rows")
        XCTAssertTrue(doc.warnings.isEmpty)
    }

    func testCRLFAndBOMAndMissingIndices() throws {
        let text = "\u{FEFF}00:00:01,000 --> 00:00:02,000\r\nNo index\r\n\r\n7\r\n00:00:03,000 --> 00:00:04,000\r\nSeven\r\n"
        let doc = try SRTCodec.parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["No index", "Seven"])
    }

    func testMissingBlankLineBetweenCues() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nOne\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n"
        let doc = try SRTCodec.parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["One", "Two"])
        XCTAssertEqual(doc.cues[1].startMs, 3000)
    }

    func testUnicodeContent() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nこんにちは 👋🏽 — Ünïcödé\nمرحبا\n"
        let doc = try SRTCodec.parse(text)
        XCTAssertEqual(doc.cues[0].text, "こんにちは 👋🏽 — Ünïcödé\nمرحبا")
        let written = SRTCodec.write(doc.cues)
        XCTAssertEqual(try SRTCodec.parse(written).cues, doc.cues)
    }

    func testInvalidTimestampsAreSkippedWithWarnings() throws {
        let text = "1\n00:00:01,000 --> 00:00:0X,000\nBad\n\n2\n00:00:03,000 --> 00:00:04,000\nGood\n"
        let doc = try SRTCodec.parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["Good"])
        XCTAssertEqual(doc.warnings.count, 1)
    }

    func testEndBeforeStartIsCorrected() throws {
        let doc = try SRTCodec.parse("1\n00:00:05,000 --> 00:00:04,000\nBackwards\n")
        XCTAssertEqual(doc.cues[0].endMs, 5000)
        XCTAssertFalse(doc.warnings.isEmpty)
    }

    func testNoCuesThrows() {
        XCTAssertThrowsError(try SRTCodec.parse("just some text\nwithout timing")) { error in
            XCTAssertEqual(error as? SubtitleError, .noCues(.srt))
        }
    }

    func testRoundTripPreservesTextAndOrder() throws {
        let doc = try SRTCodec.parse(sample)
        let again = try SRTCodec.parse(SRTCodec.write(doc.cues))
        XCTAssertEqual(again.cues, doc.cues)
    }
}

final class WebVTTTests: XCTestCase {
    let sample = """
        WEBVTT - Example

        STYLE
        ::cue { color: yellow }

        NOTE a comment

        intro
        00:01.000 --> 00:03.000 align:start line:90%
        Hello <b>there</b>

        00:00:04.000 --> 00:00:06.500
        Karaoke <00:04.500>word <00:05.000>by word

        """

    func testParsesHeaderIdentifiersAndSettings() throws {
        let doc = try WebVTTCodec.parse(sample)
        XCTAssertEqual(doc.cues.count, 2)
        XCTAssertEqual(doc.cues[0].meta["identifier"], "intro")
        XCTAssertEqual(doc.cues[0].meta["settings"], "align:start line:90%")
        XCTAssertEqual(doc.cues[0].startMs, 1000)
        XCTAssertTrue(doc.header.contains("STYLE"))
        XCTAssertTrue(doc.header.hasPrefix("WEBVTT - Example"))
    }

    func testRejectsMissingSignature() {
        XCTAssertThrowsError(try WebVTTCodec.parse("00:01.000 --> 00:02.000\nHi")) { error in
            XCTAssertEqual(error as? SubtitleError, .notWebVTT)
        }
    }

    func testInlineTimestampsShiftWithOffset() throws {
        let doc = try WebVTTCodec.parse(sample)
        let written = WebVTTCodec.write(doc.cues, transform: TimingTransform(offsetMs: 1000), header: doc.header)
        XCTAssertTrue(written.contains("00:00:05.000 --> 00:00:07.500"))
        XCTAssertTrue(written.contains("<00:00:05.500>word <00:00:06.000>by word"))
        XCTAssertTrue(written.contains("STYLE"), "header blocks are preserved")
    }

    func testRoundTrip() throws {
        let doc = try WebVTTCodec.parse(sample)
        let again = try WebVTTCodec.parse(WebVTTCodec.write(doc.cues, header: doc.header))
        XCTAssertEqual(again.cues, doc.cues)
    }
}

final class ASSTests: XCTestCase {
    let sample = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
        Style: Sign,Arial,36,&H0000FFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,Hello, {\\i1}world{\\i0}!\\NSecond row
        Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,translator note
        Dialogue: 1,0:00:04.00,0:00:05.00,Sign,,0,0,0,,{\\pos(100,50)}EXIT

        [Fonts]
        fontname: custom.ttf
        """

    func testParsesEventsAndKeepsFields() throws {
        let doc = try ASSCodec.parse(sample)
        XCTAssertEqual(doc.cues.count, 3)
        XCTAssertEqual(doc.cues[0].text, "Hello, {\\i1}world{\\i0}!\\NSecond row", "commas in Text are preserved")
        XCTAssertEqual(doc.cues[0].startMs, 1000)
        XCTAssertEqual(doc.cues[0].endMs, 3500)
        XCTAssertEqual(doc.cues[2].meta["Style"], "Sign")
        XCTAssertEqual(doc.cues[1].meta["kind"], "Comment")
        XCTAssertTrue(doc.trailer.contains("[Fonts]"))
    }

    func testRoundTripPreservesStylingVerbatim() throws {
        let doc = try ASSCodec.parse(sample)
        let written = ASSCodec.write(document: doc, cues: doc.cues)
        XCTAssertTrue(written.contains("Style: Sign,Arial,36"))
        XCTAssertTrue(written.contains("Dialogue: 1,0:00:04.00,0:00:05.00,Sign,,0,0,0,,{\\pos(100,50)}EXIT"))
        XCTAssertTrue(written.contains("Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,translator note"))
        XCTAssertTrue(written.contains("[Fonts]\nfontname: custom.ttf"))
        XCTAssertEqual(try ASSCodec.parse(written).cues, doc.cues)
    }

    func testConversionToSRTStripsTagsWithWarning() throws {
        let doc = try ASSCodec.parse(sample)
        let prepared = SubtitleIO.prepare(doc, transform: .identity, target: .srt)
        XCTAssertEqual(prepared.cues.map(\.text), ["Hello, world!\nSecond row", "EXIT"])
        XCTAssertTrue(prepared.warnings.contains { $0.contains("styling") }, "styling loss is never silent")
        XCTAssertTrue(prepared.warnings.contains { $0.contains("comment") })
    }

    func testRejectsNonASS() {
        XCTAssertThrowsError(try ASSCodec.parse("[Events]\nDialogue: x"))
    }
}

final class DetectionAndEncodingTests: XCTestCase {
    func testDetectFormat() throws {
        XCTAssertEqual(try SubtitleIO.detectFormat("WEBVTT\n\n00:01.000 --> 00:02.000\nx"), .vtt)
        XCTAssertEqual(try SubtitleIO.detectFormat("[Script Info]\nTitle: x"), .ass)
        XCTAssertEqual(try SubtitleIO.detectFormat("1\n00:00:01,000 --> 00:00:02,000\nx"), .srt)
        XCTAssertThrowsError(try SubtitleIO.detectFormat("hello", filename: "notes.txt"))
    }

    func testDecodeUTF8WithBOM() throws {
        let decoded = try SubtitleIO.decode(Data([0xEF, 0xBB, 0xBF]) + Data("héllo".utf8))
        XCTAssertEqual(decoded.text, "héllo")
        XCTAssertTrue(decoded.hadBOM)
        XCTAssertFalse(decoded.guessed)
    }

    func testDecodeUTF16WithBOM() throws {
        let data = "Привет".data(using: .utf16)!  // Foundation writes a BOM
        let decoded = try SubtitleIO.decode(data)
        XCTAssertEqual(decoded.text, "Привет")
    }

    func testLegacyEncodingFallbackIsFlagged() throws {
        let data = "Café crème".data(using: .windowsCP1252)!
        let decoded = try SubtitleIO.decode(data)
        XCTAssertEqual(decoded.text, "Café crème")
        XCTAssertEqual(decoded.encoding, "windows-1252")
        XCTAssertTrue(decoded.guessed)
    }

    func testExplicitEncoding() throws {
        let data = "Привет".data(using: .windowsCP1251)!
        XCTAssertEqual(try SubtitleIO.decode(data, encoding: "windows-1251").text, "Привет")
    }

    func testLoadRejectsBinaryFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-binary-\(UUID()).srt")
        try Data([0x00, 0x01, 0x02, 0x41, 0x42, 0x00, 0xFF, 0x10] + Array(repeating: 0x41, count: 100)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SubtitleIO.load(url)) { XCTAssertEqual($0 as? SubtitleError, .binaryFile) }
    }
}
