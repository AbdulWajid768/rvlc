import Combine
import RVLCTestSupport
import XCTest

@testable import RVLCCore
@testable import RVLCEngine

/// Regression tests for engine defects found in pre-release review.
final class EngineRegressionTests: XCTestCase {
    var player: MPVPlayer!
    var media: Fixtures.Media!
    var bag = Set<AnyCancellable>()

    override func setUpWithError() throws {
        media = try Fixtures.media()
        player = try MPVPlayer(configuration: .init(headless: true))
    }

    override func tearDown() {
        bag.removeAll()
        player?.shutdown()
    }

    func testRapidLoadsOnlyReportTheLastFile() throws {
        var loaded: [URL] = []
        player.events.sink { if case .fileLoaded(let url) = $0 { loaded.append(url) } }.store(in: &bag)
        try player.open(media.video)
        try player.open(media.broken)
        try player.open(media.shortVideo)
        waitUntil("last file loaded") { player.currentURL == media.shortVideo && player.status == .playing }
        spin(0.5)
        XCTAssertEqual(loaded, [media.shortVideo], "superseded files never report as loaded")
        XCTAssertEqual(player.duration, 4, accuracy: 0.2, "metadata belongs to the file that is playing")
    }

    func testStaleErrorFromSupersededFileIsIgnored() throws {
        var failures = 0
        player.events.sink { if case .loadFailed = $0 { failures += 1 } }.store(in: &bag)
        try player.open(media.broken)
        try player.open(media.video)
        waitUntil("video playing") { player.status == .playing && player.currentURL == media.video }
        spin(0.4)
        XCTAssertEqual(player.status, .playing)
        XCTAssertEqual(failures, 0, "the broken file was replaced before it could fail")
    }

    func testStopLeavesErrorState() throws {
        try player.open(media.broken)
        waitUntil("error") {
            if case .error = player.status { return true }
            return false
        }
        player.stop()
        XCTAssertEqual(player.status, .idle, "Dismiss/Stop returns to the empty state")
    }

    func testStreamingSpeechActivityMatchesInMemoryAnalysis() throws {
        let streamed = try AudioExtractor().speechActivity(from: media.video)
        let samples = try AudioExtractor().extract(from: media.video)
        let inMemory = AutoSync.speechActivity(samples: samples, sampleRate: AudioExtractor.sampleRate)
        XCTAssertEqual(streamed, inMemory)
        XCTAssertEqual(Double(streamed.count) / 100, 8, accuracy: 0.2)
    }

    func testShutdownIsIdempotentAndCallsAfterwardsAreSafe() {
        player.shutdown()
        player.shutdown()
        player.setVolume(10)
        player.seek(3)
        XCTAssertNil(player.double("volume"))
        XCTAssertTrue(player.isTerminated)
    }

    func testPlayerReleasedWithoutExplicitShutdownDoesNotCrash() throws {
        var p: MPVPlayer? = try MPVPlayer(configuration: .init(headless: true))
        try p?.open(media.shortVideo)
        spin(0.3)
        p = nil
        spin(0.3)
    }
}

extension EngineRegressionTests {
    func testStopWhileLoadingReturnsToIdle() throws {
        try player.open(media.video)
        XCTAssertEqual(player.status, .loading)
        player.stop()
        XCTAssertEqual(player.status, .idle)
        spin(0.8)
        XCTAssertEqual(player.status, .idle, "no late event leaves the player stuck")
        try player.open(media.shortVideo)
        waitUntil("plays after stop") { player.status == .playing }
    }
}
