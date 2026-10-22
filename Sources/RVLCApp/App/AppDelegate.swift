import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Application entry point used by the `RVLCPlayer` executable.
public enum RVLCApplication {
    public static func run() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            // Used by scripts/package-macos.sh to render the app icon.
            do {
                try AppIcon.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Icon export failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if args.contains("--version") {
            // Also used by the packaging script to prove the bundle launches (all libraries load).
            print("RVLC \(RVLCVersion.string)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            exit(selfTest(URL(fileURLWithPath: args[i + 1])))
        }
        // Tooltips appear after half a second instead of AppKit's default ~1 s, so
        // hovering a control explains it promptly. A user-set value still wins.
        // NSFullScreenMenuItemEverywhere: the View menu has its own instant
        // “Toggle Full Screen”; don't let AppKit add a native one next to it.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500, "NSFullScreenMenuItemEverywhere": false])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

extension RVLCApplication {
    /// Headless check used by the packaging script: opens `url` with the
    /// bundled libmpv (null outputs), verifies it plays, and prints a summary.
    static func selfTest(_ url: URL) -> Int32 {
        func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        do {
            let player = try MPVPlayer(configuration: .init(headless: true))
            defer { player.shutdown() }
            try player.open(url)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if case .error(let message) = player.status {
                    report("SELF-TEST FAILED: \(message)")
                    return 1
                }
                if player.status == .playing, player.duration > 0, player.position > 0.2 { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard player.status == .playing else {
                report("SELF-TEST FAILED: playback did not start (status \(player.status))")
                return 1
            }
            report("mpv: \(player.string("mpv-version") ?? "?")")
            report("ffmpeg: \(player.string("ffmpeg-version") ?? "?")")
            report(String(format: "duration: %.2f s, position: %.2f s", player.duration, player.position))
            report("tracks: " + player.tracks.map { "\($0.kind.rawValue):\($0.codec ?? "?")" }.joined(separator: ", "))
            player.setAudioDelay(ms: 250)
            player.setSubtitleDelay(ms: -100)
            guard player.currentAudioDelayMs == 250, player.currentSubtitleDelayMs == -100 else {
                report("SELF-TEST FAILED: delays not applied")
                return 1
            }
            report("SELF-TEST PASSED")
            return 0
        } catch {
            report("SELF-TEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isolatedDefaultsSuite = "org.rvlc.player.isolated"
    private(set) var controller: PlayerController!
    private(set) var mainWindow: MainWindowController!
    private var videoView: MPVVideoView?
    private var settings: SettingsWindowController?
    private var settingsCloseObserver: NSObjectProtocol?
    private var router: KeyboardRouter!
    private var pendingOpen: [URL] = []
    private var bag = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must exist before launch completes so Finder “Open With” files are delivered.
        NSApp.mainMenu = NSMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // RVLC_DATA_DIR selects an isolated profile (library, caches and settings)
        // for development and end-to-end tests; normal launches use the user profile.
        let environment = ProcessInfo.processInfo.environment
        let dataDir = environment["RVLC_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var defaults = UserDefaults.standard
        if dataDir != nil, let isolated = UserDefaults(suiteName: Self.isolatedDefaultsSuite) {
            if environment["RVLC_RESET"] == "1" { isolated.removePersistentDomain(forName: Self.isolatedDefaultsSuite) }
            defaults = isolated
        }
        let preferences = Preferences(defaults: defaults)
        Theme.apply(preferences.theme)
        if Bundle.main.bundleIdentifier == nil || Bundle.main.bundlePath.hasSuffix("/debug") || !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApp.applicationIconImage = AppIcon.image(size: 512)
        }

        let player: MPVPlayer
        do {
            player = try MPVPlayer(
                configuration: .init(
                    hardwareDecoding: preferences.hardwareDecoding, initialVolume: preferences.volume,
                    maxVolume: preferences.maxVolume))
        } catch {
            let alert = NSAlert()
            alert.messageText = "RVLC could not start its media engine"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure libmpv is installed (brew install mpv)."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let library = MediaLibrary(storeURL: dataDir?.appendingPathComponent("library.json") ?? MediaLibrary.defaultStoreURL())
        controller = PlayerController(
            player: player, preferences: preferences, library: library,
            cacheDirectory: dataDir?.appendingPathComponent("Subtitle Preview", isDirectory: true))
        let video = MPVVideoView(player: player)
        video.onRenderFailure = { [weak self] message in
            self?.controller.osd.send("Video output unavailable: \(message)")
        }
        videoView = video
        mainWindow = MainWindowController(controller: controller, videoView: video)
        mainWindow.onShowSettings = { [weak self] in self?.showSettings() }

        router = KeyboardRouter(controller: controller)
        router.isEligibleWindow = { [weak self] window in
            window === self?.mainWindow.window || window === self?.mainWindow.editorWindow
        }
        router.start()

        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange, object: preferences).receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                let key = note.userInfo?["key"] as? String
                if key == Preferences.Key.theme.rawValue { Theme.apply(preferences.theme) }
                if key == Preferences.Key.keyBindings.rawValue || key == Preferences.Key.theme.rawValue { self.refreshMenuSoon() }
            }.store(in: &bag)
        // Keep Open Recent, Repeat and Appearance menus current.
        controller.player.$currentURL.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuSoon() }.store(in: &bag)
        controller.$playlist.map(\.repeatMode).removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuSoon() }.store(in: &bag)
        controller.libraryChanged.receive(on: RunLoop.main).sink { [weak self] in self?.refreshMenuSoon() }.store(in: &bag)
        controller.confirmDiscardEdits = { action in Self.confirmDiscard(action) }

        buildMenu()
        mainWindow.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Files passed on the command line (development) or via Finder before launch.
        let cliFiles = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let toOpen = pendingOpen + cliFiles
        pendingOpen = []
        if !toOpen.isEmpty { controller.open(toOpen) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingOpen += urls
            return
        }
        controller.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.commitPendingEdits?()
        guard let controller, controller.subtitles.hasEdits else { return .terminateNow }
        return Self.confirmDiscard("quit RVLC") ? .terminateNow : .terminateCancel
    }

    /// Asks before discarding unexported subtitle edits.
    static func confirmDiscard(_ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard your subtitle edits?"
        alert.informativeText =
            "You have edited subtitle lines that have not been exported. If you \(action), the edits will be lost. Use Export in Subtitle Studio to keep them; the original file is never changed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Edits")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        router?.stop()
        controller?.prepareForTermination()
        // Order matters: free the render context before destroying libmpv.
        videoView?.uninitialize()
        controller?.player.shutdown()
    }

    // MARK: Windows

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(controller: controller)
            // Rebuilt on next open so every control reflects the current settings (e.g. after a reset).
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: settings?.window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if let observer = self.settingsCloseObserver { NotificationCenter.default.removeObserver(observer) }
                self.settingsCloseObserver = nil
                self.settings = nil
            }
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: """
                Reimagined VLC.

                Play anything. Fix everything.

                A free, open-source media player with Smart Subtitle Sync. Everything runs locally: no account, no telemetry.

                Playback by libmpv (GPL-2.0-or-later / LGPL-2.1-or-later) and FFmpeg. Licensed under the GNU GPL v3 or later.
                """, attributes: [.font: Theme.captionFont, .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "RVLC",
            .applicationIcon: AppIcon.image(size: 128),
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? RVLCVersion.string,
            .credits: credits,
        ])
    }

    // MARK: Menu

    func buildMenu() {
        let c = controller!
        let map = c.keyMap
        let main = NSMenu()
        func actionItem(_ action: PlayerAction, title: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title ?? action.title) { c.perform(action) }
            item.showShortcutHint(map.combos(for: action).first)
            return item
        }
        func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], handler: @escaping () -> Void)
            -> NSMenuItem
        {
            let i = NSMenuItem(title: title, handler: handler)
            i.keyEquivalent = key
            i.keyEquivalentModifierMask = mods
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            return i
        }

        // App
        let appMenu = submenu(
            "RVLC",
            [
                item("About RVLC", "") { [weak self] in self?.showAbout() },
                .separator(),
                item("Settings…", ",") { [weak self] in self?.showSettings() },
                .separator(),
                NSMenuItem(title: "Hide RVLC", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
                {
                    let i = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
                    i.keyEquivalentModifierMask = [.command, .option]
                    return i
                }(),
                NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
                .separator(),
                NSMenuItem(title: "Quit RVLC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
            ])
        main.addItem(appMenu)

        // File
        let recent = c.library.recent(limit: 20).filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(10).map { record in
            NSMenuItem(title: record.title) { c.open([record.url]) }
        }
        main.addItem(
            submenu(
                "File",
                [
                    item("Open File…", "o") { [weak self] in self?.mainWindow.openFiles() },
                    item("Open Folder…", "o", [.command, .shift]) { [weak self] in self?.mainWindow.openFolder() },
                    submenu(
                        "Open Recent", recent.isEmpty ? [NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")] : recent),
                    .separator(),
                    item("Load Subtitle File…", "l") { [weak self] in self?.mainWindow.openSubtitle() },
                    item("Load External Audio…", "l", [.command, .shift]) { [weak self] in self?.mainWindow.openExternalAudio() },
                    .separator(),
                    item("File Info", "i") { [weak self] in
                        guard let self, let window = self.mainWindow.window, c.player.currentURL != nil else { return }
                        FileInfoPresenter.present(record: nil, player: c, in: window)
                    },
                    .separator(),
                    NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
                ]))

        // Edit (standard text editing so fields support copy/paste/undo)
        main.addItem(
            submenu(
                "Edit",
                [
                    NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
                    {
                        let i = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
                        i.keyEquivalentModifierMask = [.command, .shift]
                        return i
                    }(),
                    .separator(),
                    NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                    NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                    NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                    NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
                ]))

        // Playback
        let speeds = PlayerController.speedSteps.map { s in NSMenuItem(title: String(format: "%g×", s)) { c.setSpeed(s) } }
        let repeatItems = RepeatMode.allCases.map { mode -> NSMenuItem in
            let i = NSMenuItem(title: ["off": "Off", "all": "Repeat Playlist", "one": "Repeat Current Item"][mode.rawValue]!) {
                c.setRepeatMode(mode)
            }
            i.state = c.playlist.repeatMode == mode ? .on : .off
            return i
        }
        main.addItem(
            submenu(
                "Playback",
                [
                    actionItem(.playPause), actionItem(.stop), .separator(),
                    item("Go to Time…", "j") { [weak self] in self?.mainWindow.showGoToTime() },
                    actionItem(.previous), actionItem(.next), .separator(),
                    actionItem(.seekBackward), actionItem(.seekForward), actionItem(.seekBackwardLarge), actionItem(.seekForwardLarge),
                    actionItem(.frameBackStep), actionItem(.frameStep), .separator(),
                    actionItem(.speedDown), actionItem(.speedUp), actionItem(.speedReset), submenu("Speed", speeds), .separator(),
                    actionItem(.volumeUp), actionItem(.volumeDown), actionItem(.mute), .separator(),
                    submenu("Repeat", repeatItems),
                ]))

        // Subtitles
        main.addItem(
            submenu(
                "Subtitles",
                [
                    item("Load Subtitle File…", "l") { [weak self] in self?.mainWindow.openSubtitle() },
                    actionItem(.toggleSubtitles), actionItem(.cycleSubtitle), .separator(),
                    actionItem(.subtitleEarlier), actionItem(.subtitleLater), actionItem(.subtitleReset), actionItem(.setSyncPoint),
                    .separator(),
                    item("Subtitle Studio", "3") { [weak self] in self?.mainWindow.showPanel(.subtitles) },
                    item("Subtitle Editor…", "e") { [weak self] in self?.mainWindow.showEditor() },
                    item("Analyze Audio for Sync") { [weak self] in
                        self?.mainWindow.showPanel(.subtitles)
                        c.subtitles.analyzeAudio()
                    },
                ]))

        // Audio
        main.addItem(
            submenu(
                "Audio",
                [
                    actionItem(.cycleAudio),
                    item("Load External Audio…", "l", [.command, .shift]) { [weak self] in self?.mainWindow.openExternalAudio() },
                    .separator(),
                    actionItem(.audioEarlier), actionItem(.audioLater), actionItem(.audioReset), .separator(),
                    item("Audio Sync Lab", "4") { [weak self] in self?.mainWindow.showPanel(.audio) },
                ]))

        // View
        let themeItems = ThemePreference.allCases.map { theme -> NSMenuItem in
            let i = NSMenuItem(title: theme.title) { c.preferences.theme = theme }
            i.state = c.preferences.theme == theme ? .on : .off
            return i
        }
        main.addItem(
            submenu(
                "View",
                [
                    item("Toggle Sidebar", "s", [.command, .control]) { [weak self] in self?.mainWindow.toggleSidebar() },
                    item("Playlist", "1") { [weak self] in self?.mainWindow.showPanel(.playlist) },
                    item("Library", "2") { [weak self] in self?.mainWindow.showPanel(.library) },
                    item("Subtitle Studio", "3") { [weak self] in self?.mainWindow.showPanel(.subtitles) },
                    item("Audio Sync Lab", "4") { [weak self] in self?.mainWindow.showPanel(.audio) },
                    item("Picture & Sound", "5") { [weak self] in self?.mainWindow.showPanel(.adjust) },
                    .separator(),
                    item("Toggle Full Screen", "f", [.command, .control]) { c.perform(.toggleFullscreen) },
                    submenu("Appearance", themeItems),
                ]))

        // Window
        let windowMenu = submenu(
            "Window",
            [
                NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
                NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
                .separator(),
                NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""),
            ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        // Help
        main.addItem(
            submenu(
                "Help",
                [
                    actionItem(.showShortcuts, title: "Keyboard Shortcuts"),
                    item("Privacy") { [weak self] in
                        let alert = NSAlert()
                        alert.messageText = "Your media stays on your Mac"
                        alert.informativeText =
                            "RVLC has no account and no telemetry, and makes no network requests. Media, subtitles and audio analysis are processed locally. Playback history, resume positions and per-file sync settings are stored in ~/Library/Application Support/RVLC and can be cleared in Settings."
                        if let window = self?.mainWindow.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                    },
                ]))
        NSApp.mainMenu = main
    }

    private var recentWork: DispatchWorkItem?
    private func refreshMenuSoon() {
        recentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.buildMenu() }
        recentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

public enum RVLCVersion {
    public static let string = "0.1.0"
}
