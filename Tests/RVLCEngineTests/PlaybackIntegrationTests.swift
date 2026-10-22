import Combine
import RVLCTestSupport
import XCTest

@testable import RVLCCore
@testable import RVLCEngine

/// Drives the real libmpv backend headlessly (null video/audio outputs).
final class PlaybackIntegrationTests: XCTestCase {
    var player: MPVPlayer!
    var media: Fixtures.Media!
    var bag = Set<AnyCancellable>()
    var events: [PlayerEvent] = []

    override func setUpWithError() throws {
        media = try Fixtures.media()
        player = try MPVPlayer(configuration: .init(headless: true))
        player.events.sink { [weak self] in self?.events.append($0) }.store(in: &bag)
    }

    override func tearDown() {
        bag.removeAll()
        player?.shutdown()
        player = nil
    }

    func openAndWait(_ url: URL, paused: Bool = false, audioDelayMs: Int = 0) {
        XCTAssertNoThrow(try player.open(url, audioDelayMs: audioDelayMs, paused: paused))
        waitUntil("file loaded") { player.status == (paused ? .paused : .playing) && player.duration > 0 }
    }

    func seekAndSettle(_ seconds: Double) {
        player.seek(seconds)
        waitUntil("seek to \(seconds)") { !player.isSeeking && abs(player.position - seconds) < 0.1 }
        spin(0.15)
    }

    // MARK: Basic playback

    func testOpenReportsDurationTracksAndPlays() {
        openAndWait(media.video)
        XCTAssertEqual(player.duration, 8, accuracy: 0.2)
        XCTAssertEqual(player.currentURL, media.video)
        XCTAssertTrue(events.contains(.fileLoaded(media.video)))
        XCTAssertEqual(player.tracks(.video).count, 1)
        XCTAssertEqual(player.tracks(.audio).count, 1)
        waitUntil("position advances") { player.position > 0.5 }
        XCTAssertEqual(player.videoSize, CGSize(width: 320, height: 240))
    }

    func testPauseResumeTransitions() {
        openAndWait(media.video)
        player.pause()
        waitUntil("paused") { player.status == .paused }
        let frozen = player.position
        spin(0.4)
        XCTAssertEqual(player.position, frozen, accuracy: 0.05, "position does not advance while paused")
        player.togglePause()
        waitUntil("playing") { player.status == .playing }
        waitUntil("advancing") { player.position > frozen + 0.2 }
    }

    func testSeekWhilePausedAndPlaying() {
        openAndWait(media.video, paused: true)
        seekAndSettle(4.2)
        XCTAssertEqual(player.status, .paused, "seeking does not resume playback")
        XCTAssertEqual(player.position, 4.2, accuracy: 0.1)
        player.play()
        waitUntil("playing") { player.status == .playing }
        player.seek(-2, mode: .relative)
        waitUntil("relative seek") { player.position < 3.5 && !player.isSeeking }
        XCTAssertEqual(player.status, .playing, "playback continues after seeking")
    }

    func testSeekIsClampedToDuration() {
        openAndWait(media.video, paused: true)
        player.seek(-30)
        waitUntil("clamped to start") { !player.isSeeking && player.position < 0.1 }
    }

    func testEndOfFileAndRestart() {
        openAndWait(media.video)
        player.seek(7.6)
        waitUntil("ended", timeout: 5) { player.status == .ended }
        XCTAssertTrue(events.contains(.endOfFile))
        player.play()
        waitUntil("restarted from beginning") { player.status == .playing && player.position < 2 }
    }

    func testBrokenFileReportsError() {
        XCTAssertNoThrow(try player.open(media.broken))
        waitUntil("error state") {
            if case .error = player.status { return true }
            return false
        }
        XCTAssertTrue(events.contains { if case .loadFailed = $0 { return true } else { return false } })
        // A valid file afterwards recovers from the error state.
        openAndWait(media.video)
    }

    func testMissingFileReportsError() {
        XCTAssertNoThrow(try player.open(media.dir.appendingPathComponent("does-not-exist.mkv")))
        waitUntil("error state") {
            if case .error = player.status { return true }
            return false
        }
    }

    func testStopReturnsToIdle() {
        openAndWait(media.video)
        player.stop()
        waitUntil("idle") { player.status == .idle }
        XCTAssertNil(player.currentURL)
        XCTAssertTrue(player.tracks.isEmpty)
    }

    func testVolumeMuteAndSpeed() {
        openAndWait(media.video)
        player.setVolume(35)
        player.setMuted(true)
        player.setSpeed(1.5)
        waitUntil("properties applied") { player.volume == 35 && player.isMuted && player.speed == 1.5 }
        player.setVolume(500)
        waitUntil("volume clamped") { player.volume == 100 }
        player.setSpeed(100)
        waitUntil("speed clamped") { player.speed == 4 }
    }

    // MARK: Subtitle timing through the real engine

    func testSubtitleDelayDirectionIsVerifiedByEngine() throws {
        openAndWait(media.video, paused: true)
        let id = try player.addSubtitle(media.subtitle)
        XCTAssertNotNil(id)
        waitUntil("track listed") { player.selectedTrack(.sub)?.isExternal == true }

        seekAndSettle(2.5)
        XCTAssertEqual(player.currentSubtitleText, "Alpha", "baseline: Alpha shown 2.0–3.0 s")

        // Positive offset = later: Alpha now spans 3.0–4.0 s.
        player.setSubtitleDelay(ms: 1000)
        waitUntil("delay applied") { player.subtitleDelayMs == 1000 }
        seekAndSettle(2.5)
        XCTAssertEqual(player.currentSubtitleText ?? "", "", "not yet visible with +1 s")
        seekAndSettle(3.5)
        XCTAssertEqual(player.currentSubtitleText, "Alpha")

        // Negative offset = earlier: Alpha spans 1.0–2.0 s.
        player.setSubtitleDelay(ms: -1000)
        waitUntil("delay applied") { player.subtitleDelayMs == -1000 }
        seekAndSettle(1.5)
        XCTAssertEqual(player.currentSubtitleText, "Alpha")
    }

    func testSubtitleAndAudioOffsetsAreIndependentAndStable() throws {
        openAndWait(media.video, paused: true)
        try player.addSubtitle(media.subtitle)
        player.setSubtitleDelay(ms: 400)
        waitUntil("sub delay") { player.subtitleDelayMs == 400 }
        XCTAssertEqual(player.audioDelayMs, 0, "changing subtitle delay leaves audio alone")

        player.setAudioDelay(ms: -250)
        waitUntil("audio delay") { player.audioDelayMs == -250 }
        XCTAssertEqual(player.subtitleDelayMs, 400, "changing audio delay leaves subtitles alone")

        // Seeking repeatedly must not accumulate or reapply offsets.
        for t in [1.0, 6.0, 3.0, 0.2] { seekAndSettle(t) }
        XCTAssertEqual(player.subtitleDelayMs, 400)
        XCTAssertEqual(player.audioDelayMs, -250)
        XCTAssertEqual(player.double("audio-delay") ?? .nan, -0.25, accuracy: 1e-9)

        // Reset behaviour.
        player.setAudioDelay(ms: 0)
        waitUntil("audio reset") { player.audioDelayMs == 0 }
        XCTAssertEqual(player.subtitleDelayMs, 400)
    }

    func testTrackSwitchingDoesNotAccumulateOffsets() throws {
        openAndWait(media.video)
        player.setAudioDelay(ms: 300)
        player.setSubtitleDelay(ms: -200)
        waitUntil("delays") { player.audioDelayMs == 300 && player.subtitleDelayMs == -200 }
        let embedded = try XCTUnwrap(player.selectedTrack(.audio)?.id)
        let external = try XCTUnwrap(try player.addAudio(media.externalAudio))
        waitUntil("external audio selected") { player.selectedTrack(.audio)?.id == external }
        XCTAssertTrue(player.selectedTrack(.audio)?.isExternal == true)
        player.selectTrack(.audio, id: embedded)
        waitUntil("embedded selected") { player.selectedTrack(.audio)?.id == embedded }
        player.selectTrack(.audio, id: external)
        waitUntil("external selected again") { player.selectedTrack(.audio)?.id == external }
        spin(0.3)
        XCTAssertEqual(player.audioDelayMs, 300)
        XCTAssertEqual(player.subtitleDelayMs, -200)
        player.removeTrack(.audio, id: external)
        waitUntil("external removed") { !player.tracks.contains { $0.id == external && $0.kind == .audio } }
    }

    func testPerFileDelaysDoNotLeakIntoNextFile() {
        openAndWait(media.video, audioDelayMs: 250)
        XCTAssertEqual(player.audioDelayMs, 250)
        openAndWait(media.shortVideo)
        waitUntil("delay reset for new file") { player.audioDelayMs == 0 }
    }

    func testReplacingExternalSubtitle() throws {
        openAndWait(media.video, paused: true)
        let first = try XCTUnwrap(try player.addSubtitle(media.subtitle))
        let second = try XCTUnwrap(try player.addSubtitle(media.earlySubtitle))
        player.removeTrack(.sub, id: first)
        waitUntil("one external subtitle left") { player.tracks(.sub).count == 1 }
        XCTAssertEqual(player.selectedTrack(.sub)?.id, second)
        player.selectTrack(.sub, id: nil)
        waitUntil("subtitles off") { player.selectedTrack(.sub) == nil }
    }

    func testAudioEffectsAreAcceptedByEngine() throws {
        openAndWait(media.video)
        for eq in AudioEffects.Equalizer.allCases {
            let effects = AudioEffects(normalize: true, equalizer: eq, limiter: true)
            XCTAssertNoThrow(try player.apply(effects), "filter chain for \(eq) rejected")
        }
        XCTAssertNoThrow(try player.apply(AudioEffects()))
        XCTAssertEqual(player.string("af"), "")
        var video = VideoAdjustments()
        video.brightness = 10
        video.aspect = .r4x3
        player.apply(video)
        XCTAssertEqual(player.double("brightness") ?? .nan, 10, accuracy: 1e-6)
        XCTAssertEqual(player.double("video-aspect-override") ?? .nan, 4.0 / 3.0, accuracy: 1e-4)
    }

    // MARK: Audio analysis and automatic sync

    func testAudioExtractionAndAutoSyncEndToEnd() throws {
        let samples = try AudioExtractor().extract(from: media.video)
        XCTAssertEqual(Double(samples.count) / Double(AudioExtractor.sampleRate), 8, accuracy: 0.2)
        let activity = AutoSync.speechActivity(samples: samples, sampleRate: AudioExtractor.sampleRate)
        XCTAssertTrue(activity[90], "burst at 0.9 s detected")
        XCTAssertFalse(activity[170], "silence at 1.7 s")

        let doc = try SubtitleIO.load(media.earlySubtitle)
        let result = try AutoSync.synchronize(
            samples: samples, sampleRate: AudioExtractor.sampleRate, cues: doc.cues,
            maxOffsetSeconds: 1.5, tryFrameRateRatios: false)
        XCTAssertEqual(result.transform.offsetMs, 600, accuracy: 60, "subtitles authored 0.6 s early must be delayed by ~0.6 s")
    }

    func testAudioExtractionRejectsBrokenFile() {
        XCTAssertThrowsError(try AudioExtractor().extract(from: media.broken))
    }
}
