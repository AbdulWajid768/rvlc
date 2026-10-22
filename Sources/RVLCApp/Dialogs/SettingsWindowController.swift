import AppKit
import Combine
import RVLCCore

/// Settings window. Every control writes straight to `Preferences`, which
/// persists immediately and notifies the running player.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let controller: PlayerController
    private var prefs: Preferences { controller.preferences }
    private let tabs = NSTabViewController()
    private let shortcutsTable = NSTableView()
    private var actions = PlayerAction.allCases
    private var bag = Set<AnyCancellable>()

    init(controller: PlayerController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "RVLC Settings"
        super.init(window: window)
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item("General", symbol: "gearshape", view: generalPane()))
        tabs.addTabViewItem(item("Playback", symbol: "play.rectangle", view: playbackPane()))
        tabs.addTabViewItem(item("Subtitles", symbol: "captions.bubble", view: subtitlePane()))
        tabs.addTabViewItem(item("Audio", symbol: "speaker.wave.2", view: audioPane()))
        tabs.addTabViewItem(item("Shortcuts", symbol: "keyboard", view: shortcutsPane()))
        window.contentViewController = tabs
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func item(_ title: String, symbol: String, view: NSView) -> NSTabViewItem {
        let vc = NSViewController()
        vc.view = view
        vc.title = title
        let item = NSTabViewItem(viewController: vc)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func pane(_ rows: [[NSView]], footer: String? = nil) -> NSView {
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = Theme.spaceM
        grid.columnSpacing = Theme.spaceM
        let stack = NSStackView(views: [grid])
        if let footer {
            let label = makeLabel(footer, font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
            label.preferredMaxLayoutWidth = 460
            stack.addArrangedSubview(label)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.spaceL
        stack.edgeInsets = NSEdgeInsets(top: Theme.spaceXL, left: Theme.spaceXL, bottom: Theme.spaceXL, right: Theme.spaceXL)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 560),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField { makeLabel(text) }

    private func checkbox(_ title: String, tip: String? = nil, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.toolTip = tip ?? title
        box.state = get() ? .on : .off
        box.onAction { _ in set(box.state == .on) }
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).sink { _ in box.state = get() ? .on : .off }.store(in: &bag)
        return box
    }

    private func generalPane() -> NSView {
        let theme = NSSegmentedControl(labels: ThemePreference.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        theme.selectedSegment = ThemePreference.allCases.firstIndex(of: prefs.theme) ?? 0
        theme.setAccessibilityLabel("Appearance")
        theme.setToolTip("Follow the macOS appearance", forSegment: 0)
        theme.setToolTip("Always use the light appearance", forSegment: 1)
        theme.setToolTip("Always use the dark appearance", forSegment: 2)
        theme.onAction { [weak self] _ in
            guard let self else { return }
            self.prefs.theme = ThemePreference.allCases[theme.selectedSegment]
        }
        let clear = makeButton("Clear Playback History…", tip: "Forget recently played files and resume positions") { [weak self] in
            self?.confirmClearHistory()
        }
        let reset = makeButton("Reset All Settings…", tip: "Restore every setting and shortcut to its default") { [weak self] in
            self?.confirmReset()
        }
        return pane(
            [
                [label("Appearance:"), theme],
                [
                    label("Privacy:"),
                    checkbox("Remember playback positions", { [weak self] in self?.prefs.rememberPosition ?? true }) { [weak self] in
                        self?.prefs.rememberPosition = $0
                    },
                ],
                [NSGridCell.emptyContentView, clear],
                [NSGridCell.emptyContentView, reset],
            ],
            footer:
                "RVLC works entirely offline. It has no account, sends no telemetry and never uploads your media or subtitles. History and per-file sync settings are stored only on this Mac."
        )
    }

    private func playbackPane() -> NSView {
        let seek = NSPopUpButton()
        seek.addItems(withTitles: Preferences.seekChoicesSeconds.map { "\($0) seconds" })
        seek.toolTip = "How far ← / → and the seek buttons jump"
        seek.selectItem(at: Preferences.seekChoicesSeconds.firstIndex(of: prefs.seekStepSeconds) ?? 0)
        seek.onAction { [weak self] _ in self?.prefs.seekStepSeconds = Preferences.seekChoicesSeconds[seek.indexOfSelectedItem] }
        return pane(
            [
                [label("Seek step:"), seek],
                [
                    label("Decoding:"),
                    checkbox("Use hardware decoding when available", { [weak self] in self?.prefs.hardwareDecoding ?? true }) {
                        [weak self] in self?.prefs.hardwareDecoding = $0
                    },
                ],
                [
                    label("Resume:"),
                    checkbox("Resume files where I left off", { [weak self] in self?.prefs.rememberPosition ?? true }) { [weak self] in
                        self?.prefs.rememberPosition = $0
                    },
                ],
            ],
            footer:
                "Hardware decoding uses VideoToolbox through libmpv’s “auto-safe” mode and falls back to software decoding automatically.")
    }

    private func stepPopup(_ get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: Preferences.stepChoicesMs.map { "\($0) ms" })
        popup.toolTip = "How far each key press moves the timing"
        popup.selectItem(at: Preferences.stepChoicesMs.firstIndex(of: get()) ?? 0)
        popup.onAction { _ in set(Preferences.stepChoicesMs[popup.indexOfSelectedItem]) }
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).sink { _ in
            popup.selectItem(at: Preferences.stepChoicesMs.firstIndex(of: get()) ?? 0)
        }.store(in: &bag)
        return popup
    }

    private func subtitlePane() -> NSView {
        let size = NSSlider(value: Double(prefs.subtitleFontSize), minValue: 16, maxValue: 100, target: nil, action: nil)
        size.onAction { [weak self] _ in self?.prefs.subtitleFontSize = Int(size.doubleValue) }
        size.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return pane(
            [
                [
                    label("Loading:"),
                    checkbox(
                        "Automatically load subtitles with the same name as the video",
                        { [weak self] in self?.prefs.autoLoadSubtitles ?? true }
                    ) { [weak self] in self?.prefs.autoLoadSubtitles = $0 },
                ],
                [
                    label("Offset step:"),
                    stepPopup({ [weak self] in self?.prefs.subtitleStepMs ?? 100 }) { [weak self] in self?.prefs.subtitleStepMs = $0 },
                ],
                [label("Text size:"), size],
                [
                    label("Readability:"),
                    checkbox("Draw a background box behind subtitles", { [weak self] in self?.prefs.subtitleBackground ?? false }) {
                        [weak self] in self?.prefs.subtitleBackground = $0
                    },
                ],
            ],
            footer:
                "Offset convention: a positive offset shows subtitles later, a negative offset shows them earlier. Corrections never modify the original file; use Export in Subtitle Studio to save a corrected copy."
        )
    }

    private func audioPane() -> NSView {
        pane(
            [
                [
                    label("Delay step:"),
                    stepPopup({ [weak self] in self?.prefs.audioStepMs ?? 100 }) { [weak self] in self?.prefs.audioStepMs = $0 },
                ],
                [
                    label("Volume:"),
                    checkbox(
                        "Allow amplification up to 200% (a limiter prevents clipping)",
                        { [weak self] in self?.prefs.allowAmplification ?? false }
                    ) { [weak self] in self?.prefs.allowAmplification = $0 },
                ],
                [
                    label("Loudness:"),
                    checkbox("Normalize loudness", { [weak self] in self?.prefs.normalizeAudio ?? false }) { [weak self] in
                        self?.prefs.normalizeAudio = $0
                    },
                ],
            ],
            footer:
                "Audio delay convention: a positive delay plays the audio later relative to the video. The delay is remembered per file.")
    }

    // MARK: Shortcuts

    private func shortcutsPane() -> NSView {
        let actionColumn = NSTableColumn(identifier: .init("action"))
        actionColumn.title = "Action"
        actionColumn.width = 250
        let keyColumn = NSTableColumn(identifier: .init("key"))
        keyColumn.title = "Shortcut"
        keyColumn.width = 160
        shortcutsTable.addTableColumn(actionColumn)
        shortcutsTable.addTableColumn(keyColumn)
        shortcutsTable.rowHeight = 26
        shortcutsTable.usesAlternatingRowBackgroundColors = true
        shortcutsTable.dataSource = self
        shortcutsTable.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = shortcutsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let restore = makeButton("Restore Defaults", tip: "Restore every keyboard shortcut to its default") { [weak self] in
            guard let self else { return }
            self.prefs.keyMap = KeyMap()
            self.shortcutsTable.reloadData()
        }
        let hint = makeLabel(
            "Click a shortcut, then press the new key. Esc cancels, ⌫ clears. Menu commands such as ⌘O are fixed.",
            font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
        let stack = NSStackView(views: [scroll, hStack([hint, flexibleSpacer(), restore])])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: Theme.spaceL, left: Theme.spaceL, bottom: Theme.spaceL, right: Theme.spaceL)
        stack.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        return stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = actions[row]
        if tableColumn?.identifier.rawValue == "action" {
            return makeLabel("\(action.category.rawValue) — \(action.title)")
        }
        let recorder = KeyRecorderField(combo: controller.keyMap.combos(for: action).first)
        recorder.controlSize = .small
        recorder.onRecord = { [weak self] combo in self?.assign(combo, to: action) }
        return recorder
    }

    private func assign(_ combo: KeyCombo?, to action: PlayerAction) {
        var map = prefs.keyMap
        if let combo {
            let conflicts = map.conflicts(for: combo, excluding: action)
            if !conflicts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "\(combo) is already used by “\(conflicts[0].title)”"
                alert.informativeText = "Assign it to “\(action.title)” instead? The other action will lose this shortcut."
                alert.addButton(withTitle: "Reassign")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    shortcutsTable.reloadData()
                    return
                }
                for other in conflicts { map.set(map.combos(for: other).filter { $0 != combo }, for: other) }
            }
            map.set([combo], for: action)
        } else {
            map.set([], for: action)
        }
        prefs.keyMap = map
        shortcutsTable.reloadData()
    }

    // MARK: Destructive actions

    private func confirmClearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear playback history?"
        alert.informativeText = "Recently played items and resume positions are removed. Favorites are kept. Your files are not affected."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.controller.library.clearHistory()
            self.controller.saveLibraryNow()
        }
    }

    private func confirmReset() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText =
            "Appearance, playback, subtitle, audio and shortcut settings return to their defaults. Your library is kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.prefs.resetAll()
            self.window?.close()
        }
    }
}

/// Read-only reference of all keyboard shortcuts.
final class ShortcutsWindowController: NSWindowController {
    init(controller: PlayerController) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        super.init(window: window)
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.textStorage?.setAttributedString(Self.reference(controller.keyMap))
        text.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        window.contentView = scroll
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static let menuShortcuts: [(String, String)] = [
        ("Open File…", "⌘O"), ("Open Folder…", "⇧⌘O"), ("Load Subtitle File…", "⌘L"), ("Load External Audio…", "⇧⌘L"),
        ("Subtitle Editor", "⌘E"), ("Toggle Sidebar", "⌃⌘S"), ("Playlist / Library / Subtitles / Audio / Picture & Sound", "⌘1 … ⌘5"),
        ("Settings", "⌘,"), ("File Info", "⌘I"), ("Go to Time…", "⌘J"),
    ]

    static func reference(_ map: KeyMap) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 300)]
        style.paragraphSpacing = 3
        func heading(_ s: String) {
            out.append(NSAttributedString(string: "\(s)\n", attributes: [.font: Theme.headlineFont, .foregroundColor: NSColor.labelColor]))
        }
        func row(_ title: String, _ keys: String) {
            out.append(
                NSAttributedString(
                    string: "\(title)\t\(keys)\n",
                    attributes: [
                        .font: Theme.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
                    ]))
        }
        for category in PlayerAction.Category.allCases {
            heading(category.rawValue)
            for action in PlayerAction.allCases where action.category == category {
                let combos = map.combos(for: action)
                row(action.title, combos.isEmpty ? "—" : combos.map(\.description).joined(separator: "  or  "))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        heading("Menu commands")
        for (title, keys) in menuShortcuts { row(title, keys) }
        out.append(
            NSAttributedString(
                string: "\nShortcuts are inactive while you type in a text field. Customize them in Settings › Shortcuts.\n",
                attributes: [.font: Theme.captionFont, .foregroundColor: NSColor.secondaryLabelColor]))
        return out
    }
}

/// Presents technical details about a media file.
enum FileInfoPresenter {
    static func present(record: MediaRecord?, player: PlayerController?, in window: NSWindow) {
        var lines: [String] = []
        let path = player?.player.currentURL?.path ?? record?.path
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        lines.append("Name: \(url.lastPathComponent)")
        lines.append("Folder: \(url.deletingLastPathComponent().path)")
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        if let p = player?.player, p.currentURL?.path == path {
            if let format = p.string("file-format") { lines.append("Container: \(format)") }
            lines.append("Duration: \(Timecode.formatClock(seconds: p.duration, forceHours: true))")
            if let size = p.videoSize { lines.append("Display size: \(Int(size.width))×\(Int(size.height))") }
            if let codec = p.string("video-codec") { lines.append("Video codec: \(codec)") }
            if let fps = p.double("container-fps") { lines.append(String(format: "Frame rate: %.3f fps", fps)) }
            if let codec = p.string("audio-codec") { lines.append("Audio codec: \(codec)") }
            lines.append("Decoder: \(p.hardwareDecoder.map { "hardware (\($0))" } ?? "software")")
            let tracks = p.tracks
            lines.append(
                "Tracks: \(tracks.filter { $0.kind == .video }.count) video, \(tracks.filter { $0.kind == .audio }.count) audio, \(tracks.filter { $0.kind == .sub }.count) subtitle"
            )
            for t in tracks { lines.append("  • \(t.kind.rawValue): \(t.displayName)") }
        } else if let record {
            if let d = record.duration { lines.append("Duration: \(Timecode.formatClock(seconds: d, forceHours: true))") }
            if let r = record.resolutionText { lines.append("Resolution: \(r)") }
            if let played = record.lastPlayed { lines.append("Last played: \(played.formatted(date: .abbreviated, time: .shortened))") }
            lines.append("Times played: \(record.playCount)")
            if record.audioDelayMs != 0 { lines.append("Saved audio delay: \(formatOffset(record.audioDelayMs))") }
            if let sub = record.subtitlePath {
                lines.append("Saved subtitle: \(URL(fileURLWithPath: sub).lastPathComponent) (\(formatOffset(record.subtitleOffsetMs)))")
            }
        }
        let alert = NSAlert()
        alert.messageText = "File Info"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { r in
            if r == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
