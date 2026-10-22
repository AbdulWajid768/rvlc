import XCTest

@testable import RVLCCore

/// Regression tests for defects found in pre-release review.
final class RegressionTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-regress-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDriftSnapsToClosestRatio() throws {
        // True drift 24 → 25 fps must not be snapped to the nearby 23.976 → 25 ratio.
        let truth = TimingTransform(scale: 25.0 / 24.0, offsetMs: 300)
        let points = [60_000, 1_800_000, 3_600_000, 7_000_000].map { SyncPoint(subtitleMs: $0, mediaMs: truth.apply($0)) }
        let s = try XCTUnwrap(SyncFit.fit(points))
        XCTAssertEqual(s.ratioName, "24 → 25 fps")
        XCTAssertLessThan(s.rmsErrorMs, 5)
        let back = TimingTransform(scale: 24.0 / 25.0, offsetMs: 0)
        let s2 = try XCTUnwrap(SyncFit.fit([60_000, 3_600_000, 7_000_000].map { SyncPoint(subtitleMs: $0, mediaMs: back.apply($0)) }))
        XCTAssertEqual(s2.ratioName, "25 → 24 fps")
    }

    func testEditorTimeRejectsHugeOrExoticInput() {
        for bad in ["1e20", "999999999999999:00:00", "9000000000000000000:0:0", "-5", "inf", "nan", "1:2:3:4", "12..5", "1000:00:00"] {
            XCTAssertThrowsError(try Timecode.parseEditor(bad), bad)
        }
        XCTAssertEqual(try Timecode.parseEditor("998:59:59.999"), 998 * 3_600_000 + 3_599_999)
    }

    func testUTF16WithoutBOMIsDecoded() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        let data = text.data(using: .utf16LittleEndian)!
        let decoded = try SubtitleIO.decode(data)
        XCTAssertEqual(decoded.text, text)
        let url = dir.appendingPathComponent("le.srt")
        try data.write(to: url)
        XCTAssertEqual(try SubtitleIO.load(url).cues.first?.text, "Hello")
    }

    func testSymlinkToDeviceOrHugeFileIsRejected() throws {
        let link = dir.appendingPathComponent("movie.srt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
        XCTAssertThrowsError(try SubtitleIO.load(link))
        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(SubtitleIO.maxBytes + 10))
        try handle.close()
        let link2 = dir.appendingPathComponent("big.srt")
        try FileManager.default.createSymbolicLink(atPath: link2.path, withDestinationPath: big.path)
        XCTAssertThrowsError(try SubtitleIO.load(link2)) {
            XCTAssertEqual($0 as? SubtitleError, .tooLarge(bytes: SubtitleIO.maxBytes + 10))
        }
    }

    func testVTTExportShiftsKaraokeTimestamps() throws {
        let doc = try WebVTTCodec.parse("WEBVTT\n\n00:01.000 --> 00:03.000\nA <00:02.000>B\n")
        let (text, _) = try SubtitleIO.render(doc, transform: TimingTransform(offsetMs: 5000))
        XCTAssertTrue(text.contains("00:00:06.000 --> 00:00:08.000"))
        XCTAssertTrue(text.contains("<00:00:07.000>B"), text)
        let (srt, _) = try SubtitleIO.render(doc, transform: .identity, target: .srt)
        XCTAssertFalse(srt.contains("<00:"), "karaoke tags are removed for SRT")
    }

    func testExportRefusesSourceUnderDifferentCase() throws {
        let source = dir.appendingPathComponent("movie.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nA\n".utf8).write(to: source)
        let doc = try SubtitleIO.load(source)
        let variant = dir.appendingPathComponent("MOVIE.SRT")
        guard FileManager.default.fileExists(atPath: variant.path) else { throw XCTSkip("case-sensitive file system") }
        XCTAssertThrowsError(try SubtitleIO.export(doc, to: variant, transform: TimingTransform(offsetMs: 1), format: .srt))
        let hardLink = dir.appendingPathComponent("link.srt")
        try FileManager.default.linkItem(at: source, to: hardLink)
        XCTAssertThrowsError(try SubtitleIO.export(doc, to: hardLink, transform: TimingTransform(offsetMs: 1), format: .srt))
    }

    func testSRTDialogueContainingArrowStaysInCue() throws {
        let doc = try SRTCodec.parse("1\n00:00:01,000 --> 00:00:02,000\nMe --> You\nsecond line\n\n2\n00:00:03,000 --> 00:00:04,000\nB\n")
        XCTAssertEqual(doc.cues.map(\.text), ["Me --> You\nsecond line", "B"])
        XCTAssertTrue(doc.warnings.isEmpty)
        let written = SRTCodec.write(doc.cues)
        XCTAssertFalse(written.contains("Me -->"), "arrow is escaped on write")
        XCTAssertEqual(try SRTCodec.parse(written).cues.count, 2)
    }

    func testASSFieldNamesAreCaseInsensitive() throws {
        let text =
            "[Script Info]\nTitle: x\n\n[Events]\nformat: layer, start, end, style, name, marginl, marginr, marginv, effect, text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi, there\n"
        let doc = try ASSCodec.parse(text)
        XCTAssertEqual(doc.cues.first?.startMs, 1000)
        XCTAssertEqual(doc.cues.first?.text, "Hi, there")
        let out = ASSCodec.write(document: doc, cues: doc.cues, transform: TimingTransform(offsetMs: 500))
        XCTAssertTrue(out.contains("Dialogue: 0,0:00:01.50,0:00:02.50,Default,,0,0,0,,Hi, there"), out)
    }

    func testPlusKeyBindingsRoundTrip() {
        for combo in [KeyCombo("+"), KeyCombo("+", [.shift]), KeyCombo("+", [.command, .option])] {
            XCTAssertEqual(KeyCombo(string: combo.storageString), combo, combo.storageString)
        }
    }

    func testLargeOffsetOnShortMediaIsFound() throws {
        // 3-minute clip with subtitles 40 s early: the overlap-normalised score must still find +40 s.
        var state: UInt64 = 99
        var t = 1.0
        var speech: [(Double, Double)] = []
        while t < 175 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let len = 0.8 + Double(state % 1000) / 1000 * 2
            speech.append((t, t + len))
            t += len + 0.6 + Double((state >> 20) % 1000) / 1000 * 2
        }
        var activity = [Bool](repeating: false, count: 18_000)
        for (s, e) in speech { for k in Int(s * 100)..<min(18_000, Int(e * 100)) { activity[k] = true } }
        let cues = speech.map { Cue(startMs: Int(($0.0 - 40) * 1000), endMs: Int(($0.1 - 40) * 1000), text: "x") }.filter { $0.endMs > 0 }
        let result = try AutoSync.synchronize(activity: activity, cues: cues, maxOffsetSeconds: 60, tryFrameRateRatios: false)
        XCTAssertEqual(result.transform.offsetMs, 40_000, accuracy: 30)
    }

    func testSpeechDetectorChunkingMatchesSingleBuffer() {
        var gen = SystemRandomNumberGenerator()
        var samples = (0..<(22_050 * 4)).map { _ in Float.random(in: -0.002...0.002, using: &gen) }
        for i in 22_050..<44_100 { samples[i] += 0.4 * sin(2 * .pi * 440 * Float(i) / 22_050) }
        let whole = AutoSync.speechActivity(samples: samples, sampleRate: 22_050)
        var detector = AutoSync.SpeechDetector(sampleRate: 22_050)
        var i = 0
        while i < samples.count {
            detector.consume(Array(samples[i..<min(samples.count, i + 7_919)]))
            i += 7_919
        }
        XCTAssertEqual(detector.activity(), whole)
        XCTAssertEqual(whole.count, 400, "exactly 100 frames per second at 22.05 kHz")
        XCTAssertTrue(whole[150])
        XCTAssertFalse(whole[300])
    }
}

/// Second review round.
final class RegressionTests2: XCTestCase {
    func testSpeechDetectorFilterStateCarriesAcrossChunks() {
        var gen = SystemRandomNumberGenerator()
        let samples = (0..<(16_000 * 3)).map { i in
            0.3 * sin(2 * .pi * 700 * Float(i) / 16_000) + Float.random(in: -0.01...0.01, using: &gen)
        }
        var whole = AutoSync.SpeechDetector(sampleRate: 16_000)
        whole.consume(samples)
        var chunked = AutoSync.SpeechDetector(sampleRate: 16_000)
        var i = 0
        while i < samples.count {
            chunked.consume(Array(samples[i..<min(samples.count, i + 1_000)]))
            i += 1_000
        }
        XCTAssertEqual(chunked.frameEnergies.count, whole.frameEnergies.count)
        let maxDiff = zip(chunked.frameEnergies, whole.frameEnergies).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 0.01, "no filter transient at chunk boundaries")
    }

    func testUTF16BigEndianWithoutBOM() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        let decoded = try SubtitleIO.decode(text.data(using: .utf16BigEndian)!)
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.encoding, "utf-16be")
    }

    func testNoRunnerUpIsNotHighConfidence() throws {
        var activity = [Bool](repeating: false, count: 150)
        for k in 40..<90 { activity[k] = true }
        let cues = [Cue(startMs: 400, endMs: 900, text: "x")]
        let result = try AutoSync.synchronize(activity: activity, cues: cues, maxOffsetSeconds: 0.5, tryFrameRateRatios: false)
        XCTAssertNotEqual(result.confidence, .high, "a single possible alignment is not evidence")
    }

    func testDamagedPlaylistKeepsRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-pl-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("library.json")
        let json = """
            {"version":1,"playlist":{"items":42},
             "records":[{"path":"/a","title":"A","addedAt":"2026-01-01T00:00:00Z","playCount":1,"favorite":true,"audioDelayMs":5,"subtitleOffsetMs":0}]}
            """
        try Data(json.utf8).write(to: store)
        let lib = MediaLibrary(storeURL: store)
        XCTAssertEqual(lib.record(for: "/a")?.audioDelayMs, 5)
        XCTAssertTrue(lib.playlist.isEmpty)
    }

    func testPositionUpdatesDoNotSignalListChanges() {
        let lib = MediaLibrary(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-\(UUID()).json"))
        var listChanges = 0
        lib.onListsChange = { listChanges += 1 }
        lib.updatePosition("/a", position: 12, duration: 60)
        XCTAssertEqual(listChanges, 0)
        lib.markOpened("/a")
        lib.setFavorite("/a", true)
        XCTAssertEqual(listChanges, 2)
    }
}

final class GoToTimeParsingTests: XCTestCase {
    func testAcceptedForms() throws {
        XCTAssertEqual(try Timecode.parseGoTo("83", duration: 600), 83)
        XCTAssertEqual(try Timecode.parseGoTo("83.5", duration: 600), 83.5)
        XCTAssertEqual(try Timecode.parseGoTo("1:23", duration: 600), 83)
        XCTAssertEqual(try Timecode.parseGoTo(" 0:01:23.250 ", duration: 600), 83.25)
        XCTAssertEqual(try Timecode.parseGoTo("1:02:03", duration: nil), 3723)
    }

    func testRejectedInput() {
        XCTAssertThrowsError(try Timecode.parseGoTo("abc", duration: 600)) {
            XCTAssertEqual($0 as? Timecode.GoToTimeError, .invalid("abc"))
        }
        XCTAssertThrowsError(try Timecode.parseGoTo("1:75", duration: 600))
        XCTAssertThrowsError(try Timecode.parseGoTo("-5", duration: 600))
        XCTAssertThrowsError(try Timecode.parseGoTo("10:01", duration: 600)) {
            XCTAssertEqual($0 as? Timecode.GoToTimeError, .beyondEnd(duration: 600))
        }
        XCTAssertEqual(try Timecode.parseGoTo("10:00", duration: 600), 600, "the very end is allowed")
    }
}
