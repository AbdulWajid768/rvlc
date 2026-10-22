import XCTest

@testable import RVLCCore

final class TimingTransformTests: XCTestCase {
    func testPositiveOffsetMakesSubtitlesLater() {
        let t = TimingTransform(offsetMs: 500)
        XCTAssertEqual(t.apply(1000), 1500)
    }

    func testNegativeOffsetMakesSubtitlesEarlier() {
        let t = TimingTransform(offsetMs: -250)
        XCTAssertEqual(t.apply(1000), 750)
    }

    func testScaleAndInverse() {
        let t = TimingTransform(scale: 25.0 / 23.976, offsetMs: 100)
        let shown = t.apply(3_600_000)
        XCTAssertEqual(t.invert(shown), 3_600_000, accuracy: 1)
        XCTAssertGreaterThan(t.driftSecondsPerHour, 150)
    }

    func testRepeatedAdjustmentsDoNotAccumulateIntoTimestamps() throws {
        let doc = try SRTCodec.parse("1\n00:00:10,000 --> 00:00:11,000\nLine\n")
        var transform = TimingTransform.identity
        // A user nudges +100 five times, then −100 twice: net +300 ms.
        for delta in [100, 100, 100, 100, 100, -100, -100] {
            transform = transform.withOffset(transform.offsetMs + delta)
        }
        XCTAssertEqual(transform.offsetMs, 300)
        XCTAssertEqual(doc.cues[0].startMs, 10_000, "original timestamps are never modified")
        let rendered = try SubtitleIO.render(doc, transform: transform).text
        XCTAssertTrue(rendered.contains("00:00:10,300 --> 00:00:11,300"))
        // Rendering again with the same transform is idempotent.
        XCTAssertEqual(try SubtitleIO.render(doc, transform: transform).text, rendered)
    }

    func testFormatOffset() {
        XCTAssertEqual(formatOffset(1250), "+1.250 s")
        XCTAssertEqual(formatOffset(-100), "−0.100 s")
        XCTAssertEqual(formatOffset(0), "+0.000 s")
    }

    func testCueLookup() throws {
        let doc = try SRTCodec.parse("1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:05,000 --> 00:00:06,000\nB\n")
        XCTAssertEqual(doc.cueIndex(at: 1500), 0)
        XCTAssertNil(doc.cueIndex(at: 3000))
        XCTAssertEqual(doc.cueIndex(at: 2500, transform: TimingTransform(offsetMs: 1000)), 0)
        XCTAssertEqual(doc.nearestCueIndex(to: 4200), 1)
    }
}

final class ExportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func writeSource(_ text: String, name: String = "movie.srt") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testExportAppliesOffsetAccuratelyAndPreservesSource() throws {
        let original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,250 --> 00:00:04,750\nTwo\n"
        let source = try writeSource(original)
        let doc = try SubtitleIO.load(source)
        let dest = SubtitleIO.suggestedExportURL(for: source, format: .srt)
        XCTAssertEqual(dest.lastPathComponent, "movie.synced.srt")
        let report = try SubtitleIO.export(doc, to: dest, transform: TimingTransform(offsetMs: -750), format: .srt)
        XCTAssertEqual(report.cueCount, 2)
        let exported = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(exported.contains("00:00:00,250 --> 00:00:01,250"))
        XCTAssertTrue(exported.contains("00:00:02,500 --> 00:00:04,000"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original, "source file is unchanged")
    }

    func testExportRefusesToOverwriteSource() throws {
        let source = try writeSource("1\n00:00:01,000 --> 00:00:02,000\nOne\n")
        let doc = try SubtitleIO.load(source)
        XCTAssertThrowsError(try SubtitleIO.export(doc, to: source, transform: .identity, format: .srt)) {
            XCTAssertEqual($0 as? SubtitleError, .refusingToOverwriteSource)
        }
    }

    func testNegativeTimesAreClampedOrDroppedWithWarnings() throws {
        let doc = try SRTCodec.parse(
            "1\n00:00:00,500 --> 00:00:01,000\nGone\n\n2\n00:00:01,500 --> 00:00:03,000\nClamped\n\n3\n00:00:05,000 --> 00:00:06,000\nKept\n"
        )
        let prepared = SubtitleIO.prepare(doc, transform: TimingTransform(offsetMs: -2000), target: .srt)
        XCTAssertEqual(prepared.cues.map(\.text), ["Clamped", "Kept"])
        XCTAssertEqual(prepared.cues[0].startMs, 0)
        XCTAssertEqual(prepared.cues[0].endMs, 1000)
        XCTAssertEqual(prepared.warnings.count, 2)
    }

    func testExportSortsCuesAndConvertsToVTT() throws {
        var doc = try SRTCodec.parse("1\n00:00:05,000 --> 00:00:06,000\nLater\n\n2\n00:00:01,000 --> 00:00:02,000\nEarlier\n")
        doc.sourceURL = nil
        let dest = dir.appendingPathComponent("out.vtt")
        try SubtitleIO.export(doc, to: dest, transform: .identity, format: .vtt)
        let parsed = try WebVTTCodec.parse(String(contentsOf: dest, encoding: .utf8))
        XCTAssertEqual(parsed.cues.map(\.text), ["Earlier", "Later"])
    }

    func testExportWithLegacyEncodingFallsBackWhenNeeded() throws {
        let doc = try SRTCodec.parse("1\n00:00:01,000 --> 00:00:02,000\n日本語\n")
        let dest = dir.appendingPathComponent("out.srt")
        let report = try SubtitleIO.export(doc, to: dest, transform: .identity, format: .srt, encoding: "windows-1252")
        XCTAssertEqual(report.encoding, "utf-8")
        XCTAssertFalse(report.warnings.isEmpty)
        XCTAssertTrue(try String(contentsOf: dest, encoding: .utf8).contains("日本語"))
    }

    func testDriftCorrectedExport() throws {
        let doc = try SRTCodec.parse("1\n01:00:00,000 --> 01:00:01,000\nOne hour\n")
        let t = TimingTransform(scale: 1.001, offsetMs: 0)
        let prepared = SubtitleIO.prepare(doc, transform: t, target: .srt)
        XCTAssertEqual(prepared.cues[0].startMs, 3_603_600)
    }
}

final class SyncFitTests: XCTestCase {
    func testSinglePointGivesConstantOffset() throws {
        let s = try XCTUnwrap(SyncFit.fit([SyncPoint(subtitleMs: 10_000, mediaMs: 12_500)]))
        XCTAssertEqual(s.transform, TimingTransform(offsetMs: 2500))
        XCTAssertEqual(s.method, .offset)
        XCTAssertTrue(s.summary.contains("2.500 s later"))
    }

    func testSubtitlesTooLateGiveNegativeOffset() throws {
        let s = try XCTUnwrap(SyncFit.fit([SyncPoint(subtitleMs: 10_000, mediaMs: 9_000)]))
        XCTAssertEqual(s.transform.offsetMs, -1000)
        XCTAssertTrue(s.summary.contains("earlier"))
    }

    func testConsistentPointsStayConstant() throws {
        let points = [SyncPoint(subtitleMs: 60_000, mediaMs: 61_020), SyncPoint(subtitleMs: 3_000_000, mediaMs: 3_000_980)]
        let s = try XCTUnwrap(SyncFit.fit(points))
        XCTAssertEqual(s.method, .offset, "small differences do not justify a drift model")
        XCTAssertEqual(s.transform.offsetMs, 1000)
    }

    func testDetectsFrameRateDrift() throws {
        let ratio = 25.0 / (24000.0 / 1001.0)
        let truth = TimingTransform(scale: ratio, offsetMs: 1500)
        let points = [120_000, 1_800_000, 4_000_000].map { SyncPoint(subtitleMs: $0, mediaMs: truth.apply($0)) }
        let s = try XCTUnwrap(SyncFit.fit(points))
        XCTAssertEqual(s.method, .linear)
        XCTAssertEqual(s.ratioName, "23.976 → 25 fps")
        XCTAssertEqual(s.transform.offsetMs, 1500, accuracy: 2)
        XCTAssertLessThan(s.rmsErrorMs, 5)
    }

    func testCloseTogetherPointsDoNotFitDrift() throws {
        let points = [SyncPoint(subtitleMs: 10_000, mediaMs: 11_000), SyncPoint(subtitleMs: 20_000, mediaMs: 21_500)]
        let s = try XCTUnwrap(SyncFit.fit(points))
        XCTAssertEqual(s.method, .offset)
        XCTAssertFalse(s.notes.isEmpty)
    }

    func testImplausibleScaleIsRejected() throws {
        let points = [SyncPoint(subtitleMs: 100_000, mediaMs: 100_000), SyncPoint(subtitleMs: 200_000, mediaMs: 400_000)]
        let s = try XCTUnwrap(SyncFit.fit(points))
        XCTAssertEqual(s.method, .offset)
        XCTAssertTrue(s.notes.contains { $0.contains("inconsistent") })
    }

    func testNoPoints() {
        XCTAssertNil(SyncFit.fit([]))
    }
}

final class AutoSyncTests: XCTestCase {
    /// Synthetic "speech": 440 Hz bursts at the given intervals over low noise.
    func makeAudio(bursts: [(Double, Double)], duration: Double, rate: Int = 16_000) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var samples = [Float](repeating: 0, count: Int(duration * Double(rate)))
        for i in samples.indices {
            samples[i] = Float.random(in: -0.003...0.003, using: &generator)
        }
        for (start, end) in bursts {
            for i in Int(start * Double(rate))..<min(samples.count, Int(end * Double(rate))) {
                samples[i] += 0.4 * sin(2 * .pi * 440 * Float(i) / Float(rate))
            }
        }
        return samples
    }

    func bursts(count: Int, seed: UInt64) -> [(Double, Double)] {
        // Deterministic irregular pattern (a linear congruential sequence).
        var state = seed
        var t = 2.0
        var result: [(Double, Double)] = []
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let len = 0.8 + Double(state % 1000) / 1000 * 2.2
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let gap = 0.5 + Double(state % 1000) / 1000 * 2.5
            result.append((t, t + len))
            t += len + gap
        }
        return result
    }

    func testRecoversConstantOffset() throws {
        let speech = bursts(count: 25, seed: 42)
        let audio = makeAudio(bursts: speech, duration: speech.last!.1 + 10)
        // Subtitles were authored 2.3 s too early.
        let cues = speech.map { Cue(startMs: Int(($0.0 - 2.3) * 1000), endMs: Int(($0.1 - 2.3) * 1000), text: "x") }
        let result = try AutoSync.synchronize(
            samples: audio, sampleRate: 16_000, cues: cues, maxOffsetSeconds: 20, tryFrameRateRatios: false)
        XCTAssertEqual(result.transform.offsetMs, 2300, accuracy: 40)
        XCTAssertEqual(result.transform.scale, 1)
        XCTAssertGreaterThan(result.agreement, 0.9)
        XCTAssertEqual(result.confidence, .high)
    }

    func testRecoversNegativeOffset() throws {
        let speech = bursts(count: 25, seed: 7)
        let audio = makeAudio(bursts: speech, duration: speech.last!.1 + 10)
        let cues = speech.map { Cue(startMs: Int(($0.0 + 1.75) * 1000), endMs: Int(($0.1 + 1.75) * 1000), text: "x") }
        let result = try AutoSync.synchronize(
            samples: audio, sampleRate: 16_000, cues: cues, maxOffsetSeconds: 20, tryFrameRateRatios: false)
        XCTAssertEqual(result.transform.offsetMs, -1750, accuracy: 40)
    }

    func testUnrelatedSubtitlesGetLowConfidence() throws {
        let speech = bursts(count: 25, seed: 11)
        let audio = makeAudio(bursts: speech, duration: speech.last!.1 + 10)
        // Regularly spaced lines that do not follow the speech pattern.
        let cues = (0..<25).map { Cue(startMs: 2000 + $0 * 3000, endMs: 3500 + $0 * 3000, text: "x") }
        let result = try AutoSync.synchronize(
            samples: audio, sampleRate: 16_000, cues: cues, maxOffsetSeconds: 20, tryFrameRateRatios: false)
        XCTAssertNotEqual(result.confidence, .high)
    }

    func testRecoversFrameRateDrift() throws {
        let speech = bursts(count: 60, seed: 3)
        let audio = makeAudio(bursts: speech, duration: speech.last!.1 + 5)
        let ratio = 25.0 / (24000.0 / 1001.0)
        // Subtitles timed for 23.976 fps played back at 25 fps: media = ratio * sub + 0.5 s
        let cues = speech.map { Cue(startMs: Int((($0.0 - 0.5) / ratio) * 1000), endMs: Int((($0.1 - 0.5) / ratio) * 1000), text: "x") }
        let result = try AutoSync.synchronize(samples: audio, sampleRate: 16_000, cues: cues, maxOffsetSeconds: 20)
        XCTAssertEqual(result.transform.scale, ratio, accuracy: 1e-9)
        XCTAssertEqual(result.transform.offsetMs, 500, accuracy: 40)
    }

    func testSilenceIsReported() {
        let audio = [Float](repeating: 0, count: 16_000 * 5)
        XCTAssertThrowsError(
            try AutoSync.synchronize(
                samples: audio, sampleRate: 16_000,
                cues: [Cue(startMs: 0, endMs: 1000, text: "x")])
        ) {
            XCTAssertEqual($0 as? AutoSync.Failure, .noSpeech)
        }
    }

    func testSpeechActivityDetectsBursts() {
        let audio = makeAudio(bursts: [(1, 2), (3, 4)], duration: 5)
        let activity = AutoSync.speechActivity(samples: audio, sampleRate: 16_000)
        XCTAssertEqual(activity.count, 500)
        XCTAssertTrue(activity[150])
        XCTAssertFalse(activity[250])
        XCTAssertTrue(activity[350])
    }
}

final class EditingTests: XCTestCase {
    func testSearchAndReplace() throws {
        var doc = try SRTCodec.parse(
            "1\n00:00:01,000 --> 00:00:02,000\nColor of the colour\n\n2\n00:00:03,000 --> 00:00:04,000\nNo match\n")
        XCTAssertEqual(try SubtitleEditing.find("colour", in: doc), [0])
        XCTAssertEqual(try SubtitleEditing.find("COLOR", in: doc, options: .init(caseSensitive: true)), [])
        let count = try SubtitleEditing.replaceAll("colou?r", with: "hue", in: &doc, options: .init(regularExpression: true))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(doc.cues[0].text, "hue of the hue")
    }

    func testLiteralReplacementEscapesTemplates() throws {
        var doc = try SRTCodec.parse("1\n00:00:01,000 --> 00:00:02,000\nPrice\n")
        try SubtitleEditing.replaceAll("Price", with: "$1 cost", in: &doc)
        XCTAssertEqual(doc.cues[0].text, "$1 cost")
    }

    func testShiftAndSetTimes() throws {
        var doc = try SRTCodec.parse("1\n00:00:01,000 --> 00:00:02,000\nA\n")
        SubtitleEditing.shift(cue: 0, by: -5000, in: &doc)
        XCTAssertEqual(doc.cues[0].startMs, 0, "never before 0:00")
        XCTAssertEqual(doc.cues[0].durationMs, 1000, "duration preserved")
        XCTAssertThrowsError(try SubtitleEditing.setTimes(cue: 0, startMs: 500, endMs: 100, in: &doc))
        try SubtitleEditing.setTimes(cue: 0, startMs: 100, endMs: 900, in: &doc)
        XCTAssertEqual(doc.cues[0], Cue(startMs: 100, endMs: 900, text: "A"))
    }
}
