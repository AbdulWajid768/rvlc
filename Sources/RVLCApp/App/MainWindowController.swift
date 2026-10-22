import AppKit
import Combine
import RVLCCore
import RVLCEngine
import UniformTypeIdentifiers

/// The player window. It is borderless in full screen, so it must still be
/// allowed to become key (for the keyboard) and main.
final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The player window: video and controls on the left, tool sidebar on the right.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let controller: PlayerController
    let playerVC: PlayerViewController
    let sidebarVC: SidebarViewController
    let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var bag = Set<AnyCancellable>()
    private(set) var isFullscreen = false
    private var editor: SubtitleEditorWindowController?
    private var shortcutsWindow: ShortcutsWindowController?
    var onShowSettings: (() -> Void)?

    init(controller: PlayerController, videoView: NSView?) {
        self.controller = controller
        playerVC = PlayerViewController(controller: controller, videoView: videoView)
        sidebarVC = SidebarViewController(controller: controller)
        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "RVLC"
        window.titlebarAppearsTransparent = false
        window.minSize = Theme.minimumWindowSize
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let playerItem = NSSplitViewItem(viewController: playerVC)
        playerItem.minimumThickness = 360
        playerItem.holdingPriority = .init(240)
        sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 300
        sidebarItem.maximumThickness = 520
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.isCollapsed = !controller.preferences.sidebarVisible
        split.addSplitViewItem(playerItem)
        split.addSplitViewItem(sidebarItem)
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "RVLCMainSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }

        wire()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        playerVC.onOpenFile = { [weak self] in self?.openFiles() }
        playerVC.onOpenFolder = { [weak self] in self?.openFolder() }
        let bar = playerVC.controlBar
        bar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        bar.onShowPanel = { [weak self] tab in self?.showPanel(tab) }
        bar.onOpenSubtitle = { [weak self] in self?.openSubtitle() }
        bar.onOpenAudio = { [weak self] in self?.openExternalAudio() }
        bar.onGoToTime = { [weak self] in self?.showGoToTime() }
        bar.setSidebarVisible(!sidebarItem.isCollapsed)
        sidebarVC.onOpenFiles = { [weak self] in self?.openFiles() }
        sidebarVC.onOpenSubtitle = { [weak self] in self?.openSubtitle() }
        sidebarVC.onOpenAudio = { [weak self] in self?.openExternalAudio() }
        sidebarVC.onOpenEditor = { [weak self] in self?.showEditor() }

        controller.fullscreenRequests.receive(on: RunLoop.main).sink { [weak self] request in
            guard let self else { return }
            self.setFullscreen(request ?? !self.isFullscreen)
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitInstantFullscreenToScreen() }.store(in: &bag)
        controller.showShortcutsRequests.receive(on: RunLoop.main).sink { [weak self] in self?.showShortcuts() }.store(in: &bag)
        controller.player.$currentURL.combineLatest(controller.player.$mediaTitle).receive(on: RunLoop.main).sink {
            [weak self] url, title in
            guard let window = self?.window else { return }
            window.title = url == nil ? "RVLC" : (title?.isEmpty == false ? title! : url!.lastPathComponent)
            window.representedURL = url
        }.store(in: &bag)
    }

    // MARK: Panels

    func toggleSidebar() {
        setSidebarVisible(sidebarItem.isCollapsed)
    }

    func setSidebarVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            sidebarItem.animator().isCollapsed = !visible
        }
        controller.preferences.sidebarVisible = visible
        playerVC.controlBar.setSidebarVisible(visible)
    }

    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    func showPanel(_ tab: SidebarTab) {
        sidebarVC.show(tab)
        if sidebarItem.isCollapsed { setSidebarVisible(true) }
    }

    func showEditor() {
        if editor == nil {
            editor = SubtitleEditorWindowController(controller: controller)
            controller.commitPendingEdits = { [weak self] in self?.editor?.commitEditing() }
        }
        editor?.showWindow(nil)
        editor?.window?.makeKeyAndOrderFront(nil)
    }

    var editorWindow: NSWindow? { editor?.window }

    private var goToTime: GoToTimeSheet?

    /// Opens “Go to Time…” for the current file; the jump is an exact seek.
    func showGoToTime() {
        guard let window, controller.player.status.hasMedia, window.attachedSheet == nil else { return }
        let player = controller.player
        let sheet = GoToTimeSheet(current: player.currentPosition, duration: player.duration) { [weak self] seconds in
            self?.controller.player.seek(seconds)
            self?.controller.osd.send("Go to \(Timecode.formatClock(seconds: seconds))")
        }
        goToTime = sheet
        sheet.present(on: window)
    }

    func showShortcuts() {
        // Rebuilt each time so it reflects the current bindings, but never duplicated.
        shortcutsWindow?.close()
        shortcutsWindow = ShortcutsWindowController(controller: controller)
        shortcutsWindow?.showWindow(nil)
    }

    // MARK: Open panels

    private static var mediaTypes: [UTType] {
        [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2Video, .mp3, .wav]
            + MediaLibrary.videoExtensions.union(MediaLibrary.audioExtensions).compactMap { UTType(filenameExtension: $0) }
    }

    private static var subtitleTypes: [UTType] {
        SubtitleIO.fileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .text) }
    }

    private func runPanel(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
        if let dir = controller.preferences.lastOpenDirectory { panel.directoryURL = dir }
        guard let window else {
            if panel.runModal() == .OK { completion(panel.urls) }
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.controller.preferences.lastOpenDirectory = panel.urls.first?.deletingLastPathComponent()
            completion(panel.urls)
        }
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Open Media"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.mediaTypes + Self.subtitleTypes
        runPanel(panel) { [weak self] urls in self?.controller.open(urls) }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        runPanel(panel) { [weak self] urls in self?.controller.open(urls) }
    }

    func openSubtitle() {
        guard controller.player.status.hasMedia else {
            controller.osd.send("Open a video before adding subtitles")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Load Subtitle File"
        panel.message = "Choose an SRT, WebVTT or ASS/SSA subtitle file. The file itself will not be modified."
        panel.allowedContentTypes = Self.subtitleTypes
        if let media = controller.player.currentURL { panel.directoryURL = media.deletingLastPathComponent() }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.controller.loadSubtitle(url)
            self.showPanel(.subtitles)
        }
    }

    func openExternalAudio() {
        guard controller.player.status.hasMedia else {
            controller.osd.send("Open a video before adding external audio")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Load External Audio"
        panel.allowedContentTypes = [.audio] + MediaLibrary.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        if let media = controller.player.currentURL { panel.directoryURL = media.deletingLastPathComponent() }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.controller.loadExternalAudio(url)
            self.showPanel(.audio)
        }
    }

    // MARK: Full screen

    /// Window frame and style to restore when leaving instant full screen.
    private var windowedState: (frame: NSRect, style: NSWindow.StyleMask)?
    var isInstantFullscreen: Bool { windowedState != nil }
    private static let frameAutosaveName = "RVLCMainWindow"

    /// Enters or leaves full screen instantly: the window covers its screen and the
    /// Dock and menu bar auto-hide, without macOS's Spaces animation (during which
    /// the system drops clicks and keys, so zooming in and straight back out with
    /// two quick double-clicks would not work). Native full screen entered with the
    /// green window button is left the native way.
    func setFullscreen(_ on: Bool) {
        guard let window, on != isFullscreen else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        if on {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowedState = (window.frame, window.styleMask)
            // Don't remember the full-screen frame as the window's size.
            window.setFrameAutosaveName("")
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
        } else if let state = windowedState {
            windowedState = nil
            NSApp.presentationOptions = []
            window.styleMask = state.style
            window.setFrame(state.frame, display: true)
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        fullscreenChanged(on)
        window.makeKeyAndOrderFront(nil)
    }

    private func fitInstantFullscreenToScreen() {
        guard isInstantFullscreen, let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func fullscreenChanged(_ on: Bool) {
        isFullscreen = on
        controller.isFullscreen = on
        playerVC.setOverlayMode(on)
    }

    // MARK: NSWindowDelegate

    // Native full screen (the green window button).
    func windowWillEnterFullScreen(_ notification: Notification) { fullscreenChanged(true) }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenChanged(false) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullscreenChanged(false) }

    /// The player window is the app: closing it quits (after the usual checks,
    /// e.g. unexported subtitle edits) instead of leaving audio playing with no window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
