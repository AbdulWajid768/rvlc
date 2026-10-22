import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Full subtitle line editor with search/replace and per-line timing.
/// Edits are previewed live in the player; the source file is never modified.
final class SubtitleEditorWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSMenuItemValidation
{
    let controller: PlayerController
    private var session: SubtitleSession { controller.subtitles }
    private var bag = Set<AnyCancellable>()

    let table = NSTableView()
    let searchField = NSSearchField()
    let replaceField = NSTextField()
    private let caseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wordBox = NSButton(checkboxWithTitle: "Whole words", target: nil, action: nil)
    private let regexBox = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let filterBox = NSButton(checkboxWithTitle: "Show matches only", target: nil, action: nil)
    private let matchLabel = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    private let footer = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    private let emptyLabel = makeLabel(
        "No subtitle file is loaded. Load one from Subtitle Studio.", font: Theme.bodyFont, color: .secondaryLabelColor)

    /// Visible rows → cue indices (sorted by time, optionally filtered).
    private(set) var rows: [Int] = []
    private var matches = Set<Int>()

    init(controller: PlayerController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Subtitle Editor"
        window.minSize = NSSize(width: 560, height: 320)
        window.setFrameAutosaveName("RVLCSubtitleEditor")
        super.init(window: window)
        window.delegate = self
        build()
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        searchField.placeholderString = "Find"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.onAction { [weak self] _ in self?.updateMatches() }
        searchField.setAccessibilityLabel("Find text")
        replaceField.placeholderString = "Replace with"
        replaceField.setAccessibilityLabel("Replacement text")
        for box in [caseBox, wordBox, regexBox, filterBox] {
            box.controlSize = .small
            box.toolTip = box.title
            box.onAction { [weak self] _ in self?.updateMatches() }
        }
        let replaceAll = makeButton("Replace All", tip: "Replace every match in the visible lines (can be undone)") { [weak self] in
            self?.replaceAll()
        }
        let findRow = hStack([searchField, replaceField, replaceAll], spacing: Theme.spaceS)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let optionsRow = hStack([caseBox, wordBox, regexBox, filterBox, flexibleSpacer(), matchLabel], spacing: Theme.spaceM)

        let columns: [(String, String, CGFloat, Bool)] = [
            ("index", "#", 44, false), ("start", "Start", 104, true), ("end", "End", 104, true),
            ("shown", "Shown at", 96, false), ("text", "Text", 360, true),
        ]
        for (id, title, width, _) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "text" ? 160 : 40
            if id == "text" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(jumpToSelected)
        table.setAccessibilityLabel("Subtitle lines")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let minus = makeButton("−100 ms") { [weak self] in self?.shiftSelected(-100) }
        let plus = makeButton("+100 ms") { [weak self] in self?.shiftSelected(100) }
        minus.toolTip = "Move selected lines 100 ms earlier"
        plus.toolTip = "Move selected lines 100 ms later"
        let setStart = makeButton("Set Start to Now", symbol: .target) { [weak self] in self?.setStartToNow() }
        setStart.toolTip = "Move the selected line so it starts at the current playback time (keeps its duration)"
        let jump = makeButton("Jump to Line", tip: "Play from the selected line (or double-click it)") { [weak self] in
            self?.jumpToSelected()
        }
        let undo = makeButton("Undo", tip: "Undo the last edit (⌘Z)") { [weak self] in self?.undo(nil) }
        let redo = makeButton("Redo", tip: "Redo the last undone edit (⇧⌘Z)") { [weak self] in self?.redo(nil) }
        let actions = hStack([minus, plus, setStart, jump, flexibleSpacer(), undo, redo], spacing: Theme.spaceS)

        let stack = NSStackView(views: [findRow, optionsRow, scroll, actions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.spaceS
        stack.edgeInsets = NSEdgeInsets(top: Theme.spaceM, left: Theme.spaceL, bottom: Theme.spaceM, right: Theme.spaceL)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            findRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.spaceL),
            optionsRow.widthAnchor.constraint(equalTo: findRow.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: findRow.widthAnchor),
            actions.widthAnchor.constraint(equalTo: findRow.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func bind() {
        session.$document.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &bag)
        controller.player.$subtitleDelayMs.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.reloadShownColumn()
            self?.updateFooter()
        }.store(in: &bag)
        session.$scale.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.reloadShownColumn()
            self?.updateFooter()
        }.store(in: &bag)
    }

    private var options: SubtitleEditing.SearchOptions {
        .init(caseSensitive: caseBox.state == .on, wholeWord: wordBox.state == .on, regularExpression: regexBox.state == .on)
    }

    func reload() {
        guard let doc = session.document else {
            rows = []
            table.reloadData()
            emptyLabel.isHidden = false
            updateFooter()
            return
        }
        emptyLabel.isHidden = true
        let query = searchField.stringValue
        do {
            matches = Set(try SubtitleEditing.find(query, in: doc, options: options))
            matchLabel.textColor = .secondaryLabelColor
            matchLabel.stringValue = query.isEmpty ? "\(doc.cues.count) lines" : "\(matches.count) matching line(s)"
        } catch {
            matches = []
            matchLabel.textColor = Theme.danger
            matchLabel.stringValue = "Invalid regular expression"
        }
        let sorted = doc.sortedIndices()
        rows = filterBox.state == .on && !query.isEmpty ? sorted.filter { matches.contains($0) } : sorted
        if table.editedRow < 0 { table.reloadData() }
        updateFooter()
    }

    private func reloadShownColumn() {
        guard let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "shown" }), !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [col])
    }

    private func updateFooter() {
        let t = session.transform
        footer.stringValue =
            t.isIdentity
            ? "Start and End are the file’s times. Edits are previewed live; the original file is never modified."
            : "Start and End are the file’s times; “Shown at” includes the Studio correction (\(formatOffset(t.offsetMs))\(t.hasScale ? String(format: ", ×%.5f", t.scale) : ""))."
    }

    private func updateMatches() { reload() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let doc = session.document, let index = rows[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let cue = doc.cues[index]
        let field = CueField()
        field.generation = session.documentGeneration
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        field.tag = index
        field.identifier = NSUserInterfaceItemIdentifier(id)
        switch id {
        case "index":
            field.stringValue = String(index + 1)
            field.isEditable = false
            field.textColor = .secondaryLabelColor
            field.font = Theme.monoDigits
        case "start":
            field.stringValue = Timecode.formatEditor(cue.startMs)
            field.isEditable = true
            field.font = Theme.monoDigits
            field.setAccessibilityLabel("Start time of line \(index + 1)")
        case "end":
            field.stringValue = Timecode.formatEditor(cue.endMs)
            field.isEditable = true
            field.font = Theme.monoDigits
            field.setAccessibilityLabel("End time of line \(index + 1)")
        case "shown":
            field.stringValue = Timecode.formatEditor(session.transform.apply(cue.startMs))
            field.isEditable = false
            field.textColor = .secondaryLabelColor
            field.font = Theme.monoDigits
        default:
            field.stringValue = cue.text
            field.isEditable = true
            field.font = Theme.bodyFont
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.lineBreakMode = .byWordWrapping
            field.setAccessibilityLabel("Text of line \(index + 1)")
            if matches.contains(index) { field.textColor = .controlAccentColor }
            if cue.isComment { field.textColor = .tertiaryLabelColor }
        }
        return field
    }

    /// Ends any cell edit (committing it) before a button acts on the document.
    func commitEditing() {
        if table.editedRow >= 0 || window?.firstResponder is NSTextView { window?.makeFirstResponder(table) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // A cell created for a document that has since been replaced is discarded, not misapplied.
        guard let field = obj.object as? CueField, field.generation == session.documentGeneration,
            let id = field.identifier?.rawValue, let cue = session.document?.cues[safe: field.tag]
        else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
            return
        }
        let index = field.tag
        switch id {
        case "text":
            // Multi-line text uses ⌥↩ in the field; stored with \n line breaks.
            if field.stringValue != cue.text { session.setText(field.stringValue, at: index) }
        case "start", "end":
            do {
                let original = Timecode.formatEditor(id == "start" ? cue.startMs : cue.endMs)
                guard field.stringValue != original else { break }
                let ms = try Timecode.parseEditor(field.stringValue)
                let start = id == "start" ? ms : cue.startMs
                var end = id == "end" ? ms : cue.endMs
                if id == "start", end < start { end = start + cue.durationMs }
                try session.setTimes(at: index, startMs: start, endMs: end)
            } catch {
                NSSound.beep()
                field.stringValue = Timecode.formatEditor(id == "start" ? cue.startMs : cue.endMs)
                controller.osd.send(error.localizedDescription)
            }
        default: break
        }
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField { updateMatches() }
    }

    // MARK: Actions

    private var selectedCues: [Int] { table.selectedRowIndexes.compactMap { rows[safe: $0] } }

    func shiftSelected(_ delta: Int) {
        commitEditing()
        let cues = selectedCues
        guard !cues.isEmpty else { NSSound.beep(); return }
        session.shiftLines(cues, by: delta)
        controller.osd.send("Moved \(cues.count) line(s) \(formatOffset(delta))")
    }

    func setStartToNow() {
        commitEditing()
        guard let index = selectedCues.first, let cue = session.document?.cues[safe: index] else { NSSound.beep(); return }
        let nowMs = Int(controller.player.currentPosition * 1000)
        let start = max(0, session.transform.invert(nowMs))
        try? session.setTimes(at: index, startMs: start, endMs: start + cue.durationMs)
    }

    @objc func jumpToSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let index = rows[safe: row], let t = session.displayedStart(of: index) else { return }
        controller.player.seek(max(0, t - 0.3))
    }

    func replaceAll() {
        commitEditing()
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        do {
            let count = try session.replaceAll(query, with: replaceField.stringValue, options: options)
            matchLabel.stringValue = "Replaced \(count) occurrence(s)"
        } catch {
            NSSound.beep()
            matchLabel.stringValue = "Invalid regular expression"
        }
    }

    // MARK: Undo via Edit menu (when not editing a text field)

    @objc func undo(_ sender: Any?) {
        commitEditing()
        session.undo()
    }

    @objc func redo(_ sender: Any?) {
        commitEditing()
        session.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return session.canUndo
        case #selector(redo(_:)): return session.canRedo
        default: return true
        }
    }
}

/// Editable cell that remembers which document it was created for.
final class CueField: NSTextField {
    var generation = -1
}
