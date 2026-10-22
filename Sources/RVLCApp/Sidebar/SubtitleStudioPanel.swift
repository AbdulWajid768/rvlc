import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Subtitle Studio: import, offset, reference-point sync, audio auto-sync,
/// appearance and export — designed so a beginner can fix timing in seconds.
final class SubtitleStudioPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let controller: PlayerController
    private var session: SubtitleSession { controller.subtitles }
    private var player: MPVPlayer { controller.player }
    private var bag = Set<AnyCancellable>()
    var onOpenSubtitle: (() -> Void)?
    var onOpenEditor: (() -> Void)?

    private let scroll = PanelScrollView()

    // Source
    private let sourceCard = CardView(title: "Subtitle file")
    private let fileName = makeLabel("", font: Theme.headlineFont)
    private let fileMeta = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    private let warningLabel = makeLabel("", font: Theme.captionFont, color: Theme.warning, wraps: true)
    private let noFileLabel = makeLabel(
        "Load an SRT, WebVTT or ASS file to sync and edit it. Embedded subtitle tracks can be shifted with the offset below.",
        font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
    private let encodingPopup = NSPopUpButton()
    private let trackPopup = NSPopUpButton()
    private let visibleCheckbox = NSButton(checkboxWithTitle: "Show subtitles", target: nil, action: nil)
    private var loadButton: NSButton!
    private var fileActions: NSStackView!

    // Offset
    private var offsetControl: OffsetControl!
    private let stepKeysLabel = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    private let previewErrorLabel = makeLabel("", font: Theme.captionFont, color: Theme.danger, wraps: true)
    private var sizeSlider: NSSlider!
    private var positionSlider: NSSlider!
    private var backgroundBox: NSButton!
    private let stepPopup = NSPopUpButton()
    private let driftLabel = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
    private var driftRow: NSStackView!

    // Sync
    private let syncCard = CardView(title: "Sync to speech")
    let lineTable = NSTableView()
    private let pointsStack = NSStackView()
    private var syncButton: NSButton!
    private var activeCue: Int?
    private var sortedCues: [Int] = []

    // Suggestion
    private let suggestionCard = CardView(title: "Suggested correction")
    private let suggestionTitle = makeLabel("", font: Theme.headlineFont, wraps: true)
    private let suggestionDetail = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
    private var previewButton: NSButton!

    // Auto sync
    private let autoCard = CardView(title: "Automatic sync (audio analysis)")
    private var analyzeButton: NSButton!
    private let progress = NSProgressIndicator()
    private let autoError = makeLabel("", font: Theme.captionFont, color: Theme.danger, wraps: true)

    // Edit & export
    private let editCard = CardView(title: "Edit & export")
    private let editStatus = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
    private var revertButton: NSButton!

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = scroll
        buildSource()
        buildOffset()
        buildSync()
        buildSuggestion()
        buildAuto()
        buildAppearance()
        buildEdit()
        bind()
        controller.selectedCueProvider = { [weak self] in self?.selectedCueIndex() }
        refresh()
    }

    // MARK: Building

    private func buildSource() {
        loadButton = makeButton("Load Subtitle File…", symbol: .file, tip: "Load an SRT, WebVTT or ASS file (⌘L)") { [weak self] in
            self?.onOpenSubtitle?()
        }
        loadButton.keyEquivalent = ""
        encodingPopup.controlSize = .small
        encodingPopup.toolTip = "Text encoding — change it if characters look wrong"
        encodingPopup.setAccessibilityLabel("Text encoding")
        for (name, label) in SubtitleIO.commonEncodings {
            encodingPopup.addItem(withTitle: label)
            encodingPopup.lastItem?.representedObject = name
        }
        encodingPopup.onAction { [weak self] _ in self?.changeEncoding() }
        let replace = makeButton("Replace…", tip: "Load a different subtitle file instead of this one") { [weak self] in
            self?.onOpenSubtitle?()
        }
        replace.controlSize = .small
        let remove = makeButton("Remove") { [weak self] in self?.controller.removeSubtitle() }
        remove.controlSize = .small
        remove.toolTip = "Stop using this subtitle file (the file itself is not changed)"
        fileActions = hStack([replace, remove, flexibleSpacer()], spacing: 6)

        trackPopup.controlSize = .small
        trackPopup.setAccessibilityLabel("Active subtitle track")
        trackPopup.toolTip = "Subtitle track shown on the video"
        trackPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.player.selectTrack(.sub, id: self.trackPopup.selectedItem?.representedObject as? Int)
        }
        visibleCheckbox.onAction { [weak self] _ in
            guard let self else { return }
            self.player.setSubtitlesVisible(self.visibleCheckbox.state == .on)
        }
        visibleCheckbox.controlSize = .small
        visibleCheckbox.toolTip = "Show or hide subtitles on the video (S)"
        fileName.lineBreakMode = .byTruncatingMiddle
        sourceCard.addFull(noFileLabel)
        sourceCard.stack.addArrangedSubview(loadButton)
        sourceCard.addFull(fileName)
        sourceCard.addFull(fileMeta)
        sourceCard.addFull(warningLabel)
        previewErrorLabel.isHidden = true
        sourceCard.addFull(previewErrorLabel)
        sourceCard.addFull(
            hStack(
                [makeLabel("Encoding", font: Theme.captionFont, color: .secondaryLabelColor), encodingPopup, flexibleSpacer()], spacing: 6))
        sourceCard.addFull(fileActions)
        sourceCard.addFull(
            hStack([makeLabel("Track", font: Theme.captionFont, color: .secondaryLabelColor), trackPopup, flexibleSpacer()], spacing: 6))
        sourceCard.stack.addArrangedSubview(visibleCheckbox)
        scroll.add(sourceCard)
    }

    private func buildOffset() {
        let card = CardView(title: "Timing offset")
        offsetControl = OffsetControl(
            wording: .init(
                positive: "Subtitles appear %@ later than in the file", negative: "Subtitles appear %@ earlier than in the file",
                zero: "Original timing. Use + if subtitles come too early, − if too late."),
            accessibilityName: "Subtitle offset"
        ) { [weak self] ms in self?.controller.setSubtitleOffset(ms) }
        card.addFull(offsetControl)
        for ms in Preferences.stepChoicesMs { stepPopup.addItem(withTitle: "\(ms) ms") }
        stepPopup.controlSize = .small
        stepPopup.setAccessibilityLabel("Keyboard step for subtitle offset")
        stepPopup.toolTip = "How far each Z / X key press moves the subtitles"
        stepPopup.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.preferences.subtitleStepMs = Preferences.stepChoicesMs[self.stepPopup.indexOfSelectedItem]
        }
        card.addFull(hStack([stepKeysLabel, stepPopup, flexibleSpacer()], spacing: 6))
        let removeDrift = makeButton("Remove", tip: "Remove the drift correction and keep the offset") { [weak self] in
            // Removes only the drift correction; the constant offset stays.
            self?.session.setScale(1)
            self?.controller.rememberSubtitleState()
        }
        removeDrift.controlSize = .small
        driftRow = hStack([driftLabel, flexibleSpacer(), removeDrift], spacing: 6)
        card.addFull(driftRow)
        scroll.add(card)
    }

    private func buildSync() {
        let steps = makeLabel(
            "1. Pause when a line is spoken.\n2. Select that line below.\n3. Click “Sync Line to Now”.\nAdd a second point near the end to fix drift.",
            font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
        syncCard.addFull(steps)

        let timeColumn = NSTableColumn(identifier: .init("time"))
        timeColumn.width = 64
        timeColumn.title = "Time"
        let textColumn = NSTableColumn(identifier: .init("text"))
        textColumn.title = "Line"
        lineTable.addTableColumn(timeColumn)
        lineTable.addTableColumn(textColumn)
        lineTable.headerView = nil
        lineTable.rowHeight = 20
        lineTable.usesAlternatingRowBackgroundColors = true
        lineTable.dataSource = self
        lineTable.delegate = self
        lineTable.target = self
        lineTable.doubleAction = #selector(jumpToLine)
        lineTable.setAccessibilityLabel("Subtitle lines")
        lineTable.toolTip = "Select the line being spoken. Double-click to jump to it."
        let tableScroll = NSScrollView()
        tableScroll.documentView = lineTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        syncCard.addFull(tableScroll)

        let key = controller.keyMap.combos(for: .setSyncPoint).first?.description ?? ""
        syncButton = makeButton("Sync Line to Now", symbol: .target) { [weak self] in self?.controller.syncSelectedLineToNow() }
        syncButton.toolTip = "The selected line is the one being heard right now (\(key))"
        let follow = IconButton(.findLine, label: "Find Current Line") { [weak self] in self?.selectCurrentLine() }
        follow.toolTip = "Find Current Line: select the line on screen now"
        syncCard.addFull(hStack([syncButton, flexibleSpacer(), follow], spacing: 6))

        pointsStack.orientation = .vertical
        pointsStack.alignment = .leading
        pointsStack.spacing = 4
        syncCard.addFull(pointsStack)
        scroll.add(syncCard)
    }

    private func buildSuggestion() {
        previewButton = makeButton("Preview", tip: "Try the suggested timing on the video without applying it") { [weak self] in
            self?.session.previewSuggestion()
        }
        let apply = makeButton("Apply", tip: "Use the suggested timing for this file") { [weak self] in
            self?.session.acceptSuggestion()
            self?.controller.rememberSubtitleState()
        }
        apply.keyEquivalent = ""
        apply.bezelColor = .controlAccentColor
        let discard = makeButton("Discard", tip: "Ignore the suggestion and keep the current timing") { [weak self] in
            self?.session.rejectSuggestion()
        }
        suggestionCard.addFull(suggestionTitle)
        suggestionCard.addFull(suggestionDetail)
        suggestionCard.addFull(hStack([previewButton, apply, flexibleSpacer(), discard], spacing: 6))
        suggestionCard.setAccessibilityLabel("Suggested correction")
        scroll.add(suggestionCard)
    }

    private func buildAuto() {
        let text = makeLabel(
            "Matches speech in the selected audio track with the subtitle timing to suggest an offset. Runs entirely on this Mac. Works best with dialogue-heavy content.",
            font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
        analyzeButton = makeButton(
            "Analyze Audio", symbol: .wand, tip: "Suggest an offset by matching speech in the audio to the subtitles (runs on this Mac)"
        ) { [weak self] in
            guard let self else { return }
            if self.session.isAnalyzing { self.session.cancelAnalysis() } else { self.session.analyzeAudio() }
        }
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        autoCard.addFull(text)
        autoCard.addFull(hStack([analyzeButton, progress], spacing: Theme.spaceS))
        autoCard.addFull(autoError)
        scroll.add(autoCard)
    }

    private func buildAppearance() {
        let card = CardView(title: "Appearance")
        let prefs = controller.preferences
        let size = NSSlider(value: Double(prefs.subtitleFontSize), minValue: 16, maxValue: 100, target: nil, action: nil)
        sizeSlider = size
        size.onAction { _ in prefs.subtitleFontSize = Int(size.doubleValue) }
        size.setAccessibilityLabel("Subtitle size")
        let position = NSSlider(value: Double(prefs.subtitlePosition), minValue: 50, maxValue: 100, target: nil, action: nil)
        positionSlider = position
        position.onAction { _ in prefs.subtitlePosition = Int(position.doubleValue) }
        position.setAccessibilityLabel("Subtitle vertical position")
        let background = NSButton(checkboxWithTitle: "Background box for readability", target: nil, action: nil)
        backgroundBox = background
        background.state = prefs.subtitleBackground ? .on : .off
        background.onAction { _ in prefs.subtitleBackground = background.state == .on }
        background.controlSize = .small
        background.toolTip = "Draw a dark box behind plain-text subtitles so they are easier to read"
        let grid = NSGridView(views: [
            [makeLabel("Size", font: Theme.captionFont, color: .secondaryLabelColor), size],
            [makeLabel("Position", font: Theme.captionFont, color: .secondaryLabelColor), position],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        card.addFull(grid)
        card.stack.addArrangedSubview(background)
        card.addFull(
            makeLabel(
                "Styled ASS subtitles keep their own fonts and colours; size applies to plain text subtitles.",
                font: Theme.captionFont, color: .tertiaryLabelColor, wraps: true))
        scroll.add(card)
    }

    private func buildEdit() {
        let editor = makeButton("Edit Lines…", symbol: .edit, tip: "Fix text and timing of individual lines (⌘E)") { [weak self] in
            self?.onOpenEditor?()
        }
        let export = makeButton("Export…", symbol: .export, tip: "Save a corrected copy (the original file is never changed)") {
            [weak self] in self?.exportSubtitles()
        }
        revertButton = makeButton("Revert Edits", tip: "Undo all line edits and go back to the file as loaded") { [weak self] in
            self?.session.revertEdits()
        }
        revertButton.controlSize = .small
        editCard.addFull(hStack([editor, export, flexibleSpacer()], spacing: 6))
        editCard.addFull(editStatus)
        editCard.stack.addArrangedSubview(revertButton)
        scroll.add(editCard)
    }

    // MARK: Binding

    private func bind() {
        session.$document.receive(on: RunLoop.main).sink { [weak self] _ in self?.documentChanged() }.store(in: &bag)
        session.$suggestion.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshSuggestion() }.store(in: &bag)
        session.$syncPoints.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshPoints() }.store(in: &bag)
        session.$scale.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        session.$isAnalyzing.combineLatest(session.$analysisProgress, session.$lastError).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAnalysis() }.store(in: &bag)
        player.$subtitleDelayMs.receive(on: RunLoop.main).sink { [weak self] ms in self?.offsetControl.setValue(ms, notify: false) }.store(
            in: &bag)
        player.$tracks.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshTracks() }.store(in: &bag)
        player.$subtitlesVisible.receive(on: RunLoop.main).sink { [weak self] v in self?.visibleCheckbox.state = v ? .on : .off }.store(
            in: &bag)
        player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        player.$position.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.followPlayback() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStep() }.store(in: &bag)
        // A different document: an old row selection would point at an unrelated line.
        session.$documentGeneration.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.lineTable.deselectAll(nil) }.store(in: &bag)
        session.$previewError.receive(on: RunLoop.main).sink { [weak self] message in
            self?.previewErrorLabel.stringValue = message ?? ""
            self?.previewErrorLabel.isHidden = message == nil
        }.store(in: &bag)
        refreshStep()
    }

    private func documentChanged() {
        sortedCues = session.document?.sortedIndices() ?? []
        activeCue = nil
        lineTable.reloadData()
        refresh()
    }

    /// Re-reads everything that depends on preferences (step, shortcuts, appearance).
    private func refreshStep() {
        let prefs = controller.preferences
        stepPopup.selectItem(at: Preferences.stepChoicesMs.firstIndex(of: prefs.subtitleStepMs) ?? 0)
        let map = controller.preferences.keyMap
        let earlier = map.combos(for: .subtitleEarlier).first?.description ?? "—"
        let later = map.combos(for: .subtitleLater).first?.description ?? "—"
        stepKeysLabel.stringValue = "Keys \(earlier) / \(later) step"
        let sync = map.combos(for: .setSyncPoint).first.map { " (\($0))" } ?? ""
        syncButton?.toolTip = "The selected line is the one being heard right now\(sync)"
        sizeSlider?.doubleValue = Double(prefs.subtitleFontSize)
        positionSlider?.doubleValue = Double(prefs.subtitlePosition)
        backgroundBox?.state = prefs.subtitleBackground ? .on : .off
    }

    func refresh() {
        let doc = session.document
        let hasMedia = player.status.hasMedia
        noFileLabel.isHidden = doc != nil
        loadButton.isHidden = doc != nil
        loadButton.isEnabled = hasMedia
        loadButton.toolTip = hasMedia ? "Load an SRT, WebVTT or ASS file (⌘L)" : "Open a video first"
        for v in [fileName, fileMeta, fileActions, encodingPopup.superview] as [NSView?] { v?.isHidden = doc == nil }
        if let doc {
            fileName.stringValue = doc.sourceURL?.lastPathComponent ?? "Subtitles"
            fileName.toolTip = doc.sourceURL?.path
            let lines = doc.cues.filter { !$0.isComment }.count
            fileMeta.stringValue = "\(doc.format.rawValue.uppercased()) · \(doc.encoding.uppercased()) · \(lines.formatted()) lines"
            if let index = SubtitleIO.commonEncodings.firstIndex(where: { $0.name == doc.encoding }) {
                encodingPopup.selectItem(at: index)
            }
            if doc.warnings.isEmpty {
                warningLabel.isHidden = true
            } else {
                warningLabel.isHidden = false
                warningLabel.stringValue = "⚠︎ \(doc.warnings[0])" + (doc.warnings.count > 1 ? " (+\(doc.warnings.count - 1) more)" : "")
                warningLabel.toolTip = doc.warnings.joined(separator: "\n")
            }
        } else {
            warningLabel.isHidden = true
        }
        syncCard.isHidden = doc == nil
        autoCard.isHidden = doc == nil
        editCard.isHidden = doc == nil
        offsetControl.superview?.superview?.alphaValue = hasMedia ? 1 : 0.5
        let t = session.transform
        driftRow.isHidden = !t.hasScale
        if t.hasScale {
            driftLabel.stringValue = String(format: "Drift correction ×%.5f (%+.1f s per hour)", t.scale, t.driftSecondsPerHour)
        }
        editStatus.stringValue =
            session.hasEdits
            ? "Edited — changes are previewed live. The original file is never modified." : "No edits. The original file is never modified."
        revertButton.isHidden = !session.hasEdits
        refreshTracks()
        refreshSuggestion()
        refreshAnalysis()
    }

    private func refreshTracks() {
        trackPopup.removeAllItems()
        trackPopup.addItem(withTitle: "Off")
        trackPopup.lastItem?.representedObject = nil
        var selectedIndex = 0
        for track in player.tracks(.sub) {
            let name = track.id == session.trackID ? "\(session.sourceName ?? "Imported") (Studio)" : track.displayName
            trackPopup.addItem(withTitle: name)
            trackPopup.lastItem?.representedObject = track.id
            if track.isSelected { selectedIndex = trackPopup.numberOfItems - 1 }
        }
        trackPopup.selectItem(at: selectedIndex)
        trackPopup.isEnabled = player.status.hasMedia
    }

    private func refreshPoints() {
        pointsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !session.syncPoints.isEmpty else { return }
        pointsStack.addArrangedSubview(SectionLabel("Sync points"))
        for (i, p) in session.syncPoints.enumerated() {
            let text = "“\(p.label.prefix(28))” → \(Timecode.formatEditor(p.mediaMs)) (\(formatOffset(p.offsetMs)))"
            let label = makeLabel(text, font: Theme.captionFont)
            let remove = IconButton(.close, label: "Remove sync point", size: 10) { [weak self] in self?.session.removeSyncPoint(at: i) }
            let row = hStack([label, flexibleSpacer(), remove], spacing: 4)
            pointsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pointsStack.widthAnchor).isActive = true
        }
        let clear = makeButton("Clear Sync Points", tip: "Remove all sync points and their suggestion") { [weak self] in
            self?.session.clearSyncPoints()
        }
        clear.controlSize = .small
        pointsStack.addArrangedSubview(clear)
    }

    private func refreshSuggestion() {
        guard let s = session.suggestion else {
            suggestionCard.isHidden = true
            return
        }
        suggestionCard.isHidden = false
        suggestionTitle.stringValue = s.summary
        suggestionDetail.stringValue = s.detail
        previewButton.title = s.isPreviewing ? "Previewing" : "Preview"
        previewButton.isEnabled = !s.isPreviewing
        if case .audioAnalysis(let confidence) = s.source, confidence == "Low" {
            suggestionDetail.textColor = Theme.warning
        } else {
            suggestionDetail.textColor = .secondaryLabelColor
        }
    }

    private func refreshAnalysis() {
        analyzeButton.title = session.isAnalyzing ? "Cancel" : "Analyze Audio"
        analyzeButton.setAccessibilityLabel(analyzeButton.title)
        analyzeButton.toolTip =
            session.isAnalyzing
            ? "Stop the analysis" : "Suggest an offset by matching speech in the audio to the subtitles (runs on this Mac)"
        analyzeButton.isEnabled = player.status.hasMedia && session.hasDocument
        progress.isHidden = !session.isAnalyzing
        progress.doubleValue = session.analysisProgress
        autoError.stringValue = session.lastError ?? ""
        autoError.isHidden = session.lastError == nil
    }

    // MARK: Line list

    func numberOfRows(in tableView: NSTableView) -> Int { sortedCues.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let doc = session.document, let cueIndex = sortedCues[safe: row] else { return nil }
        guard let cue = doc.cues[safe: cueIndex] else { return nil }
        let isTime = tableColumn?.identifier.rawValue == "time"
        let text: String
        if isTime {
            text = Timecode.formatClock(seconds: Double(session.transform.apply(cue.startMs)) / 1000)
        } else {
            let plain = doc.format == .ass ? ASSCodec.plainText(cue.text) : cue.text
            text = plain.replacingOccurrences(of: "\n", with: " ")
        }
        let label = NSTextField(labelWithString: text)
        label.font = isTime ? Theme.monoDigits : Theme.font(12, cueIndex == activeCue ? .semibold : .regular)
        label.textColor = cueIndex == activeCue ? .controlAccentColor : (isTime ? .secondaryLabelColor : .labelColor)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    func selectedCueIndex() -> Int? {
        // Only a selection the user can currently see counts; otherwise the nearest line is used.
        guard view.window != nil, view.superview != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let row = lineTable.selectedRow
        return row >= 0 ? sortedCues[safe: row] : nil
    }

    @objc private func jumpToLine() {
        guard let index = sortedCues[safe: lineTable.clickedRow], let t = session.displayedStart(of: index) else { return }
        player.seek(max(0, t - 0.3))
    }

    private func selectCurrentLine() {
        guard let index = session.nearestCueIndex(toMedia: player.currentPosition), let row = sortedCues.firstIndex(of: index) else {
            return
        }
        lineTable.selectRowIndexes([row], byExtendingSelection: false)
        lineTable.scrollRowToVisible(row)
    }

    private func followPlayback() {
        guard session.hasDocument, view.window != nil else { return }
        let now = session.cueIndex(atMedia: player.position)
        guard now != activeCue else { return }
        let previous = activeCue
        activeCue = now
        var rows = IndexSet()
        if let p = previous, let r = sortedCues.firstIndex(of: p) { rows.insert(r) }
        if let n = now, let r = sortedCues.firstIndex(of: n) {
            rows.insert(r)
            if player.status == .playing { lineTable.scrollRowToVisible(min(sortedCues.count - 1, r + 2)) }
        }
        lineTable.reloadData(forRowIndexes: rows, columnIndexes: [0, 1])
    }

    // MARK: Actions

    private func changeEncoding() {
        guard let name = encodingPopup.selectedItem?.representedObject as? String else { return }
        guard controller.mayDiscardSubtitleEdits("change the text encoding") else {
            refresh()
            return
        }
        do {
            try session.reload(encoding: name)
        } catch {
            controller.osd.send(error.localizedDescription)
            refresh()
        }
    }

    func exportSubtitles() {
        guard let doc = session.document, let window = view.window else { return }
        let panel = NSSavePanel()
        let formats: [SubtitleFormat] = doc.format == .ass ? [.ass, .srt, .vtt] : [.srt, .vtt]
        let formatPopup = NSPopUpButton()
        formatPopup.addItems(withTitles: formats.map(\.displayName))
        let encodings: [(String, String)] =
            [("utf-8", "UTF-8 (recommended)")] + (doc.encoding != "utf-8" ? [(doc.encoding, "Original (\(doc.encoding))")] : [])
        let encodingPopup = NSPopUpButton()
        encodingPopup.addItems(withTitles: encodings.map(\.1))
        let note = makeLabel(
            "Timing correction \(session.transform.isIdentity ? "none" : formatOffset(session.transform.offsetMs) + (session.transform.hasScale ? String(format: ", ×%.5f", session.transform.scale) : "")) will be applied. The original file stays unchanged.",
            font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
        note.preferredMaxLayoutWidth = 360
        let grid = NSGridView(views: [
            [makeLabel("Format:"), formatPopup],
            [makeLabel("Encoding:"), encodingPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        let accessory = NSStackView(views: [grid, note])
        accessory.orientation = .vertical
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        let suggested = SubtitleIO.suggestedExportURL(for: doc.sourceURL, format: formats[0])
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = []
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        formatPopup.onAction { [weak panel, weak formatPopup] _ in
            guard let panel, let formatPopup else { return }
            let format = formats[formatPopup.indexOfSelectedItem]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + format.fileExtension
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let format = formats[formatPopup.indexOfSelectedItem]
            let encoding = encodings[encodingPopup.indexOfSelectedItem].0
            do {
                let report = try self.session.export(to: url, format: format, encoding: encoding)
                self.showExportResult(report, in: window)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The subtitles could not be exported"
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func showExportResult(_ report: SubtitleIO.ExportReport, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Subtitles exported"
        var info =
            "Saved \(report.cueCount) lines as \(report.format.displayName) (\(report.encoding.uppercased())) to:\n\(report.url.path)"
        if !report.warnings.isEmpty { info += "\n\nNotes:\n• " + report.warnings.joined(separator: "\n• ") }
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
        }
    }
}
