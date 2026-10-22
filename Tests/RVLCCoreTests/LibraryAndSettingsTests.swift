import XCTest

@testable import RVLCCore

final class KeyMapTests: XCTestCase {
    func testDefaultsAreConflictFree() {
        let map = KeyMap()
        var seen: [KeyCombo: PlayerAction] = [:]
        for action in PlayerAction.allCases {
            for combo in map.combos(for: action) {
                XCTAssertNil(seen[combo], "\(combo) bound to both \(seen[combo]!) and \(action)")
                seen[combo] = action
            }
        }
    }

    func testSubtitleAndAudioShortcutsAreIndependent() {
        let map = KeyMap()
        XCTAssertEqual(map.action(for: KeyCombo("z")), .subtitleEarlier)
        XCTAssertEqual(map.action(for: KeyCombo("x")), .subtitleLater)
        XCTAssertEqual(map.action(for: KeyCombo("c")), .audioEarlier)
        XCTAssertEqual(map.action(for: KeyCombo("v")), .audioLater)
        XCTAssertEqual(map.action(for: KeyCombo("space")), .playPause)
        XCTAssertEqual(map.action(for: KeyCombo("left", [.shift])), .seekBackwardSmall)
        XCTAssertNil(map.action(for: KeyCombo("q")))
    }

    func testParsingAndDisplay() {
        XCTAssertEqual(KeyCombo(string: "shift+left"), KeyCombo("left", [.shift]))
        XCTAssertEqual(KeyCombo(string: "cmd+alt+O"), KeyCombo("o", [.command, .option]))
        XCTAssertNil(KeyCombo(string: "hyper+x"))
        XCTAssertEqual(KeyCombo("left", [.shift]).description, "⇧←")
        XCTAssertEqual(KeyCombo("o", [.command, .shift]).storageString, "shift+cmd+o")
        XCTAssertEqual(KeyCombo(string: KeyCombo("o", [.command, .shift]).storageString), KeyCombo("o", [.command, .shift]))
    }

    func testOverridesRoundTrip() {
        var map = KeyMap()
        map.set([KeyCombo("k")], for: .playPause)
        XCTAssertEqual(map.overrides, ["playPause": ["k"]])
        let restored = KeyMap(overrides: map.overrides)
        XCTAssertEqual(restored.action(for: KeyCombo("k")), .playPause)
        XCTAssertNil(restored.action(for: KeyCombo("space")))
        XCTAssertEqual(restored.conflicts(for: KeyCombo("z"), excluding: .playPause), [.subtitleEarlier])
    }
}

final class PreferencesTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var prefs: Preferences!

    override func setUp() {
        suiteName = "rvlc-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        prefs = Preferences(defaults: defaults, notificationCenter: NotificationCenter())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        XCTAssertEqual(prefs.theme, .system)
        XCTAssertEqual(prefs.volume, 80)
        XCTAssertTrue(prefs.hardwareDecoding)
        XCTAssertEqual(prefs.subtitleStepMs, 100)
        XCTAssertEqual(prefs.keyMap, KeyMap())
    }

    func testPersistsAcrossInstances() {
        prefs.theme = .dark
        prefs.subtitleStepMs = 250
        prefs.audioStepMs = 500
        var map = prefs.keyMap
        map.set([KeyCombo("k")], for: .playPause)
        prefs.keyMap = map
        let again = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(again.theme, .dark)
        XCTAssertEqual(again.subtitleStepMs, 250)
        XCTAssertEqual(again.audioStepMs, 500)
        XCTAssertEqual(again.keyMap.action(for: KeyCombo("k")), .playPause)
    }

    func testValidationClampsValues() {
        prefs.volume = 500
        XCTAssertEqual(prefs.volume, 100, "no amplification unless enabled")
        prefs.allowAmplification = true
        prefs.volume = 500
        XCTAssertEqual(prefs.volume, 200)
        prefs.allowAmplification = false
        XCTAssertEqual(prefs.volume, 100, "disabling amplification lowers the volume")
        defaults.set(333, forKey: "subtitleStepMs")
        XCTAssertEqual(prefs.subtitleStepMs, 100, "unsupported step falls back to the default")
        prefs.subtitleFontSize = 5
        XCTAssertEqual(prefs.subtitleFontSize, 16)
    }

    func testChangeNotification() {
        let center = NotificationCenter()
        let p = Preferences(defaults: defaults, notificationCenter: center)
        let exp = expectation(forNotification: .rvlcPreferencesDidChange, object: p, notificationCenter: center) { note in
            note.userInfo?["key"] as? String == "theme"
        }
        p.theme = .light
        wait(for: [exp], timeout: 1)
    }
}

final class PlaylistTests: XCTestCase {
    func testAppendSkipsDuplicates() {
        var p = Playlist()
        XCTAssertEqual(p.append(["/a", "/b"]), 0)
        XCTAssertEqual(p.append(["/b", "/c"]), 1)
        XCTAssertEqual(p.items, ["/a", "/b", "/c"])
    }

    func testMoveAndRemoveKeepCurrentItem() {
        var p = Playlist(items: ["/a", "/b", "/c", "/d"], currentIndex: 1)
        p.move(from: 1, to: 4)
        XCTAssertEqual(p.items, ["/a", "/c", "/d", "/b"])
        XCTAssertEqual(p.current, "/b")
        p.remove(at: IndexSet([0, 1]))
        XCTAssertEqual(p.items, ["/d", "/b"])
        XCTAssertEqual(p.current, "/b")
        p.remove(at: IndexSet([1]))
        XCTAssertNil(p.currentIndex)
    }

    func testNextPreviousAndRepeat() {
        var p = Playlist(items: ["/a", "/b"], currentIndex: 1)
        XCTAssertNil(p.nextIndex())
        p.repeatMode = .all
        XCTAssertEqual(p.nextIndex(), 0)
        p.repeatMode = .one
        XCTAssertEqual(p.nextIndex(afterEnd: true), 1)
        XCTAssertNil(p.nextIndex(), "manual Next ignores repeat-one and stops at the end")
        p.currentIndex = 0
        p.repeatMode = .off
        XCTAssertNil(p.previousIndex())
        XCTAssertEqual(p.nextIndex(), 1)
    }
}

final class MediaLibraryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-lib-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPersistenceAndResume() throws {
        let store = dir.appendingPathComponent("library.json")
        let lib = MediaLibrary(storeURL: store)
        lib.markOpened("/movies/a.mkv")
        lib.updateMetadata("/movies/a.mkv", title: "A Movie", duration: 600, width: 1920, height: 1080)
        lib.updatePosition("/movies/a.mkv", position: 120, duration: 600)
        lib.setAudioDelay("/movies/a.mkv", ms: -150)
        lib.setFavorite("/movies/a.mkv", true)
        lib.playlist.append(["/movies/a.mkv", "/movies/b.mkv"])
        try lib.save()

        let reloaded = MediaLibrary(storeURL: store)
        let record = try XCTUnwrap(reloaded.record(for: "/movies/a.mkv"))
        XCTAssertEqual(record.title, "A Movie")
        XCTAssertEqual(record.resolutionText, "1920×1080")
        XCTAssertEqual(record.audioDelayMs, -150)
        XCTAssertTrue(record.favorite)
        XCTAssertEqual(reloaded.resumePosition(for: "/movies/a.mkv"), 120)
        XCTAssertEqual(reloaded.playlist.items.count, 2)
    }

    func testNoResumeNearStartOrEnd() {
        let lib = MediaLibrary(storeURL: dir.appendingPathComponent("l.json"))
        lib.updatePosition("/x", position: 5, duration: 600)
        XCTAssertNil(lib.resumePosition(for: "/x"))
        lib.updatePosition("/x", position: 590, duration: 600)
        XCTAssertNil(lib.record(for: "/x")?.position, "finished files start over")
    }

    func testRecentFavoritesSearchAndSort() {
        let lib = MediaLibrary(storeURL: dir.appendingPathComponent("l.json"))
        lib.markOpened("/m/Zeta.mkv", at: Date(timeIntervalSince1970: 100))
        lib.markOpened("/m/alpha.mp4", at: Date(timeIntervalSince1970: 200))
        lib.updateMetadata("/m/Zeta.mkv", title: nil, duration: 50, width: nil, height: nil)
        XCTAssertEqual(lib.recent().map(\.title), ["alpha", "Zeta"])
        XCTAssertEqual(lib.search("", in: lib.recent(), sort: .title).map(\.title), ["alpha", "Zeta"])
        XCTAssertEqual(lib.search("zet", in: lib.recent(), sort: .recent).map(\.title), ["Zeta"])
        lib.setFavorite("/m/Zeta.mkv", true)
        lib.clearHistory()
        XCTAssertTrue(lib.recent().isEmpty)
        XCTAssertEqual(lib.favorites().map(\.title), ["Zeta"], "favourites survive clearing history")
    }

    func testCorruptStoreIsBackedUp() throws {
        let store = dir.appendingPathComponent("library.json")
        try Data("{not json".utf8).write(to: store)
        let lib = MediaLibrary(storeURL: store)
        XCTAssertTrue(lib.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.corrupt.json").path))
    }

    func testDamagedRecordDoesNotDiscardLibraryAndBackupsAreKept() throws {
        let store = dir.appendingPathComponent("library.json")
        let json = """
            {"version":1,"playlist":{"items":["/a"],"repeatMode":"off"},
             "records":[{"path":"/a","title":"A","addedAt":"2026-01-01T00:00:00Z","playCount":1,"favorite":true,"audioDelayMs":5,"subtitleOffsetMs":0},
                        {"path":42}]}
            """
        try Data(json.utf8).write(to: store)
        try Data("older backup".utf8).write(to: dir.appendingPathComponent("library.corrupt.json"))
        let lib = MediaLibrary(storeURL: store)
        XCTAssertEqual(lib.record(for: "/a")?.audioDelayMs, 5, "readable records survive")
        XCTAssertEqual(lib.unreadableRecordCount, 1)
        XCTAssertEqual(lib.playlist.items, ["/a"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("library.corrupt") }
        XCTAssertEqual(backups.count, 2, "a new backup is written next to the existing one")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("library.corrupt.json"), encoding: .utf8), "older backup")
    }

    func testSubtitleScaleIsPersisted() throws {
        let store = dir.appendingPathComponent("library.json")
        let lib = MediaLibrary(storeURL: store)
        lib.setSubtitleState("/m", subtitlePath: "/m.srt", offsetMs: -800, scale: 1.0427)
        try lib.save()
        let again = MediaLibrary(storeURL: store)
        XCTAssertEqual(again.record(for: "/m")?.subtitleScale ?? 0, 1.0427, accuracy: 1e-9)
        XCTAssertEqual(again.record(for: "/m")?.subtitleOffsetMs, -800)
    }

    func testMatchingSubtitlesAndMediaDiscovery() throws {
        for name in ["Movie.mkv", "Movie.srt", "Movie.en.vtt", "Other.srt", "notes.txt", "clip.mp4"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let subs = MediaLibrary.matchingSubtitles(for: dir.appendingPathComponent("Movie.mkv")).map(\.lastPathComponent)
        XCTAssertEqual(subs, ["Movie.srt", "Movie.en.vtt"])
        XCTAssertEqual(MediaLibrary.mediaFiles(in: dir).map(\.lastPathComponent), ["clip.mp4", "Movie.mkv"])
    }
}
