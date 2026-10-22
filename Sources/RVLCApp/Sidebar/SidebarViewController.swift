import AppKit
import Combine
import RVLCCore

enum SidebarTab: String, CaseIterable {
    case playlist, library, subtitles, audio, adjust

    var title: String {
        switch self {
        case .playlist: return "Playlist"
        case .library: return "Library"
        case .subtitles: return "Subtitle Studio"
        case .audio: return "Audio Sync Lab"
        case .adjust: return "Picture & Sound"
        }
    }

    var symbol: Symbol {
        switch self {
        case .playlist: return .playlist
        case .library: return .library
        case .subtitles: return .subtitles
        case .audio: return .audioTrack
        case .adjust: return .adjust
        }
    }
}

/// Right-hand panel with a segmented switcher between tools.
final class SidebarViewController: NSViewController {
    let controller: PlayerController
    private let segmented = NSSegmentedControl()
    private let titleLabel = makeLabel("", font: Theme.titleFont)
    private let container = NSView()
    private var panels: [SidebarTab: NSViewController] = [:]
    private(set) var current: SidebarTab = .playlist
    var onOpenFiles: (() -> Void)?
    var onOpenSubtitle: (() -> Void)?
    var onOpenAudio: (() -> Void)?
    var onOpenEditor: (() -> Void)?

    init(controller: PlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root

        segmented.segmentCount = SidebarTab.allCases.count
        segmented.trackingMode = .selectOne
        segmented.segmentStyle = .automatic
        for (i, tab) in SidebarTab.allCases.enumerated() {
            segmented.setImage(tab.symbol.image(tab.title, size: 13), forSegment: i)
            segmented.setToolTip("\(tab.title) (⌘\(i + 1))", forSegment: i)
            segmented.setWidth(44, forSegment: i)
        }
        segmented.setAccessibilityLabel("Sidebar section")
        segmented.onAction { [weak self] _ in
            guard let self else { return }
            self.show(SidebarTab.allCases[self.segmented.selectedSegment])
        }
        segmented.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(segmented)
        root.addSubview(titleLabel)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Theme.spaceS),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: Theme.spaceM),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.spaceL),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Theme.spaceL),
            container.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Theme.spaceS),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        show(SidebarTab(rawValue: controller.preferences.sidebarTab) ?? .playlist)
    }

    func panel(_ tab: SidebarTab) -> NSViewController {
        if let existing = panels[tab] { return existing }
        let vc: NSViewController
        switch tab {
        case .playlist:
            let p = PlaylistPanel(controller: controller)
            p.onAddFiles = { [weak self] in self?.onOpenFiles?() }
            vc = p
        case .library: vc = LibraryPanel(controller: controller)
        case .subtitles:
            let s = SubtitleStudioPanel(controller: controller)
            s.onOpenSubtitle = { [weak self] in self?.onOpenSubtitle?() }
            s.onOpenEditor = { [weak self] in self?.onOpenEditor?() }
            vc = s
        case .audio:
            let a = AudioSyncPanel(controller: controller)
            a.onOpenAudio = { [weak self] in self?.onOpenAudio?() }
            vc = a
        case .adjust: vc = AdjustPanel(controller: controller)
        }
        panels[tab] = vc
        addChild(vc)
        return vc
    }

    func show(_ tab: SidebarTab) {
        current = tab
        segmented.selectedSegment = SidebarTab.allCases.firstIndex(of: tab) ?? 0
        titleLabel.stringValue = tab.title
        controller.preferences.sidebarTab = tab.rawValue
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = panel(tab).view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// Vertical scrolling container for panels made of stacked cards.
final class PanelScrollView: NSScrollView {
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.spaceM
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: Theme.spaceXS),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Theme.spaceL),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Theme.spaceL),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Theme.spaceL),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ view: NSView) {
        view.allowHorizontalShrinking()
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
