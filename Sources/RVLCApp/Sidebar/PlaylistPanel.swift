import AppKit
import Combine
import RVLCCore

private let playlistRowType = NSPasteboard.PasteboardType("com.rvlc.player.playlist-row")

/// Play queue with drag-to-reorder, file drops, repeat modes and removal.
final class PlaylistPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let controller: PlayerController
    let table = ActionTableView()
    private let emptyLabel = makeLabel(
        "The playlist is empty.\nAdd files or drop them here.", font: Theme.bodyFont, color: .secondaryLabelColor, wraps: true)
    private let repeatControl = NSSegmentedControl()
    private var bag = Set<AnyCancellable>()
    var onAddFiles: (() -> Void)?

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var items: [String] { controller.playlist.items }

    override func loadView() {
        let root = NSView()
        view = root
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked)
        table.onReturn = { [weak self] in
            guard let self, self.items.indices.contains(self.table.selectedRow) else { return }
            self.controller.play(at: self.table.selectedRow)
        }
        table.onDelete = { [weak self] in self?.removeSelectedRows() }
        table.registerForDraggedTypes([playlistRowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Playlist")
        table.menu = contextMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let add = IconButton(.plus, label: "Add Files…") { [weak self] in self?.onAddFiles?() }
        let remove = IconButton(.minus, label: "Remove Selected") { [weak self] in self?.removeSelectedRows() }
        let clear = IconButton(.trash, label: "Clear Playlist") { [weak self] in self?.confirmClear() }
        repeatControl.segmentCount = 3
        repeatControl.trackingMode = .selectOne
        repeatControl.setLabel("Off", forSegment: 0)
        repeatControl.setImage(Symbol.repeatAll.image("Repeat all", size: 12), forSegment: 1)
        repeatControl.setImage(Symbol.repeatOne.image("Repeat one", size: 12), forSegment: 2)
        repeatControl.setToolTip("No repeat", forSegment: 0)
        repeatControl.setToolTip("Repeat playlist", forSegment: 1)
        repeatControl.setToolTip("Repeat current item", forSegment: 2)
        repeatControl.controlSize = .small
        repeatControl.setAccessibilityLabel("Repeat mode")
        repeatControl.onAction { [weak self] _ in
            guard let self else { return }
            self.controller.setRepeatMode([RepeatMode.off, .all, .one][self.repeatControl.selectedSegment])
        }
        let toolbar = hStack([add, remove, clear, flexibleSpacer(), repeatControl], spacing: 2)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        root.addSubview(toolbar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -Theme.spaceXS),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.spaceM),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.spaceM),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.spaceS),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
        ])
        controller.$playlist.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &bag)
        controller.player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.table.reloadData() }.store(in: &bag)
    }

    func reload() {
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        repeatControl.selectedSegment = [RepeatMode.off, .all, .one].firstIndex(of: controller.playlist.repeatMode) ?? 0
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Play") { [weak self] in self?.playClicked() })
        menu.addItem(
            NSMenuItem(title: "Show in Finder") { [weak self] in
                guard let self else { return }
                let urls = self.targetRows().map { URL(fileURLWithPath: self.items[$0]) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove from Playlist") { [weak self] in self?.removeSelected() })
        return menu
    }

    /// Rows affected by a context-menu action: the clicked row, or the selection.
    private func targetRows() -> [Int] {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return Array(table.selectedRowIndexes)
    }

    @objc func playClicked() {
        if let row = targetRows().first, items.indices.contains(row) { controller.play(at: row) }
    }

    /// Toolbar button and Delete key: the selection only (never a stale clicked row).
    func removeSelectedRows() {
        guard !table.selectedRowIndexes.isEmpty else { return }
        controller.removeFromPlaylist(table.selectedRowIndexes)
    }

    /// Context menu: the clicked row or the selection.
    func removeSelected() {
        let rows = IndexSet(targetRows())
        guard !rows.isEmpty else { return }
        controller.removeFromPlaylist(rows)
    }

    private func confirmClear() {
        guard !items.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the playlist?"
        alert.informativeText = "This removes \(items.count) item(s) from the playlist. Your files are not deleted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.controller.clearPlaylist() }
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let path = items[safe: row] else { return nil }
        let url = URL(fileURLWithPath: path)
        let record = controller.library.record(for: path)
        let isCurrent = controller.playlist.currentIndex == row
        let cell = MediaRowView(reuse: tableView)
        let missing = !FileManager.default.fileExists(atPath: path)
        var detail: [String] = []
        if let d = record?.duration { detail.append(Timecode.formatClock(seconds: d)) }
        if let r = record?.resolutionText { detail.append(r) }
        if missing { detail.append("File not found") }
        cell.configure(
            title: record?.title ?? url.deletingPathExtension().lastPathComponent,
            detail: detail.isEmpty ? url.deletingLastPathComponent().lastPathComponent : detail.joined(separator: " · "),
            symbol: MediaLibrary.audioExtensions.contains(url.pathExtension.lowercased()) ? .music : .film,
            highlighted: isCurrent, playing: isCurrent && controller.player.status == .playing, dimmed: missing)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: playlistRowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation op: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if let items = pb.pasteboardItems, let first = items.first?.string(forType: playlistRowType), let source = Int(first) {
            controller.movePlaylistItem(from: source, to: row)
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            controller.addToPlaylist(urls)
            return true
        }
        return false
    }
}

/// Two-line row: icon, title, secondary detail; used by playlist and library.
final class MediaRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = makeLabel("", font: Theme.font(13, .medium))
    private let detail = makeLabel("", font: Theme.captionFont, color: .secondaryLabelColor)
    let accessory = NSStackView()

    convenience init(reuse tableView: NSTableView) {
        self.init(frame: .zero)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        accessory.orientation = .horizontal
        accessory.spacing = 2
        let row = hStack([icon, text, flexibleSpacer(), accessory], spacing: Theme.spaceS)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String, symbol: Symbol, highlighted: Bool, playing: Bool, dimmed: Bool = false) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        icon.image = (playing ? Symbol.play : symbol).image(nil, size: 13)
        icon.contentTintColor = highlighted ? .controlAccentColor : .secondaryLabelColor
        self.title.textColor = dimmed ? .tertiaryLabelColor : highlighted ? .controlAccentColor : .labelColor
        setAccessibilityLabel("\(title), \(detail)\(highlighted ? ", current item" : "")")
    }
}
