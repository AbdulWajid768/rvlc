import AppKit
import Combine
import RVLCCore

/// Recently played and favourite media with search, sorting and resume info.
final class LibraryPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let controller: PlayerController
    private let scope = NSSegmentedControl(labels: ["Recent", "Favorites"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let table = ActionTableView()
    private let emptyLabel = makeLabel("", font: Theme.bodyFont, color: .secondaryLabelColor, wraps: true)
    private var rows: [MediaRecord] = []
    private var bag = Set<AnyCancellable>()

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        view = root
        scope.selectedSegment = 0
        scope.onAction { [weak self] _ in self?.reload() }
        scope.setAccessibilityLabel("Library section")
        scope.setToolTip("Files you played recently", forSegment: 0)
        scope.setToolTip("Files you marked with a star", forSegment: 1)
        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = true
        search.onAction { [weak self] _ in self?.reload() }
        search.setAccessibilityLabel("Search library")
        sortPopup.addItems(withTitles: MediaLibrary.SortOrder.allCases.map(\.rawValue))
        sortPopup.controlSize = .small
        sortPopup.onAction { [weak self] _ in self?.reload() }
        sortPopup.setAccessibilityLabel("Sort order")
        sortPopup.toolTip = "Sort order"

        let column = NSTableColumn(identifier: .init("record"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.onReturn = { [weak self] in
            guard let self, let record = self.rows[safe: self.table.selectedRow] else { return }
            self.open(record)
        }
        table.menu = contextMenu()
        table.setAccessibilityLabel("Library")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        let header = NSStackView(views: [
            scope, search,
            hStack([makeLabel("Sort by", font: Theme.captionFont, color: .secondaryLabelColor), sortPopup, flexibleSpacer()]),
        ])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Theme.spaceS
        for v in [header, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.spaceL),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.spaceL),
            search.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.spaceS),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
        ])
        controller.player.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &bag)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    func reload() {
        let favorites = scope.selectedSegment == 1
        let base = favorites ? controller.library.favorites() : controller.library.recent()
        let sort = MediaLibrary.SortOrder.allCases[max(0, sortPopup.indexOfSelectedItem)]
        rows = controller.library.search(search.stringValue, in: base, sort: sort)
        table.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if !search.stringValue.isEmpty {
            emptyLabel.stringValue = "No matches for “\(search.stringValue)”."
        } else {
            emptyLabel.stringValue =
                favorites ? "No favorites yet.\nStar items to keep them here." : "Nothing played yet.\nFiles you open appear here."
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Play") { [weak self] in self?.openClicked() })
        menu.addItem(
            NSMenuItem(title: "Play from Beginning") { [weak self] in
                guard let self, let r = self.clickedRecord() else { return }
                self.controller.open([r.url], fromStart: true)
            })
        menu.addItem(
            NSMenuItem(title: "Add to Playlist") { [weak self] in
                guard let self, let r = self.clickedRecord() else { return }
                self.controller.addToPlaylist([r.url])
            })
        menu.addItem(
            NSMenuItem(title: "Toggle Favorite") { [weak self] in
                guard let self, let r = self.clickedRecord() else { return }
                self.controller.library.setFavorite(r.path, !r.favorite)
                self.reload()
            })
        menu.addItem(
            NSMenuItem(title: "File Info…") { [weak self] in
                guard let self, let r = self.clickedRecord(), let window = self.view.window else { return }
                FileInfoPresenter.present(record: r, player: nil, in: window)
            })
        menu.addItem(
            NSMenuItem(title: "Show in Finder") { [weak self] in
                guard let r = self?.clickedRecord() else { return }
                NSWorkspace.shared.activateFileViewerSelecting([r.url])
            })
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Remove from History") { [weak self] in
                guard let self, let r = self.clickedRecord() else { return }
                self.controller.library.removeFromHistory(r.path)
                self.reload()
            })
        return menu
    }

    private func clickedRecord() -> MediaRecord? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows[safe: row]
    }

    @objc private func openClicked() {
        guard let record = clickedRecord() else { return }
        open(record)
    }

    private func open(_ record: MediaRecord) {
        guard FileManager.default.fileExists(atPath: record.path) else {
            controller.osd.send("“\(record.title)” can no longer be found.")
            return
        }
        controller.open([record.url])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let record = rows[safe: row] else { return nil }
        let cell = MediaRowView(reuse: tableView)
        var detail: [String] = []
        if let d = record.duration { detail.append(Timecode.formatClock(seconds: d)) }
        if let r = record.resolutionText { detail.append(r) }
        if let p = record.position, p > 0 { detail.append("Resume at \(Timecode.formatClock(seconds: p))") }
        if let date = record.lastPlayed {
            detail.append(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
        }
        let missing = !FileManager.default.fileExists(atPath: record.path)
        if missing { detail.insert("Missing", at: 0) }
        cell.configure(
            title: record.title, detail: detail.joined(separator: " · "),
            symbol: MediaLibrary.audioExtensions.contains(record.url.pathExtension.lowercased()) ? .music : .film,
            highlighted: controller.player.currentURL?.path == record.path, playing: false, dimmed: missing)
        let star = IconButton(
            record.favorite ? .starFill : .star, label: record.favorite ? "Remove from Favorites" : "Add to Favorites", size: 12
        ) { [weak self] in
            self?.controller.library.setFavorite(record.path, !record.favorite)
            self?.reload()
        }
        star.contentTintColor = record.favorite ? .systemYellow : .tertiaryLabelColor
        cell.accessory.addArrangedSubview(star)
        return cell
    }
}
