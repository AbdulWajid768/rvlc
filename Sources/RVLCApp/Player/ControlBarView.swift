import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Bottom transport bar. Every button triggers exactly one controller action;
/// its appearance is derived from published engine state.
final class ControlBarView: NSVisualEffectView {
    private let controller: PlayerController
    private var player: MPVPlayer { controller.player }
    private var bag = Set<AnyCancellable>()

    let timeline = TimelineSlider()
    private let elapsedLabel = ClickableLabel(labelWithString: "0:00")
    private let durationLabel = ClickableLabel(labelWithString: "0:00")
    private var isFullscreenAppearance = false
    private(set) var playButton: IconButton!
    private(set) var stopButton: IconButton!
    private(set) var previousButton: IconButton!
    private(set) var nextButton: IconButton!
    private(set) var seekBackButton: IconButton!
    private(set) var seekForwardButton: IconButton!
    private(set) var muteButton: IconButton!
    private(set) var fullscreenButton: IconButton!
    private(set) var subtitleButton: IconButton!
    private(set) var audioButton: IconButton!
    private(set) var sidebarButton: IconButton!
    let volumeSlider = NSSlider()
    let speedButton = NSButton(title: "1×", target: nil, action: nil)
    private(set) var buttonRow: NSStackView!
    private var showRemaining = false

    /// Hooks provided by the window controller.
    var onToggleSidebar: (() -> Void)?
    var onShowPanel: ((SidebarTab) -> Void)?
    var onOpenSubtitle: (() -> Void)?
    var onOpenAudio: (() -> Void)?
    var onGoToTime: (() -> Void)?

    init(controller: PlayerController) {
        self.controller = controller
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        translatesAutoresizingMaskIntoConstraints = false
        // Expose the bar as a labelled group so VoiceOver users can navigate it as a unit.
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Playback controls")
        build()
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func shortcut(_ action: PlayerAction) -> KeyCombo? { controller.keyMap.combos(for: action).first }

    private func build() {
        for label in [elapsedLabel, durationLabel] {
            label.font = Theme.monoDigits
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        durationLabel.alignment = .right
        durationLabel.toolTip = "Click to toggle remaining time"
        durationLabel.onClick = { [weak self] in self?.toggleRemaining() }
        elapsedLabel.toolTip = "Go to Time… (⌘J)"
        elapsedLabel.setAccessibilityLabel("Elapsed time")
        elapsedLabel.accessibilityHelpText = "Opens Go to Time"
        elapsedLabel.onClick = { [weak self] in
            guard let self, self.player.status.hasMedia else { return }
            self.onGoToTime?()
        }
        timeline.onScrub = { [weak self] seconds, final in
            guard let self else { return }
            self.player.seek(seconds, exact: final)
            self.elapsedLabel.stringValue = Timecode.formatClock(seconds: seconds)
        }
        let timelineRow = hStack([elapsedLabel, timeline, durationLabel], spacing: Theme.spaceS)

        let c = controller
        previousButton = IconButton(.previous, label: "Previous") { c.perform(.previous) }
        seekBackButton = IconButton(.seekBack, label: "Seek back") { c.perform(.seekBackward) }
        playButton = IconButton(.play, label: "Play", size: 20) { c.perform(.playPause) }
        seekForwardButton = IconButton(.seekForward, label: "Seek forward") { c.perform(.seekForward) }
        nextButton = IconButton(.next, label: "Next") { c.perform(.next) }
        stopButton = IconButton(.stop, label: "Stop") { c.perform(.stop) }
        muteButton = IconButton(.volumeHigh, label: "Mute") { c.perform(.mute) }
        fullscreenButton = IconButton(.fullscreen, label: "Full Screen") { c.perform(.toggleFullscreen) }
        subtitleButton = IconButton(.subtitles, label: "Subtitles") { [weak self] in self?.showSubtitleMenu() }
        audioButton = IconButton(.audioTrack, label: "Audio") { [weak self] in self?.showAudioMenu() }
        sidebarButton = IconButton(.sidebar, label: "Show Sidebar") { [weak self] in self?.onToggleSidebar?() }
        playButton.widthAnchor.constraint(equalToConstant: 36).isActive = true

        subtitleButton.setToolTip("Subtitle tracks and Subtitle Studio", shortcut: nil)
        audioButton.setToolTip("Audio tracks and Audio Sync Lab", shortcut: nil)
        sidebarButton.setToolTip("Show or hide the sidebar", shortcut: KeyCombo("s", [.command, .control]))

        let volumeCell = SlimSliderCell()
        volumeCell.knobDiameter = 10
        volumeSlider.cell = volumeCell
        volumeSlider.minValue = 0
        volumeSlider.maxValue = controller.preferences.maxVolume
        volumeSlider.doubleValue = controller.preferences.volume
        volumeSlider.isContinuous = true
        volumeSlider.refusesFirstResponder = true
        volumeSlider.toolTip = "Volume"
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.widthAnchor.constraint(equalToConstant: 84).isActive = true
        volumeSlider.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.setVolume(self.volumeSlider.doubleValue, showOSD: false)
        }

        speedButton.bezelStyle = .inline
        speedButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        speedButton.refusesFirstResponder = true
        speedButton.toolTip = "Playback speed"
        speedButton.setAccessibilityLabel("Playback speed")
        speedButton.onAction { [weak self] _ in self?.showSpeedMenu() }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let row = NSStackView(views: [
            previousButton, seekBackButton, playButton, seekForwardButton, nextButton, stopButton,
            divider, muteButton, volumeSlider, flexibleSpacer(),
            speedButton, subtitleButton, audioButton, sidebarButton, fullscreenButton,
        ])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        // Allow the row to be narrower than its contents so low-priority views detach.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // Responsive layout: least important controls detach first in narrow windows.
        row.setVisibilityPriority(.detachOnlyIfNecessary, for: playButton)
        row.setVisibilityPriority(.detachOnlyIfNecessary, for: fullscreenButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 900), for: muteButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 850), for: subtitleButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 850), for: audioButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 800), for: seekBackButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 800), for: seekForwardButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 700), for: sidebarButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: volumeSlider)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 500), for: speedButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 400), for: previousButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 400), for: nextButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 300), for: stopButton)
        row.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 300), for: divider)
        buttonRow = row

        let column = NSStackView(views: [timelineRow, row])
        column.orientation = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.spaceM),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.spaceM),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.spaceS),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.spaceS),
            timelineRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            heightAnchor.constraint(equalToConstant: Theme.controlBarHeight),
        ])
    }

    private func bind() {
        player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshState() }.store(in: &bag)
        player.$position.receive(on: RunLoop.main).sink { [weak self] pos in
            guard let self else { return }
            self.timeline.setPosition(pos)
            if !self.timeline.isDragging { self.elapsedLabel.stringValue = Timecode.formatClock(seconds: pos) }
            if self.showRemaining { self.updateDurationLabel() }
        }.store(in: &bag)
        player.$duration.receive(on: RunLoop.main).sink { [weak self] d in
            self?.timeline.duration = d
            self?.updateDurationLabel()
        }.store(in: &bag)
        player.$volume.combineLatest(player.$isMuted).receive(on: RunLoop.main).sink { [weak self] volume, muted in
            guard let self else { return }
            self.volumeSlider.doubleValue = volume
            self.muteButton.symbol = muted || volume == 0 ? .volumeMuted : volume < 34 ? .volumeLow : volume < 67 ? .volumeMid : .volumeHigh
            self.muteButton.setToolTip(muted ? "Unmute" : "Mute", shortcut: self.shortcut(.mute))
            self.volumeSlider.setAccessibilityValue("\(Int(volume)) percent\(muted ? ", muted" : "")")
        }.store(in: &bag)
        player.$speed.receive(on: RunLoop.main).sink { [weak self] speed in
            self?.speedButton.title = String(format: "%g×", (speed * 100).rounded() / 100)
        }.store(in: &bag)
        controller.$playlist.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshState() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.volumeSlider.maxValue = self.controller.preferences.maxVolume
            self.refreshTooltips()
        }.store(in: &bag)
        refreshTooltips()
        // Apply the current state synchronously so the bar never shows stale defaults.
        timeline.duration = player.duration
        timeline.setPosition(player.position)
        refreshState()
    }

    func refreshState() {
        let status = player.status
        let hasMedia = status.hasMedia
        playButton.symbol = status == .playing ? .pause : .play
        playButton.setToolTip(status == .playing ? "Pause" : "Play", shortcut: shortcut(.playPause))
        playButton.isEnabled = hasMedia || !controller.playlist.isEmpty
        for button in [seekBackButton, seekForwardButton, stopButton, subtitleButton, audioButton] { button?.isEnabled = hasMedia }
        previousButton.isEnabled = hasMedia || !controller.playlist.isEmpty
        nextButton.isEnabled = controller.playlist.nextIndex() != nil
        speedButton.isEnabled = hasMedia
        timeline.isEnabled = hasMedia && player.duration > 0
        if !hasMedia {
            timeline.setPosition(0)
            elapsedLabel.stringValue = "0:00"
        }
    }

    /// Tooltips include the current key bindings, and the seek icons show the seek step.
    func refreshTooltips() {
        let step = controller.preferences.seekStepSeconds
        seekBackButton.symbol = Symbol.seek(forward: false, seconds: step)
        seekForwardButton.symbol = Symbol.seek(forward: true, seconds: step)
        seekBackButton.setToolTip("Back \(step) s", shortcut: shortcut(.seekBackward))
        seekForwardButton.setToolTip("Forward \(step) s", shortcut: shortcut(.seekForward))
        playButton.setToolTip(player.status == .playing ? "Pause" : "Play", shortcut: shortcut(.playPause))
        previousButton.setToolTip("Previous", shortcut: shortcut(.previous))
        nextButton.setToolTip("Next", shortcut: shortcut(.next))
        stopButton.setToolTip("Stop", shortcut: shortcut(.stop))
        muteButton.setToolTip(player.isMuted ? "Unmute" : "Mute", shortcut: shortcut(.mute))
        fullscreenButton.setToolTip(isFullscreenAppearance ? "Exit Full Screen" : "Full Screen", shortcut: shortcut(.toggleFullscreen))
    }

    func setFullscreenAppearance(_ fullscreen: Bool) {
        isFullscreenAppearance = fullscreen
        fullscreenButton.symbol = fullscreen ? .exitFullscreen : .fullscreen
        fullscreenButton.setToolTip(fullscreen ? "Exit Full Screen" : "Full Screen", shortcut: shortcut(.toggleFullscreen))
        material = fullscreen ? .hudWindow : .titlebar
        appearance = fullscreen ? NSAppearance(named: .darkAqua) : nil
        wantsLayer = true
        layer?.cornerRadius = fullscreen ? 12 : 0
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebarButton.contentTintColor = visible ? .controlAccentColor : .labelColor
        sidebarButton.setToolTip(visible ? "Hide Sidebar" : "Show Sidebar", shortcut: KeyCombo("s", [.command, .control]))
    }

    private func toggleRemaining() {
        showRemaining.toggle()
        updateDurationLabel()
    }

    private func updateDurationLabel() {
        let d = player.duration
        durationLabel.stringValue =
            showRemaining && d > 0 ? "−" + Timecode.formatClock(seconds: max(0, d - player.position)) : Timecode.formatClock(seconds: d)
        durationLabel.setAccessibilityLabel(showRemaining ? "Remaining time" : "Duration")
    }

    // MARK: Menus

    private func popUp(_ menu: NSMenu, from view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    func showSubtitleMenu() {
        let menu = NSMenu()
        let tracks = player.tracks(.sub)
        let off = NSMenuItem(title: "Off") { [weak self] in self?.player.selectTrack(.sub, id: nil) }
        off.state = tracks.contains { $0.isSelected } ? .off : .on
        menu.addItem(off)
        for track in tracks {
            let item = NSMenuItem(title: track.displayName) { [weak self] in self?.player.selectTrack(.sub, id: track.id) }
            item.state = track.isSelected ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Load Subtitle File…") { [weak self] in self?.onOpenSubtitle?() })
        menu.addItem(NSMenuItem(title: "Subtitle Studio…") { [weak self] in self?.onShowPanel?(.subtitles) })
        popUp(menu, from: subtitleButton)
    }

    func showAudioMenu() {
        let menu = NSMenu()
        for track in player.tracks(.audio) {
            let item = NSMenuItem(title: track.displayName) { [weak self] in self?.player.selectTrack(.audio, id: track.id) }
            item.state = track.isSelected ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No audio tracks", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Load External Audio…") { [weak self] in self?.onOpenAudio?() })
        menu.addItem(NSMenuItem(title: "Audio Sync Lab…") { [weak self] in self?.onShowPanel?(.audio) })
        popUp(menu, from: audioButton)
    }

    func showSpeedMenu() {
        let menu = NSMenu()
        let current = player.speed
        for speed in PlayerController.speedSteps {
            let item = NSMenuItem(title: String(format: "%g×", speed)) { [weak self] in self?.controller.setSpeed(speed) }
            item.state = abs(speed - current) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: speedButton)
    }
}

/// A label that can be clicked, and pressed by VoiceOver like a button.
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    var accessibilityHelpText = "Toggles between total duration and remaining time"

    override func accessibilityHelp() -> String? { accessibilityHelpText }
}
