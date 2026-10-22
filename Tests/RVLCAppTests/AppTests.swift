import AppKit
import Combine
import RVLCTestSupport
import XCTest

@testable import RVLCApp
@testable import RVLCCore
@testable import RVLCEngine

/// Builds a real (headless) engine, isolated preferences and a temporary library.
class AppTestCase: XCTestCase {
    var media: Fixtures.Media!
    var player: MPVPlayer!
    var prefs: Preferences!
    var library: MediaLibrary!
    var controller: PlayerController!
    var suite: String!
    var tempDir: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        media = try Fixtures.media()
        suite = "rvlc-app-tests-\(UUID())"
        prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        // Deterministic tests: fixtures sit next to same-named subtitles.
        prefs.autoLoadSubtitles = false
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-app-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        library = MediaLibrary(storeURL: tempDir.appendingPathComponent("library.json"))
        player = try MPVPlayer(configuration: .init(headless: true, initialVolume: prefs.volume, maxVolume: prefs.maxVolume))
        controller = PlayerController(
            player: player, preferences: prefs, library: library, cacheDirectory: tempDir.appendingPathComponent("previews"))
    }

    var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
        controller = nil
        player?.shutdown()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func openVideo(_ url: URL? = nil, paused: Bool = true) {
        controller.open([url ?? media.video])
        waitUntil("playing") { player.status == .playing && player.duration > 0 }
        if paused {
            player.pause()
            waitUntil("paused") { player.status == .paused }
        }
    }
}

// MARK: - Controller behaviour

final class PlayerControllerTests: AppTestCase {
    func testOpenQueuesAndPlaysAndRecordsHistory() {
        openVideo(paused: false)
        XCTAssertEqual(controller.playlist.items, [media.video.path])
        XCTAssertEqual(controller.playlist.currentIndex, 0)
        XCTAssertNotNil(library.record(for: media.video.path)?.lastPlayed)
    }

    func testOpeningSubtitleWithoutMediaIsRejectedGracefully() {
        controller.open([media.subtitle])
        XCTAssertNotNil(controller.lastError)
        XCTAssertNil(controller.subtitles.document)
    }

    func testPlaylistAdvancesAtEndOfFile() {
        controller.open([media.video, media.shortVideo])
        waitUntil("first playing") { player.status == .playing && player.currentURL == media.video }
        player.seek(7.7)
        waitUntil("advanced to second item", timeout: 8) { player.currentURL == media.shortVideo && player.status == .playing }
        XCTAssertEqual(controller.playlist.currentIndex, 1)
    }

    func testResumePositionIsRestored() {
        library.updatePosition(media.video.path, position: 5, duration: 60)  // 60 s duration makes 5 s resumable…
        library.updatePosition(media.video.path, position: 12, duration: 60)  // …but 12 s is above the 10 s threshold
        XCTAssertEqual(library.resumePosition(for: media.video.path), 12)
        prefs.rememberPosition = true
        // The fixture is only 8 s long, so seed a resumable position below its end.
        library.updatePosition(media.video.path, position: 3, duration: nil)
        XCTAssertNil(library.resumePosition(for: media.video.path), "below the 10 s minimum")
    }

    func testPerFileAudioDelayIsRememberedAndRestored() {
        openVideo()
        controller.setAudioDelay(-180)
        waitUntil("delay applied") { player.audioDelayMs == -180 }
        XCTAssertEqual(library.record(for: media.video.path)?.audioDelayMs, -180)
        controller.open([media.shortVideo])
        waitUntil("second file") { player.currentURL == media.shortVideo && player.status.hasMedia }
        waitUntil("delay reset for other file") { player.audioDelayMs == 0 }
        controller.play(at: 0)
        waitUntil("first file again") { player.currentURL == media.video && player.status.hasMedia }
        waitUntil("delay restored") { player.audioDelayMs == -180 }
    }

    func testRapidOffsetKeyPressesNeverLoseSteps() {
        openVideo()
        try? controller.subtitles.load(media.subtitle)
        for _ in 0..<7 { controller.perform(.subtitleLater) }
        for _ in 0..<2 { controller.perform(.subtitleEarlier) }
        XCTAssertEqual(player.currentSubtitleDelayMs, 500, "7×+100 then 2×−100, applied synchronously")
        for _ in 0..<3 { controller.perform(.audioLater) }
        XCTAssertEqual(player.currentAudioDelayMs, 300)
        XCTAssertEqual(player.currentSubtitleDelayMs, 500, "audio keys never touch the subtitle offset")
        controller.perform(.subtitleReset)
        XCTAssertEqual(player.currentSubtitleDelayMs, 0)
        XCTAssertEqual(player.currentAudioDelayMs, 300, "subtitle reset leaves audio alone")
        controller.perform(.audioReset)
        XCTAssertEqual(player.currentAudioDelayMs, 0)
    }

    func testStepSizeComesFromPreferences() {
        openVideo()
        prefs.subtitleStepMs = 250
        prefs.audioStepMs = 500
        controller.perform(.subtitleLater)
        controller.perform(.audioEarlier)
        XCTAssertEqual(player.currentSubtitleDelayMs, 250)
        XCTAssertEqual(player.currentAudioDelayMs, -500)
    }

    func testVolumeIsClampedAndPersisted() {
        openVideo()
        controller.perform(.volumeUp)
        controller.setVolume(150)
        XCTAssertEqual(player.currentVolume, 100, "amplification disabled by default")
        prefs.allowAmplification = true
        waitUntil("volume-max raised") { (player.double("volume-max") ?? 0) >= 200 }
        controller.setVolume(150)
        XCTAssertEqual(player.currentVolume, 150)
        XCTAssertEqual(prefs.volume, 150)
        XCTAssertTrue(player.string("af")?.contains("alimiter") == true, "limiter guards against clipping")
    }

    func testSpeedSteps() {
        openVideo()
        controller.perform(.speedUp)
        XCTAssertEqual(player.currentSpeed, 1.1, accuracy: 1e-9)
        controller.perform(.speedDown)
        controller.perform(.speedDown)
        XCTAssertEqual(player.currentSpeed, 0.9, accuracy: 1e-9)
        controller.perform(.speedReset)
        XCTAssertEqual(player.currentSpeed, 1)
    }

    func testCycleSubtitleTracksIncludingOff() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        waitUntil("selected") { player.selectedTrack(.sub) != nil }
        controller.perform(.cycleSubtitle)
        waitUntil("off") { player.selectedTrack(.sub) == nil }
        controller.perform(.cycleSubtitle)
        waitUntil("on again") { player.selectedTrack(.sub) != nil }
    }
}

// MARK: - Subtitle Studio workflows on the real engine

final class SubtitleSessionTests: AppTestCase {
    var session: SubtitleSession { controller.subtitles }

    func testImportPreviewAndOffsetDirection() throws {
        openVideo()
        try session.load(media.subtitle)
        XCTAssertNotNil(session.trackID)
        player.seek(2.5)
        waitUntil("seeked") { abs(player.position - 2.5) < 0.1 && !player.isSeeking }
        spin(0.2)
        XCTAssertEqual(player.currentSubtitleText, "Alpha")
        controller.setSubtitleOffset(1000)
        player.seek(3.5)
        waitUntil("seeked") { abs(player.position - 3.5) < 0.1 && !player.isSeeking }
        spin(0.2)
        XCTAssertEqual(player.currentSubtitleText, "Alpha", "positive offset shows the line later")
        XCTAssertEqual(library.record(for: media.video.path)?.subtitleOffsetMs, 1000, "offset remembered per file")
    }

    func testSyncPointSuggestionPreviewRejectAndAccept() throws {
        openVideo()
        try session.load(media.subtitle)
        // “Alpha” (2.0 s in the file) is actually heard at 2.75 s.
        let fit = session.addSyncPoint(cueIndex: 0, mediaSeconds: 2.75)
        XCTAssertEqual(fit?.transform.offsetMs, 750)
        XCTAssertNotNil(session.suggestion)
        XCTAssertEqual(session.offsetMs, 0, "a suggestion is never applied without consent")

        session.previewSuggestion()
        XCTAssertEqual(session.offsetMs, 750)
        session.rejectSuggestion()
        XCTAssertEqual(session.offsetMs, 0, "rejecting restores the previous timing")
        XCTAssertNil(session.suggestion)

        session.addSyncPoint(cueIndex: 0, mediaSeconds: 2.75)
        session.acceptSuggestion()
        XCTAssertEqual(session.offsetMs, 750)
        XCTAssertNil(session.suggestion)
    }

    func testEditsArePreviewedLiveAndUndoable() throws {
        openVideo()
        try session.load(media.subtitle)
        let firstTrack = session.trackID
        session.setText("Changed", at: 0)
        XCTAssertTrue(session.hasEdits)
        waitUntil("preview track replaced") { session.trackID != nil && session.trackID != firstTrack }
        player.seek(2.5)
        waitUntil("seeked") { abs(player.position - 2.5) < 0.1 && !player.isSeeking }
        spin(0.3)
        XCTAssertEqual(player.currentSubtitleText, "Changed")
        session.undo()
        XCTAssertEqual(session.document?.cues[0].text, "Alpha")
        session.redo()
        XCTAssertEqual(session.document?.cues[0].text, "Changed")
        session.revertEdits()
        XCTAssertFalse(session.hasEdits)
        XCTAssertEqual(player.tracks(.sub).count, 1, "old preview tracks are removed, not accumulated")
    }

    func testExportMatchesPreviewAndKeepsSource() throws {
        openVideo()
        let original = try String(contentsOf: media.subtitle, encoding: .utf8)
        try session.load(media.subtitle)
        controller.setSubtitleOffset(-500)
        let dest = tempDir.appendingPathComponent("out.vtt")
        let report = try session.export(to: dest, format: .vtt, encoding: "utf-8")
        XCTAssertEqual(report.cueCount, 2)
        let exported = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(exported.hasPrefix("WEBVTT"))
        XCTAssertTrue(exported.contains("00:00:01.500 --> 00:00:02.500"))
        XCTAssertEqual(try String(contentsOf: media.subtitle, encoding: .utf8), original)
    }

    func testPreviewFilesAreCleanedUp() throws {
        openVideo()
        let previews = tempDir.appendingPathComponent("previews")
        try session.load(media.subtitle)
        session.setText("Edited", at: 0)
        waitUntil("preview rewritten") { session.trackID != nil && session.hasEdits }
        spin(0.5)
        let count = try FileManager.default.contentsOfDirectory(atPath: previews.path).count
        XCTAssertEqual(count, 1, "only the active preview file is kept")
        controller.removeSubtitle()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path).count, 0)
        // Stale files from an unclean shutdown are purged on the next start.
        let stale = previews.appendingPathComponent("preview-stale.srt")
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 3600)], ofItemAtPath: stale.path)
        _ = SubtitleSession(player: player, cacheDirectory: previews)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testRemoveSubtitle() throws {
        openVideo()
        try session.load(media.subtitle)
        controller.removeSubtitle()
        XCTAssertNil(session.document)
        waitUntil("track removed") { player.tracks(.sub).isEmpty }
        XCTAssertEqual(player.currentSubtitleDelayMs, 0)
    }

    func testMatchingSubtitleIsLoadedAutomatically() {
        prefs.autoLoadSubtitles = true
        openVideo()
        waitUntil("auto-loaded") { session.document?.sourceURL?.lastPathComponent == media.subtitle.lastPathComponent }
        XCTAssertNotNil(session.trackID)
    }

    func testInvalidSubtitleFileReportsError() throws {
        openVideo()
        let bogus = tempDir.appendingPathComponent("bogus.srt")
        try Data("not a subtitle".utf8).write(to: bogus)
        controller.loadSubtitle(bogus)
        XCTAssertNotNil(controller.lastError)
        XCTAssertNil(session.document)
    }

    func testAutoSyncFromAudioProducesSuggestion() throws {
        openVideo()
        try session.load(media.earlySubtitle)
        session.analyzeAudio(maxOffsetSeconds: 1.5)
        waitUntil("analysis finished", timeout: 30) { !session.isAnalyzing }
        let suggestion = try XCTUnwrap(session.suggestion, session.lastError ?? "no suggestion")
        XCTAssertEqual(suggestion.transform.offsetMs, 600, accuracy: 60)
        XCTAssertEqual(session.offsetMs, 0, "audio analysis only suggests")
    }
}

// MARK: - UI behaviour

final class UIBehaviourTests: AppTestCase {
    func makeWindow(_ view: NSView, size: NSSize = NSSize(width: 900, height: 600)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    func testEachControlButtonTriggersOnlyItsOwnAction() {
        openVideo()
        let bar = ControlBarView(controller: controller)
        let window = makeWindow(bar)
        _ = window
        // Play/Pause toggles playback but nothing else.
        let volume = player.currentVolume, speed = player.currentSpeed, muted = player.isMuted
        bar.playButton.performClick(nil)
        waitUntil("playing") { player.status == .playing }
        XCTAssertEqual(player.currentVolume, volume)
        XCTAssertEqual(player.currentSpeed, speed)
        XCTAssertEqual(player.isMuted, muted)
        // Mute changes only mute.
        bar.muteButton.performClick(nil)
        waitUntil("muted") { player.isMuted }
        XCTAssertEqual(player.status, .playing)
        // Seek forward changes only the position.
        let before = player.currentPosition
        bar.seekForwardButton.performClick(nil)
        waitUntil("seeked forward") { player.currentPosition > before + 3 }
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.status, .playing)
        // Stop returns to idle.
        bar.stopButton.performClick(nil)
        waitUntil("idle") { player.status == .idle }
    }

    func testButtonsDoNotTakeKeyboardFocusOnClick() {
        let bar = ControlBarView(controller: controller)
        for button in [bar.playButton!, bar.muteButton!, bar.fullscreenButton!, bar.stopButton!] {
            XCTAssertTrue(button.refusesFirstResponder, "clicking must not let Space re-trigger \(button.toolTip ?? "")")
        }
        XCTAssertTrue(bar.timeline.refusesFirstResponder)
    }

    func testPlayButtonReflectsEngineState() {
        let bar = ControlBarView(controller: controller)
        _ = makeWindow(bar)
        XCTAssertEqual(bar.playButton.symbol, .play)
        XCTAssertFalse(bar.timeline.isEnabled, "no media: timeline disabled")
        openVideo(paused: false)
        waitUntil("pause symbol") { bar.playButton.symbol == .pause }
        XCTAssertTrue(bar.timeline.isEnabled)
        player.pause()
        waitUntil("play symbol") { bar.playButton.symbol == .play }
    }

    func testResponsiveControlBarDetachesLowPriorityControls() {
        openVideo()
        let bar = ControlBarView(controller: controller)
        let window = makeWindow(bar, size: NSSize(width: 1000, height: 100))
        window.layoutIfNeeded()
        XCTAssertTrue(bar.buttonRow.detachedViews.isEmpty, "everything fits in a wide window")
        window.setContentSize(NSSize(width: 380, height: 100))
        window.layoutIfNeeded()
        let detached = bar.buttonRow.detachedViews
        XCTAssertFalse(detached.isEmpty, "narrow window detaches low-priority controls")
        XCTAssertFalse(detached.contains(bar.playButton), "play/pause always stays")
        XCTAssertFalse(detached.contains(bar.fullscreenButton), "full screen always stays")
        // Visible controls never overlap.
        let visible = bar.buttonRow.arrangedSubviews.filter { !$0.isHidden && !detached.contains($0) && $0.frame.width > 0 }
        for (i, a) in visible.enumerated() {
            for b in visible[(i + 1)...] { XCTAssertFalse(a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame), "controls overlap") }
            XCTAssertLessThanOrEqual(a.frame.maxX, bar.buttonRow.bounds.maxX + 0.5)
        }
    }

    func testEmptyAndErrorStates() {
        let vc = PlayerViewController(controller: controller, videoView: nil)
        _ = makeWindow(vc.view)
        XCTAssertFalse(vc.emptyState.isHidden, "empty state before any file")
        XCTAssertTrue(vc.errorOverlay.isHidden)
        controller.open([media.broken])
        waitUntil("error overlay") { !vc.errorOverlay.isHidden }
        XCTAssertTrue(vc.emptyState.isHidden)
        openVideo()
        waitUntil("overlay cleared") { vc.errorOverlay.isHidden }
        XCTAssertTrue(vc.emptyState.isHidden)
    }

    func testOSDShowsFeedback() {
        let vc = PlayerViewController(controller: controller, videoView: nil)
        _ = makeWindow(vc.view)
        openVideo()
        controller.perform(.subtitleLater)
        waitUntil("osd text") { vc.osdView.text.contains("Subtitle offset +0.100 s") }
        controller.perform(.audioEarlier)
        waitUntil("osd text") { vc.osdView.text.contains("Audio delay −0.100 s") }
    }

    func testThemeSwitchingAndPersistence() {
        prefs.theme = .dark
        Theme.apply(prefs.theme)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        prefs.theme = .light
        Theme.apply(prefs.theme)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        prefs.theme = .system
        Theme.apply(prefs.theme)
        XCTAssertNil(NSApp.appearance, "system theme follows macOS")
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: suite)!).theme, .system)
    }

    func testOffsetControlNumericEntryAndReset() {
        var received: [Int] = []
        let control = OffsetControl(wording: .init(positive: "%@ later", negative: "%@ earlier", zero: "zero"), accessibilityName: "Test") {
            received.append($0)
        }
        control.nudge(250)
        control.nudge(-100)
        XCTAssertEqual(control.value, 150)
        control.setValue(0, notify: true)
        XCTAssertEqual(received, [250, 150, 0])
    }
}

// MARK: - Keyboard routing

final class KeyboardRoutingTests: AppTestCase {
    var router: KeyboardRouter!
    var window: NSWindow!
    var field: NSTextField!
    var table: NSTableView!
    var plain: NSView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        router = KeyboardRouter(controller: controller)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        table = NSTableView(frame: NSRect(x: 10, y: 50, width: 200, height: 100))
        plain = FocusableView(frame: NSRect(x: 10, y: 160, width: 100, height: 100))
        [field, table, plain].forEach { content.addSubview($0!) }
        window.contentView = content
    }

    func key(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testKeyEventToComboConversion() {
        XCTAssertEqual(KeyboardRouter.combo(for: key(" ", code: 49)), KeyCombo("space"))
        XCTAssertEqual(KeyboardRouter.combo(for: key("", code: 123, mods: .shift)), KeyCombo("left", [.shift]))
        XCTAssertEqual(KeyboardRouter.combo(for: key("?", code: 44, mods: .shift)), KeyCombo("/", [.shift]))
        XCTAssertEqual(KeyboardRouter.combo(for: key("z", code: 6)), KeyCombo("z"))
    }

    func testShortcutsWorkWhenNothingIsBeingEdited() {
        openVideo()
        window.makeFirstResponder(plain)
        XCTAssertTrue(router.handle(key(" ", code: 49)))
        waitUntil("playing") { player.status == .playing }
        XCTAssertTrue(router.handle(key("x", code: 7)))
        XCTAssertEqual(player.currentSubtitleDelayMs, 100)
        XCTAssertTrue(router.handle(key("v", code: 9)))
        XCTAssertEqual(player.currentAudioDelayMs, 100)
    }

    func testShortcutsDoNotInterfereWithTextEditing() {
        openVideo()
        window.makeFirstResponder(field)
        XCTAssertFalse(router.handle(key(" ", code: 49)), "Space types a space in text fields")
        XCTAssertFalse(router.handle(key("x", code: 7)), "letters type text")
        XCTAssertFalse(router.handle(key("", code: 123)), "arrows move the caret")
        XCTAssertEqual(player.currentSubtitleDelayMs, 0)
        XCTAssertEqual(player.status, .paused)
        // Command shortcuts still work while typing.
        XCTAssertTrue(router.handle(key(".", code: 47, mods: .command)))
        waitUntil("stopped") { player.status == .idle }
    }

    func testFocusedControlsKeepTheirKeys() {
        let table = NSTableView()
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(table, combo: KeyCombo("down")), "arrows move the list selection")
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(table, combo: KeyCombo("left")))
        XCTAssertFalse(KeyboardRouter.responderOwnsKey(table, combo: KeyCombo("space")), "Space still plays/pauses in lists")
        XCTAssertFalse(KeyboardRouter.responderOwnsKey(table, combo: KeyCombo("z")))
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(NSSlider(), combo: KeyCombo("right")))
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(NSPopUpButton(), combo: KeyCombo("space")))
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(NSButton(), combo: KeyCombo("space")), "keyboard-focused buttons keep Space")
        XCTAssertFalse(KeyboardRouter.responderOwnsKey(NSButton(), combo: KeyCombo("m")))
        XCTAssertTrue(KeyboardRouter.responderOwnsKey(KeyRecorderField(combo: nil), combo: KeyCombo("z")))
    }

    func testSheetsBlockShortcuts() {
        openVideo()
        window.makeFirstResponder(plain)
        router.isEligibleWindow = { _ in false }
        XCTAssertFalse(router.handle(key(" ", code: 49)))
    }

    func testCustomBindingTakesEffect() {
        openVideo()
        window.makeFirstResponder(plain)
        var map = prefs.keyMap
        map.set([KeyCombo("k")], for: .playPause)
        prefs.keyMap = map
        waitUntil("keymap propagated") { controller.keyMap.action(for: KeyCombo("k")) == .playPause }
        XCTAssertFalse(router.handle(key(" ", code: 49)), "old binding removed")
        XCTAssertTrue(router.handle(key("k", code: 40)))
        waitUntil("playing") { player.status == .playing }
    }
}

final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Every screen can be built and shows real state

final class ScreenSmokeTests: AppTestCase {
    func testMainWindowAndAllSidebarPanelsBuild() throws {
        let main = MainWindowController(controller: controller, videoView: nil)
        if let window = main.window {
            window.isReleasedWhenClosed = false
            windows.append(window)
        }
        openVideo()
        try controller.subtitles.load(media.subtitle)
        for tab in SidebarTab.allCases {
            main.showPanel(tab)
            main.window?.layoutIfNeeded()
            XCTAssertEqual(main.sidebarVC.current, tab)
            XCTAssertNotNil(main.sidebarVC.panel(tab).view.superview, "\(tab) panel is installed")
        }
        XCTAssertTrue(main.isSidebarVisible)
        main.toggleSidebar()
        XCTAssertFalse(prefs.sidebarVisible, "sidebar visibility persisted")
    }

    func testSubtitleStudioListsLinesAndSyncButtonUsesSelection() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        let studio = SubtitleStudioPanel(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = studio
        waitUntil("lines listed") { studio.lineTable.numberOfRows == 2 }
        studio.lineTable.selectRowIndexes([1], byExtendingSelection: false)
        player.seek(5.4)
        waitUntil("seeked") { abs(player.currentPosition - 5.4) < 0.1 }
        controller.perform(.setSyncPoint)
        XCTAssertEqual(controller.subtitles.syncPoints.first?.subtitleMs, 5000, "selected line (Bravo) was used")
        XCTAssertEqual(controller.subtitles.suggestion?.transform.offsetMs ?? 0, 400, accuracy: 60)
    }

    func testEditorSettingsAndShortcutWindowsBuild() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        let editor = SubtitleEditorWindowController(controller: controller)
        editor.window?.isReleasedWhenClosed = false
        windows.append(editor.window!)
        editor.reload()
        XCTAssertEqual(editor.rows.count, 2)
        editor.searchField.stringValue = "bravo"
        editor.reload()
        editor.replaceField.stringValue = "Charlie"
        editor.replaceAll()
        XCTAssertEqual(controller.subtitles.document?.cues[1].text, "Charlie")
        editor.table.selectRowIndexes([0], byExtendingSelection: false)
        editor.shiftSelected(100)
        XCTAssertEqual(controller.subtitles.document?.cues[0].startMs, 2100)

        let settings = SettingsWindowController(controller: controller)
        settings.window?.isReleasedWhenClosed = false
        windows.append(settings.window!)
        XCTAssertNotNil(settings.window?.contentViewController)
        let shortcuts = ShortcutsWindowController(controller: controller)
        shortcuts.window?.isReleasedWhenClosed = false
        windows.append(shortcuts.window!)
        let text = ShortcutsWindowController.reference(controller.keyMap).string
        XCTAssertTrue(text.contains("Subtitles earlier"))
        XCTAssertTrue(text.contains("Audio later"))
    }

    func testFullscreenOverlayModeAutoHidesControlsOnlyWhilePlaying() {
        let vc = PlayerViewController(controller: controller, videoView: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = vc
        openVideo(paused: true)
        vc.setOverlayMode(true)
        XCTAssertTrue(vc.isOverlayMode)
        spin(3)
        XCTAssertEqual(vc.controlBar.alphaValue, 1, "controls stay visible while paused")
        vc.setOverlayMode(false)
        XCTAssertFalse(vc.isOverlayMode)
        XCTAssertEqual(vc.controlBar.alphaValue, 1)
    }
}

// MARK: - Regressions found in pre-release review

final class ControllerRegressionTests: AppTestCase {
    func testUnexportedEditsAreProtected() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        controller.subtitles.setText("Edited", at: 0)
        var asked: [String] = []
        controller.confirmDiscardEdits = { action in
            asked.append(action)
            return false
        }
        controller.open([media.shortVideo])
        spin(0.5)
        XCTAssertEqual(player.currentURL, media.video, "declining keeps the current file")
        XCTAssertEqual(controller.subtitles.document?.cues[0].text, "Edited")
        controller.removeSubtitle()
        XCTAssertNotNil(controller.subtitles.document)
        XCTAssertEqual(asked.count, 2)
        controller.confirmDiscardEdits = { _ in true }
        controller.removeSubtitle()
        XCTAssertNil(controller.subtitles.document)
    }

    func testEndOfFileDoesNotAdvanceAwayFromEdits() throws {
        controller.open([media.video, media.shortVideo])
        waitUntil("playing") { player.status == .playing && player.currentURL == media.video }
        try controller.subtitles.load(media.subtitle)
        controller.subtitles.setText("Edited", at: 0)
        player.seek(7.7)
        waitUntil("ended", timeout: 6) { player.status == .ended }
        spin(0.5)
        XCTAssertEqual(player.currentURL, media.video)
        XCTAssertEqual(controller.subtitles.document?.cues[0].text, "Edited")
    }

    func testDriftCorrectionIsRememberedPerFile() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        controller.subtitles.apply(TimingTransform(scale: 25.0 / 24.0, offsetMs: -800))
        controller.rememberSubtitleState()
        XCTAssertEqual(library.record(for: media.video.path)?.subtitleScale ?? 0, 25.0 / 24.0, accuracy: 1e-9)
        controller.open([media.shortVideo])
        waitUntil("other file") { player.currentURL == media.shortVideo && player.status.hasMedia }
        controller.play(at: 0)
        waitUntil("subtitle restored") { controller.subtitles.document != nil }
        XCTAssertEqual(controller.subtitles.scale, 25.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(player.currentSubtitleDelayMs, -800)
    }

    func testPreviewedSuggestionIsNotPersistedAsAccepted() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        controller.subtitles.addSyncPoint(cueIndex: 0, mediaSeconds: 4.0)
        controller.subtitles.previewSuggestion()
        XCTAssertEqual(player.currentSubtitleDelayMs, 2000)
        controller.rememberSubtitleState()
        XCTAssertEqual(library.record(for: media.video.path)?.subtitleOffsetMs, 0, "only committed timing is saved")
    }

    func testEscapeIsNotConsumedOutsideFullScreen() {
        XCTAssertFalse(controller.perform(.exitFullscreen))
        controller.isFullscreen = true
        XCTAssertTrue(controller.perform(.exitFullscreen))
    }

    func testPlayFromBeginningIgnoresResumePosition() {
        openVideo(paused: false)
        player.seek(5)
        waitUntil("seeked") { player.currentPosition > 4.5 }
        library.updatePosition(media.video.path, position: 12, duration: 60)
        controller.open([media.video], fromStart: true)
        waitUntil("restarted") { player.status == .playing && player.currentPosition < 2 }
    }

    func testRemovingExternalAudioFallsBackToEmbeddedTrack() throws {
        openVideo()
        let external = try XCTUnwrap(try player.addAudio(media.externalAudio))
        waitUntil("external selected") { player.selectedTrack(.audio)?.id == external }
        controller.removeExternalAudio(id: external)
        waitUntil("embedded selected") { player.selectedTrack(.audio).map { !$0.isExternal } ?? false }
    }

    func testResetAllSettingsReachesRunningPlayer() {
        var map = prefs.keyMap
        map.set([KeyCombo("k")], for: .playPause)
        prefs.keyMap = map
        prefs.allowAmplification = true
        XCTAssertEqual(controller.keyMap.action(for: KeyCombo("k")), .playPause)
        prefs.resetAll()
        XCTAssertEqual(controller.keyMap, KeyMap(), "custom shortcuts are cleared in the running app")
        XCTAssertEqual(player.maxVolume, 100)
    }

    func testOpeningSamePathThroughSymlinkSharesHistory() throws {
        let link = tempDir.appendingPathComponent("alias.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: media.video)
        openVideo()
        controller.setAudioDelay(-120)
        controller.open([link])
        spin(0.5)
        XCTAssertEqual(controller.playlist.items.count, 1, "the same file is not queued twice")
        XCTAssertEqual(player.currentAudioDelayMs, -120)
    }

    func testSpeedMessageShowsTwoDecimals() {
        openVideo()
        var messages: [String] = []
        let token = controller.osd.sink { messages.append($0) }
        controller.setSpeed(1.25)
        token.cancel()
        XCTAssertEqual(messages.last, "Speed 1.25×")
    }
}

final class UIRegressionTests2: AppTestCase {
    func testListKeysRespectModifiersAndHandlers() {
        let table = ActionTableView()
        let column = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(column)
        final class Source: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        }
        let source = Source()
        table.dataSource = source
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
        var returns = 0
        table.onReturn = { returns += 1 }
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
        }
        table.keyDown(with: key(36, []))
        XCTAssertEqual(returns, 1)
        table.keyDown(with: key(36, .command))
        XCTAssertEqual(returns, 1, "⌘Return is not swallowed as Return")
        table.keyDown(with: key(51, []))  // no onDelete handler: passes through without crashing
    }

    func testEditorDiscardsCellFromReplacedDocument() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        let editor = SubtitleEditorWindowController(controller: controller)
        editor.window?.isReleasedWhenClosed = false
        windows.append(editor.window!)
        editor.reload()
        let column = try XCTUnwrap(editor.table.tableColumns.first { $0.identifier.rawValue == "text" })
        let cell = try XCTUnwrap(editor.tableView(editor.table, viewFor: column, row: 0) as? NSTextField)
        try controller.subtitles.load(media.earlySubtitle)  // another document replaces the first
        let newText = controller.subtitles.document?.cues[0].text
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cell))
        XCTAssertEqual(controller.subtitles.document?.cues[0].text, newText, "old cell text is not written into the new document")
        XCTAssertFalse(controller.subtitles.hasEdits)
    }

    func testEncodingChangeKeepsDriftAndOffset() throws {
        openVideo()
        try controller.subtitles.load(media.subtitle)
        controller.subtitles.apply(TimingTransform(scale: 25.0 / 24.0, offsetMs: 300))
        try controller.subtitles.reload(encoding: "windows-1252")
        XCTAssertEqual(controller.subtitles.scale, 25.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(player.currentSubtitleDelayMs, 300)
    }
}

final class TimelineAndGoToTests: AppTestCase {
    func testHoverLabelSitsAboveTheBarAndShowsTimeUnderPointer() throws {
        openVideo()
        let bar = ControlBarView(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        let slider = bar.timeline
        waitUntil("duration known") { slider.duration > 0 }
        for fraction in [0.0, 0.5, 1.0] {
            let barRect = slider.convert(slider.bounds, to: nil)
            let x = slider.bounds.width * CGFloat(fraction)
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: slider.convert(NSPoint(x: x, y: slider.bounds.midY), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            slider.mouseMoved(with: event)
            let hover = try XCTUnwrap(slider.hoverState)
            XCTAssertFalse(hover.frameInWindow.intersects(barRect), "label must not cover the bar or the pointer (fraction \(fraction))")
            XCTAssertGreaterThanOrEqual(hover.frameInWindow.minY, barRect.maxY, "label sits above the bar")
            XCTAssertGreaterThanOrEqual(hover.frameInWindow.minX, 0)
            XCTAssertLessThanOrEqual(hover.frameInWindow.maxX, content.bounds.width, "label stays inside the window")
            XCTAssertEqual(hover.text, Timecode.formatClock(seconds: slider.seconds(atX: x)))
        }
        XCTAssertEqual(slider.seconds(atX: -50), 0, "positions left of the bar clamp to the start")
        XCTAssertEqual(slider.seconds(atX: slider.bounds.width + 50), slider.duration, accuracy: 1e-9)
    }

    func testAccessibilityAdjustmentSeeksExactly() {
        openVideo()
        let bar = ControlBarView(controller: controller)
        _ = bar
        bar.timeline.duration = player.duration
        bar.timeline.doubleValue = 6.0
        bar.timeline.sendAction(bar.timeline.action, to: bar.timeline.target)
        waitUntil("seeked to 6 s") { abs(player.currentPosition - 6.0) < 0.1 && !player.isSeeking }
    }

    func testGoToTimeSheetValidatesAndJumps() {
        var jumped: [Double] = []
        let sheet = GoToTimeSheet(current: 2, duration: 8) { jumped.append($0) }
        XCTAssertEqual(sheet.field.stringValue, "0:02", "pre-filled with the current time")
        sheet.field.stringValue = "abc"
        sheet.go()
        XCTAssertTrue(jumped.isEmpty, "invalid input keeps the sheet open")
        sheet.field.stringValue = "0:09"
        sheet.go()
        XCTAssertTrue(jumped.isEmpty, "beyond the end is rejected")
        sheet.field.stringValue = "0:05.5"
        sheet.go()
        XCTAssertEqual(jumped, [5.5])
    }
}

extension TimelineAndGoToTests {
    /// Reproduces the real window: the player sits inside a split view.
    func testHoverLabelIsVisibleInsideTheRealSplitViewLayout() throws {
        openVideo()
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.layoutIfNeeded()
        let slider = main.playerVC.controlBar.timeline
        waitUntil("duration known") { slider.duration > 0 }
        let host = try XCTUnwrap(slider.hoverHost)
        XCTAssertFalse(host is NSSplitView, "never add the label to a split view")
        XCTAssertTrue(host === main.playerVC.view, "hosted by the player view, above video and controls")
        let x = slider.bounds.width * 0.6
        let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: slider.convert(NSPoint(x: x, y: slider.bounds.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        slider.mouseMoved(with: event)
        let hover = try XCTUnwrap(slider.hoverState)
        let barRect = slider.convert(slider.bounds, to: nil)
        XCTAssertFalse(hover.frameInWindow.intersects(barRect))
        XCTAssertGreaterThanOrEqual(hover.frameInWindow.minY, barRect.maxY)
        XCTAssertTrue(main.playerVC.view.convert(main.playerVC.view.bounds, to: nil).contains(hover.frameInWindow), "label fully visible")
        XCTAssertEqual(main.split.splitViewItems.count, 2, "split view layout is untouched")
        XCTAssertEqual(main.split.splitView.subviews.filter { !$0.className.contains("Divider") }.count, 2, "no extra pane was added")
    }
}

extension TimelineAndGoToTests {
    /// A quick movement onto the bar can deliver only `mouseEntered`; the time must still appear.
    func testHoverTimeAppearsOnEntryWithoutFurtherMovement() throws {
        openVideo()
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.layoutIfNeeded()
        let slider = main.playerVC.controlBar.timeline
        waitUntil("duration known") { slider.duration > 0 }
        let x = slider.bounds.width * 0.25
        let entered = NSEvent.enterExitEvent(
            with: .mouseEntered, location: slider.convert(NSPoint(x: x, y: slider.bounds.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        slider.mouseEntered(with: entered)
        let hover = try XCTUnwrap(slider.hoverState, "time shown as soon as the pointer enters")
        XCTAssertEqual(hover.text, Timecode.formatClock(seconds: slider.seconds(atX: x)))
    }
}

final class SidebarLayoutTests: AppTestCase {
    /// Switching tabs must never resize the sidebar; only the user's divider drag does.
    func testSidebarWidthIsTheSameOnEveryTab() throws {
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        openVideo()
        try controller.subtitles.load(media.subtitle)
        main.showPanel(.playlist)
        window.layoutIfNeeded()
        // Start from the narrowest sidebar, where content is most likely to push it wider.
        let split = main.split.splitView
        split.setPosition(split.bounds.width - 300 - split.dividerThickness, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let initial = main.sidebarVC.view.frame.width
        XCTAssertEqual(initial, 300, accuracy: 0.5)
        for tab in SidebarTab.allCases + SidebarTab.allCases.reversed() {
            main.showPanel(tab)
            window.layoutIfNeeded()
            split.layoutSubtreeIfNeeded()
            XCTAssertEqual(main.sidebarVC.view.frame.width, initial, accuracy: 0.5, "\(tab) changed the sidebar width")
        }
    }
}

extension SidebarLayoutTests {
    /// Every clickable control explains itself on hover.
    func testEveryButtonHasATooltip() throws {
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        openVideo()
        try controller.subtitles.load(media.subtitle)
        _ = controller.subtitles.addSyncPoint(cueIndex: 0, mediaSeconds: 2.4)
        var roots: [NSView] = [main.playerVC.view, main.sidebarVC.view]
        for tab in SidebarTab.allCases { roots.append(main.sidebarVC.panel(tab).view) }
        let editor = SubtitleEditorWindowController(controller: controller)
        editor.window?.isReleasedWhenClosed = false
        windows.append(editor.window!)
        roots.append(editor.window!.contentView!)
        let settings = SettingsWindowController(controller: controller)
        settings.window?.isReleasedWhenClosed = false
        windows.append(settings.window!)
        if let tabs = settings.window?.contentViewController as? NSTabViewController {
            roots += tabs.tabViewItems.compactMap { $0.viewController?.view }
        } else {
            roots.append(settings.window!.contentView!)
        }
        roots.append(GoToTimeSheet(current: 0, duration: 10) { _ in }.window!.contentView!)
        roots.append(EmptyStateView())
        var missing: [String] = []
        func walk(_ view: NSView, _ path: String) {
            if let segmented = view as? NSSegmentedControl {
                for i in 0..<segmented.segmentCount where (segmented.toolTip(forSegment: i) ?? "").isEmpty {
                    missing.append("\(path) segment \(segmented.label(forSegment: i) ?? String(i))")
                }
            } else if let button = view as? NSButton, (button.toolTip ?? "").isEmpty {
                missing.append("\(path) \(type(of: button)) “\(button.title)” \(button.accessibilityLabel() ?? "")")
            }
            view.subviews.forEach { walk($0, path) }
        }
        for root in roots { walk(root, String(describing: type(of: root))) }
        XCTAssertEqual(missing, [], "buttons without a tooltip:\n" + missing.joined(separator: "\n"))
    }
}

final class VideoClickAndHoverTests: AppTestCase {
    private func click(_ stage: VideoStageView, in window: NSWindow, count: Int, at point: NSPoint? = nil, dragTo: NSPoint? = nil) {
        let p = point ?? stage.convert(NSPoint(x: stage.bounds.midX, y: stage.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint, _ clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        for n in 1...count {
            stage.mouseDown(with: event(.leftMouseDown, p, n))
            stage.mouseUp(with: event(.leftMouseUp, n == count ? (dragTo ?? p) : p, n))
        }
    }

    private func makePlayer() -> (PlayerViewController, NSWindow) {
        let vc = PlayerViewController(controller: controller, videoView: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = vc
        window.layoutIfNeeded()
        return (vc, window)
    }

    func testSingleClickOnVideoTogglesPlayPauseAfterAShortWait() {
        let (vc, window) = makePlayer()
        openVideo(paused: true)
        XCTAssertLessThanOrEqual(vc.stage.singleClickDelay, 0.25)
        click(vc.stage, in: window, count: 1)
        XCTAssertEqual(player.status, .paused, "waits briefly for a possible second click")
        waitUntil("playing shortly after one click", timeout: 0.6) { player.status == .playing }
        spin(0.8)
        XCTAssertEqual(player.status, .playing, "one click toggles exactly once")
        click(vc.stage, in: window, count: 1)
        waitUntil("paused shortly after another click", timeout: 0.6) { player.status == .paused }
    }

    func testFastDoubleClickTogglesFullScreenWithoutAnyPlayPause() {
        let (vc, window) = makePlayer()
        var requests = 0
        let sub = controller.fullscreenRequests.sink { _ in requests += 1 }
        defer { sub.cancel() }
        var statuses: [PlaybackStatus] = []
        let watch = player.$status.sink { statuses.append($0) }
        defer { watch.cancel() }
        for playing in [false, true] {
            openVideo(paused: !playing)
            let expected: PlaybackStatus = playing ? .playing : .paused
            requests = 0
            statuses = []
            click(vc.stage, in: window, count: 2)
            spin(0.8)
            XCTAssertEqual(requests, 1, "double-click toggles full screen")
            XCTAssertEqual(player.status, expected)
            XCTAssertFalse(statuses.contains { $0 != expected }, "no pause/play blip: \(statuses)")
        }
    }

    func testSlowDoubleClickUndoesTheFirstClicksPlayPause() {
        let (vc, window) = makePlayer()
        openVideo(paused: false)
        click(vc.stage, in: window, count: 1)
        waitUntil("first click paused", timeout: 0.6) { player.status == .paused }
        // A second click still within the system double-click interval.
        let p = vc.stage.convert(NSPoint(x: vc.stage.bounds.midX, y: vc.stage.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        vc.stage.mouseDown(with: down)
        waitUntil("playback restored", timeout: 1) { player.status == .playing }
    }

    func testRapidDoubleClicksInARowEachToggleFullScreen() {
        let (vc, window) = makePlayer()
        openVideo(paused: false)
        var requests = 0
        let sub = controller.fullscreenRequests.sink { _ in requests += 1 }
        defer { sub.cancel() }
        // Zoom in and straight back out: AppKit reports one sequence of four clicks.
        click(vc.stage, in: window, count: 4)
        spin(0.5)
        XCTAssertEqual(requests, 2, "clicks 2 and 4 are both double-clicks")
        XCTAssertEqual(player.status, .playing, "no play/pause from the third click")
    }

    func testDragOnVideoAndClickWithoutMediaDoNothing() {
        let (vc, window) = makePlayer()
        click(vc.stage, in: window, count: 1)
        spin(0.6)
        XCTAssertEqual(player.status, .idle, "a click on the start screen does not start playback")
        openVideo(paused: true)
        let start = vc.stage.convert(NSPoint(x: 100, y: 100), to: nil)
        click(vc.stage, in: window, count: 1, at: start, dragTo: NSPoint(x: start.x + 60, y: start.y))
        spin(0.6)
        XCTAssertEqual(player.status, .paused, "a drag is not a click")
    }

    func testHoverBubbleShowsOffsetAndPointsAtThePointer() throws {
        openVideo()
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.layoutIfNeeded()
        let slider = main.playerVC.controlBar.timeline
        waitUntil("duration known") { slider.duration > 0 }
        player.seek(2)
        waitUntil("at 2 s") { abs(slider.doubleValue - 2) < 0.2 }
        let host = try XCTUnwrap(slider.hoverHost)
        for fraction in [0.0, 0.75, 1.0] {
            let x = slider.bounds.width * CGFloat(fraction)
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: slider.convert(NSPoint(x: x, y: slider.bounds.midY), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            slider.mouseMoved(with: event)
            let hover = try XCTUnwrap(slider.hoverState)
            let time = slider.seconds(atX: x)
            XCTAssertEqual(hover.text, Timecode.formatClock(seconds: time))
            let delta = time - slider.doubleValue
            if abs(delta) >= 1 {
                XCTAssertEqual(hover.delta, (delta > 0 ? "+" : "−") + Timecode.formatClock(seconds: abs(delta)))
            }
            let bubble = try XCTUnwrap(host.subviews.compactMap { $0 as? TimeBubbleView }.first)
            let pointerInHost = host.convert(NSPoint(x: x, y: 0), from: slider).x
            XCTAssertEqual(
                bubble.frame.minX + bubble.arrowX, pointerInHost, accuracy: 0.5, "arrow aims at the pointer (fraction \(fraction))")
            XCTAssertTrue(host.bounds.contains(bubble.frame), "bubble stays inside the player")
            XCTAssertEqual((slider.cell as? SlimSliderCell)?.hoverFraction ?? -1, time / slider.duration, accuracy: 1e-9)
        }
        let exit = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
        slider.mouseExited(with: exit)
        XCTAssertNil(slider.hoverState, "bubble hides when the pointer leaves")
        XCTAssertNil((slider.cell as? SlimSliderCell)?.hoverFraction, "track preview clears")
    }
}

extension VideoClickAndHoverTests {
    /// Full screen is instant (no Spaces animation that would swallow a quick second double-click).
    func testInstantFullScreenCoversTheScreenAndRestoresTheWindow() throws {
        let main = MainWindowController(controller: controller, videoView: nil)
        let window = try XCTUnwrap(main.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let windowed = window.frame
        let style = window.styleMask
        controller.perform(.toggleFullscreen)
        waitUntil("full screen") { main.isFullscreen }
        XCTAssertTrue(main.isInstantFullscreen)
        XCTAssertEqual(window.frame, screen.frame, "covers the whole screen at once")
        XCTAssertFalse(window.styleMask.contains(.titled), "no title bar")
        XCTAssertTrue(window.canBecomeKey, "still receives the keyboard")
        XCTAssertTrue(controller.isFullscreen)
        XCTAssertTrue(main.playerVC.isOverlayMode)
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar))
        controller.perform(.toggleFullscreen)
        waitUntil("windowed") { !main.isFullscreen }
        XCTAssertEqual(window.frame, windowed)
        XCTAssertEqual(window.styleMask, style)
        XCTAssertEqual(NSApp.presentationOptions, [])
        XCTAssertFalse(main.playerVC.isOverlayMode)
        XCTAssertEqual(window.frameAutosaveName, "RVLCMainWindow", "window size is remembered again")
        controller.perform(.toggleFullscreen)
        waitUntil("full screen again") { main.isFullscreen }
        controller.perform(.exitFullscreen)
        waitUntil("Esc leaves full screen") { !main.isFullscreen }
    }
}
