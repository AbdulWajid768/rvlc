import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Shown before any media is opened.
final class EmptyStateView: NSView {
    var onOpenFile: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenRecent: ((String) -> Void)?
    private let recentStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let logo = NSImageView(image: AppIcon.image(size: 96))
        logo.setAccessibilityLabel("RVLC, Reimagined VLC")
        let title = makeLabel("RVLC", font: Theme.font(26, .bold), color: .white)
        let meaning = makeLabel("Reimagined VLC", font: Theme.font(15, .medium), color: NSColor.white.withAlphaComponent(0.82))
        let tagline = makeLabel("Play anything. Fix everything.", font: Theme.font(14), color: NSColor.white.withAlphaComponent(0.65))
        let open = makeButton("Open File…", symbol: .file, tip: "Open a video or audio file (⌘O)") { [weak self] in self?.onOpenFile?() }
        open.keyEquivalent = "\r"
        open.controlSize = .large
        let folder = makeButton("Open Folder…", symbol: .folder, tip: "Add every media file in a folder to the playlist (⇧⌘O)") {
            [weak self] in self?.onOpenFolder?()
        }
        folder.controlSize = .large
        let buttons = hStack([open, folder], spacing: Theme.spaceS)
        let hint = makeLabel(
            "or drop video, audio or subtitle files here", font: Theme.captionFont, color: NSColor.white.withAlphaComponent(0.5))
        recentStack.orientation = .vertical
        recentStack.alignment = .centerX
        recentStack.spacing = 2

        let stack = NSStackView(views: [logo, title, meaning, tagline, buttons, hint, recentStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.spaceS
        stack.setCustomSpacing(Theme.spaceM, after: logo)
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(Theme.spaceXL, after: tagline)
        stack.setCustomSpacing(Theme.spaceXL, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.spaceL),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Theme.spaceS),
        ])
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setRecent(_ records: [MediaRecord]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let available = records.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(4)
        guard !available.isEmpty else { return }
        recentStack.addArrangedSubview(SectionLabel("Recently played"))
        for record in available {
            var title = record.title
            if let p = record.progress, p > 0.01 { title += "  ·  \(Int(p * 100))% watched" }
            let button = makeButton(title, symbol: .clock, style: .inline) { [weak self] in self?.onOpenRecent?(record.path) }
            button.toolTip = "Play \(record.path)"
            recentStack.addArrangedSubview(button)
        }
    }
}

/// Shown when the engine reports a load or playback error.
final class ErrorOverlayView: NSView {
    private let message = makeLabel("", font: Theme.bodyFont, color: NSColor.white.withAlphaComponent(0.75), wraps: true)
    var onOpenAnother: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        let icon = NSImageView(image: Symbol.warning.image("Error", size: 34))
        icon.contentTintColor = Theme.warning
        let title = makeLabel("This file can’t be played", font: Theme.font(17, .semibold), color: .white)
        message.alignment = .center
        message.preferredMaxLayoutWidth = 380
        let open = makeButton("Open Another File…", tip: "Choose a different file to play") { [weak self] in self?.onOpenAnother?() }
        let dismiss = makeButton("Dismiss", tip: "Close this message and return to the start screen") { [weak self] in self?.onDismiss?() }
        let stack = NSStackView(views: [icon, title, message, hStack([dismiss, open])])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.spaceS
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        message.stringValue = text
        setAccessibilityLabel("Error: \(text)")
    }
}

/// Black stage that hosts the video surface and overlays. Accepts file drops.
final class VideoStageView: NSView {
    var onDrop: (([URL], Bool) -> Void)?
    /// A click on the picture, fired `singleClickDelay` after it unless a second click follows.
    var onSingleClick: (() -> Void)?
    /// A double-click. `followsSingleClick` is true when its first click already
    /// fired `onSingleClick` (a slow double-click), which the handler should then undo.
    var onDoubleClick: ((_ followsSingleClick: Bool) -> Void)?
    var onMouseActivity: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var pendingSingleClick: DispatchWorkItem?
    private var singleClickFired = false
    /// Long enough for a quick double-click never to reach `onSingleClick`, short
    /// enough that a single click still feels immediate.
    var singleClickDelay: TimeInterval { min(0.25, NSEvent.doubleClickInterval) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.videoBackground.cgColor
        registerForDraggedTypes([.fileURL])
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onMouseActivity?() }
    override func mouseEntered(with event: NSEvent) { onMouseActivity?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseActivity?()
        // Rapid double-clicks in a row (zoom in, then out) arrive as one sequence
        // with click counts 1, 2, 3, 4…: every second click is a double-click, and
        // the odd clicks after the first only start the next one.
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        if event.clickCount >= 2, event.clickCount.isMultiple(of: 2) {
            onDoubleClick?(singleClickFired)
        }
        singleClickFired = false
        mouseDownLocation = event.clickCount == 1 ? event.locationInWindow : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1, let start = mouseDownLocation else { return }
        mouseDownLocation = nil
        // A drag is not a click.
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 5 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSingleClick = nil
            self.singleClickFired = true
            self.onSingleClick?()
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + singleClickDelay, execute: work)
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        // Holding Option while dropping an audio file adds it as an external audio track.
        onDrop?(files, NSEvent.modifierFlags.contains(.option))
        return true
    }
}

/// Main player screen: video stage, overlays and the control bar.
final class PlayerViewController: NSViewController {
    let controller: PlayerController
    let controlBar: ControlBarView
    let stage = VideoStageView()
    let emptyState = EmptyStateView()
    let errorOverlay = ErrorOverlayView()
    let osdView = OSDView()
    private let spinner = NSProgressIndicator()
    private(set) var videoView: NSView?
    private var bag = Set<AnyCancellable>()

    private var stageBottomToBar: NSLayoutConstraint!
    private var stageBottomToView: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!
    private var barTrailing: NSLayoutConstraint!
    private var barBottom: NSLayoutConstraint!
    private(set) var isOverlayMode = false
    private var hideWork: DispatchWorkItem?
    /// Playback state before the latest click on the video, so a double-click can undo it.
    private var statusBeforeClick: PlaybackStatus?

    var onOpenFile: (() -> Void)?
    var onOpenFolder: (() -> Void)?

    init(controller: PlayerController, videoView: NSView?) {
        self.controller = controller
        controlBar = ControlBarView(controller: controller)
        self.videoView = videoView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        view = root
        root.addSubview(stage)
        root.addSubview(controlBar)
        controlBar.timeline.overlayHost = root
        if let videoView {
            videoView.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(videoView)
            pin(videoView, to: stage)
        }
        for overlay in [emptyState, errorOverlay] as [NSView] {
            stage.addSubview(overlay)
            pin(overlay, to: stage)
        }
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Loading")
        stage.addSubview(spinner)
        stage.addSubview(osdView)

        stageBottomToBar = stage.bottomAnchor.constraint(equalTo: controlBar.topAnchor)
        stageBottomToView = stage.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        barLeading = controlBar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        barTrailing = controlBar.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        barBottom = controlBar.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stageBottomToBar, barLeading, barTrailing, barBottom,
            spinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            osdView.topAnchor.constraint(equalTo: stage.safeAreaLayoutGuide.topAnchor, constant: Theme.spaceL),
            osdView.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: Theme.spaceL),
            osdView.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor, constant: -Theme.spaceL),
        ])

        emptyState.onOpenFile = { [weak self] in self?.onOpenFile?() }
        emptyState.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        emptyState.onOpenRecent = { [weak self] path in self?.controller.open([URL(fileURLWithPath: path)]) }
        errorOverlay.onOpenAnother = { [weak self] in self?.onOpenFile?() }
        errorOverlay.onDismiss = { [weak self] in
            self?.controller.clearError()
            self?.controller.stop()
        }
        stage.onDrop = { [weak self] urls, asAudio in
            guard let self else { return }
            if asAudio, let audio = urls.first(where: { MediaLibrary.audioExtensions.contains($0.pathExtension.lowercased()) }) {
                self.controller.loadExternalAudio(audio)
            } else {
                self.controller.open(urls)
            }
        }
        // One click on the picture plays or pauses (only while a file is open, so
        // clicks on the start screen and error message do nothing).
        stage.onSingleClick = { [weak self] in
            guard let self, self.controller.player.status.hasMedia else {
                self?.statusBeforeClick = nil
                return
            }
            self.statusBeforeClick = self.controller.player.status
            self.controller.perform(.playPause)
        }
        // A double-click toggles full screen. If it was slow enough for its first
        // click to play/pause already, playback is put back the way it was; the
        // state is restored explicitly because the engine reports changes asynchronously.
        stage.onDoubleClick = { [weak self] followsSingleClick in
            guard let self else { return }
            if followsSingleClick, let before = self.statusBeforeClick {
                if before == .playing { self.controller.player.play() } else { self.controller.player.pause() }
            }
            self.statusBeforeClick = nil
            self.controller.perform(.toggleFullscreen)
        }
        stage.onMouseActivity = { [weak self] in self?.revealControls() }
        bind()
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    private func bind() {
        controller.player.$status.receive(on: RunLoop.main).sink { [weak self] status in
            self?.render(status)
        }.store(in: &bag)
        controller.osd.receive(on: RunLoop.main).sink { [weak self] message in self?.osdView.show(message) }.store(in: &bag)
        controller.$lastError.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.render(self.controller.player.status)
        }.store(in: &bag)
        render(controller.player.status)
    }

    func refreshRecent() {
        emptyState.setRecent(controller.library.recent(limit: 8))
    }

    func render(_ status: PlaybackStatus) {
        let showEmpty: Bool
        switch status {
        case .idle: showEmpty = true
        default: showEmpty = false
        }
        if case .error(let message) = status {
            errorOverlay.show(message)
            errorOverlay.isHidden = false
        } else {
            errorOverlay.isHidden = true
        }
        if showEmpty { refreshRecent() }
        emptyState.isHidden = !showEmpty
        videoView?.isHidden = showEmpty || !errorOverlay.isHidden
        if status == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if status != .playing { revealControls() } else { scheduleHide() }
        controlBar.refreshState()
    }

    // MARK: Full screen control overlay

    func setOverlayMode(_ overlay: Bool) {
        isOverlayMode = overlay
        stageBottomToBar.isActive = !overlay
        stageBottomToView.isActive = overlay
        barLeading.constant = overlay ? 80 : 0
        barTrailing.constant = overlay ? -80 : 0
        barBottom.constant = overlay ? -24 : 0
        controlBar.setFullscreenAppearance(overlay)
        if overlay {
            scheduleHide()
        } else {
            hideWork?.cancel()
            controlBar.alphaValue = 1
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    func revealControls() {
        guard isOverlayMode else { return }
        hideWork?.cancel()
        if controlBar.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.15; controlBar.animator().alphaValue = 1
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        guard isOverlayMode else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOverlayMode, self.controller.player.status == .playing else { return }
            let mouse = self.controlBar.convert(self.view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            if self.controlBar.bounds.contains(mouse) { self.scheduleHide(); return }
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.4; self.controlBar.animator().alphaValue = 0
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
