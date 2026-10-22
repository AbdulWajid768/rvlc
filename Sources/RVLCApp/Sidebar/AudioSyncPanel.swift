import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Audio Sync Lab: independent audio delay, track choice and external audio.
final class AudioSyncPanel: NSViewController {
    let controller: PlayerController
    private var player: MPVPlayer { controller.player }
    private var bag = Set<AnyCancellable>()
    var onOpenAudio: (() -> Void)?

    private let scroll = PanelScrollView()
    private let trackPopup = NSPopUpButton()
    private let trackInfo = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
    private var removeExternal: NSButton!
    private var loadExternal: NSButton!
    private var offsetControl: OffsetControl!
    private let stepPopup = NSPopUpButton()
    private let stepKeysLabel = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    private let rememberNote = makeLabel("", font: Theme.captionFont, color: .tertiaryLabelColor, wraps: true)

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = scroll

        let trackCard = CardView(title: "Audio track")
        trackPopup.setAccessibilityLabel("Active audio track")
        trackPopup.toolTip = "Audio track you hear"
        trackPopup.onAction { [weak self] _ in
            guard let self, let id = self.trackPopup.selectedItem?.representedObject as? Int else { return }
            self.player.selectTrack(.audio, id: id)
        }
        loadExternal = makeButton(
            "Load External Audio…", symbol: .headphones, tip: "Play a separate audio file, e.g. a dubbed track, with this video (⇧⌘L)"
        ) { [weak self] in self?.onOpenAudio?() }
        removeExternal = IconButton(.trash, label: "Remove External Audio") { [weak self] in
            guard let self, let t = self.player.selectedTrack(.audio), t.isExternal else { return }
            self.controller.removeExternalAudio(id: t.id)
        }
        removeExternal.toolTip = "Remove the selected external audio track (the file is not changed)"
        trackCard.addFull(trackPopup)
        trackCard.addFull(trackInfo)
        trackCard.addFull(hStack([loadExternal, flexibleSpacer(), removeExternal], spacing: 6))
        trackCard.addFull(
            makeLabel(
                "External audio (e.g. a dubbed track) plays in place of the embedded audio. Tip: hold ⌥ while dropping an audio file onto the video.",
                font: Theme.captionFont, color: .tertiaryLabelColor, wraps: true))
        scroll.add(trackCard)

        let delayCard = CardView(title: "Audio delay")
        offsetControl = OffsetControl(
            wording: .init(
                positive: "Audio plays %@ later than the picture", negative: "Audio plays %@ earlier than the picture",
                zero: "In sync with the file. Use + if you hear voices before lips move, − if after."),
            accessibilityName: "Audio delay"
        ) { [weak self] ms in self?.controller.setAudioDelay(ms) }
        delayCard.addFull(offsetControl)
        for ms in Preferences.stepChoicesMs { stepPopup.addItem(withTitle: "\(ms) ms") }
        stepPopup.controlSize = .small
        stepPopup.setAccessibilityLabel("Keyboard step for audio delay")
        stepPopup.toolTip = "How far each C / V key press moves the audio"
        stepPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.preferences.audioStepMs = Preferences.stepChoicesMs[self.stepPopup.indexOfSelectedItem]
        }
        delayCard.addFull(hStack([stepKeysLabel, stepPopup, flexibleSpacer()], spacing: 6))
        delayCard.addFull(rememberNote)
        scroll.add(delayCard)

        let tips = CardView(title: "How to sync by ear")
        tips.addFull(
            makeLabel(
                """
                1. Find a moment with a sharp sound — a clap, a door, a word starting with “p” or “b”.
                2. Pause and step frame by frame with , and . to see exactly when it happens.
                3. Adjust until sound and picture match, then play to confirm.
                The delay is independent of subtitle timing and is remembered for this file.
                """, font: Theme.captionFont, color: .secondaryLabelColor, wraps: true))
        scroll.add(tips)

        player.$audioDelayMs.receive(on: RunLoop.main).sink { [weak self] ms in self?.offsetControl.setValue(ms, notify: false) }.store(
            in: &bag)
        player.$tracks.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStep() }.store(in: &bag)
        refreshStep()
        refresh()
    }

    private func refreshStep() {
        stepPopup.selectItem(at: Preferences.stepChoicesMs.firstIndex(of: controller.preferences.audioStepMs) ?? 0)
        let map = controller.preferences.keyMap
        let earlier = map.combos(for: .audioEarlier).first?.description ?? "—"
        let later = map.combos(for: .audioLater).first?.description ?? "—"
        stepKeysLabel.stringValue = "Keys \(earlier) / \(later) step"
    }

    private func refresh() {
        let hasMedia = player.status.hasMedia
        trackPopup.removeAllItems()
        let tracks = player.tracks(.audio)
        for track in tracks {
            trackPopup.addItem(withTitle: track.displayName)
            trackPopup.lastItem?.representedObject = track.id
            if track.isSelected { trackPopup.select(trackPopup.lastItem) }
        }
        if tracks.isEmpty { trackPopup.addItem(withTitle: hasMedia ? "No audio" : "No media open") }
        trackPopup.isEnabled = !tracks.isEmpty
        let selected = player.selectedTrack(.audio)
        if let selected {
            var info = "Active: \(selected.displayName)"
            if let rate = selected.sampleRate { info += " · \(rate / 1000) kHz" }
            trackInfo.stringValue = info
        } else {
            trackInfo.stringValue = hasMedia ? "Audio is disabled." : "Open a file to adjust its audio."
        }
        loadExternal.isEnabled = hasMedia
        removeExternal.isEnabled = selected?.isExternal == true
        offsetControl.alphaValue = hasMedia ? 1 : 0.5
        rememberNote.stringValue =
            hasMedia
            ? "Remembered for this file. Positive values delay the audio relative to the video."
            : "Positive values delay the audio relative to the video."
    }
}

/// Picture & Sound: video adjustments and audio enhancements backed by libmpv.
final class AdjustPanel: NSViewController {
    let controller: PlayerController
    private let scroll = PanelScrollView()
    private var bag = Set<AnyCancellable>()
    private var sliders: [WritableKeyPath<VideoAdjustments, Int>: NSSlider] = [:]
    private let aspectPopup = NSPopUpButton()
    private let fitPopup = NSPopUpButton()
    private let eqPopup = NSPopUpButton()
    private let normalize = NSButton(checkboxWithTitle: "Normalize loudness", target: nil, action: nil)
    private let amplify = NSButton(checkboxWithTitle: "Allow volume up to 200%", target: nil, action: nil)
    private let devicePopup = NSPopUpButton()
    private let hwdec = NSButton(checkboxWithTitle: "Hardware decoding", target: nil, action: nil)
    private let hwdecStatus = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = scroll
        let picture = CardView(title: "Picture")
        aspectPopup.addItems(withTitles: VideoAdjustments.Aspect.allCases.map(\.title))
        aspectPopup.setAccessibilityLabel("Aspect ratio")
        aspectPopup.toolTip = "Override the picture’s aspect ratio"
        aspectPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.videoAdjustments.aspect = VideoAdjustments.Aspect.allCases[self.aspectPopup.indexOfSelectedItem]
            self.controller.applyVideoAdjustments()
        }
        fitPopup.addItems(withTitles: VideoAdjustments.Fit.allCases.map(\.title))
        fitPopup.setAccessibilityLabel("Scaling")
        fitPopup.toolTip = "How the picture fills the window"
        fitPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.videoAdjustments.fit = VideoAdjustments.Fit.allCases[self.fitPopup.indexOfSelectedItem]
            self.controller.applyVideoAdjustments()
        }
        var rows: [[NSView]] = [
            [makeLabel("Aspect", font: Theme.captionFont, color: .secondaryLabelColor), aspectPopup],
            [makeLabel("Scaling", font: Theme.captionFont, color: .secondaryLabelColor), fitPopup],
        ]
        for (title, key) in [
            ("Brightness", \VideoAdjustments.brightness), ("Contrast", \.contrast), ("Saturation", \.saturation), ("Gamma", \.gamma),
        ] {
            let slider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
            slider.numberOfTickMarks = 3
            slider.setAccessibilityLabel(title)
            slider.onAction { [weak self] _ in
                guard let self else { return }
                // Snap to neutral near the middle tick.
                var v = Int(slider.doubleValue)
                if abs(v) < 4 { v = 0 }
                self.controller.videoAdjustments[keyPath: key] = v
                self.controller.applyVideoAdjustments()
            }
            sliders[key] = slider
            rows.append([makeLabel(title, font: Theme.captionFont, color: .secondaryLabelColor), slider])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        picture.addFull(grid)
        let rotate = makeButton("Rotate 90°", symbol: .reset, tip: "Rotate the picture a quarter turn") { [weak self] in
            guard let self else { return }
            self.controller.videoAdjustments.rotation = (self.controller.videoAdjustments.rotation + 90) % 360
            self.controller.applyVideoAdjustments()
        }
        rotate.controlSize = .small
        let reset = makeButton("Reset Picture", tip: "Reset aspect, scaling, colour and rotation") { [weak self] in
            self?.controller.videoAdjustments = VideoAdjustments()
            self?.controller.applyVideoAdjustments()
            self?.refresh()
        }
        reset.controlSize = .small
        picture.addFull(hStack([rotate, flexibleSpacer(), reset], spacing: 6))
        hwdec.controlSize = .small
        hwdec.toolTip = "Decode video with VideoToolbox, using less power; falls back to software automatically"
        hwdec.onAction { [weak self] _ in self?.controller.preferences.hardwareDecoding = self?.hwdec.state == .on }
        picture.stack.addArrangedSubview(hwdec)
        picture.addFull(hwdecStatus)
        picture.addFull(
            makeLabel("HDR video is tone-mapped to SDR in this version.", font: Theme.captionFont, color: .tertiaryLabelColor, wraps: true))
        scroll.add(picture)

        let sound = CardView(title: "Sound")
        eqPopup.addItems(withTitles: AudioEffects.Equalizer.allCases.map(\.title))
        eqPopup.setAccessibilityLabel("Equalizer preset")
        eqPopup.toolTip = "Equalizer preset"
        eqPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.audioEffects.equalizer = AudioEffects.Equalizer.allCases[self.eqPopup.indexOfSelectedItem]
            self.controller.applyAudioEffects()
        }
        normalize.controlSize = .small
        normalize.toolTip = "Even out quiet dialogue and loud effects"
        normalize.onAction { [weak self] _ in self?.controller.preferences.normalizeAudio = self?.normalize.state == .on }
        amplify.controlSize = .small
        amplify.toolTip = "Let the volume go above 100%; a limiter prevents clipping"
        amplify.onAction { [weak self] _ in self?.controller.preferences.allowAmplification = self?.amplify.state == .on }
        devicePopup.setAccessibilityLabel("Audio output device")
        devicePopup.toolTip = "Audio output device"
        devicePopup.onAction { [weak self] _ in
            guard let self, let name = self.devicePopup.selectedItem?.representedObject as? String else { return }
            do { try self.controller.player.setAudioDevice(name) } catch { self.controller.osd.send("Could not switch output device") }
        }
        let soundGrid = NSGridView(views: [
            [makeLabel("Equalizer", font: Theme.captionFont, color: .secondaryLabelColor), eqPopup],
            [makeLabel("Output", font: Theme.captionFont, color: .secondaryLabelColor), devicePopup],
        ])
        soundGrid.column(at: 0).xPlacement = .trailing
        soundGrid.rowSpacing = 6
        sound.addFull(soundGrid)
        sound.addFull(normalize)
        sound.addFull(amplify)
        scroll.add(sound)

        controller.player.$hardwareDecoder.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        controller.player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDevices()
    }

    private func refreshDevices() {
        devicePopup.removeAllItems()
        let current = controller.player.currentAudioDevice
        for device in controller.player.audioDevices() {
            devicePopup.addItem(withTitle: device.name == "auto" ? "System default" : device.description)
            devicePopup.lastItem?.representedObject = device.name
            if device.name == current { devicePopup.select(devicePopup.lastItem) }
        }
    }

    private func refresh() {
        let adj = controller.videoAdjustments
        aspectPopup.selectItem(at: VideoAdjustments.Aspect.allCases.firstIndex(of: adj.aspect) ?? 0)
        fitPopup.selectItem(at: VideoAdjustments.Fit.allCases.firstIndex(of: adj.fit) ?? 0)
        for (key, slider) in sliders { slider.doubleValue = Double(adj[keyPath: key]) }
        eqPopup.selectItem(at: AudioEffects.Equalizer.allCases.firstIndex(of: controller.audioEffects.equalizer) ?? 0)
        normalize.state = controller.preferences.normalizeAudio ? .on : .off
        amplify.state = controller.preferences.allowAmplification ? .on : .off
        hwdec.state = controller.preferences.hardwareDecoding ? .on : .off
        if controller.player.status.hasMedia {
            hwdecStatus.stringValue =
                controller.player.hardwareDecoder.map { "Active decoder: hardware (\($0))" } ?? "Active decoder: software"
        } else {
            hwdecStatus.stringValue = ""
        }
    }
}
