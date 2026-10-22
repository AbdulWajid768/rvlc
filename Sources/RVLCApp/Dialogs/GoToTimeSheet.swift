import AppKit
import RVLCCore

/// “Go to Time…” sheet: type a time and jump there exactly.
final class GoToTimeSheet: NSWindowController, NSTextFieldDelegate {
    let field = NSTextField()
    private let errorLabel = makeLabel("", font: Theme.captionFont, color: Theme.danger, wraps: true)
    private let duration: Double
    private let onGo: (Double) -> Void
    private var goButton: NSButton!

    init(current: Double, duration: Double, onGo: @escaping (Double) -> Void) {
        self.duration = duration
        self.onGo = onGo
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Go to Time"
        super.init(window: panel)

        let title = makeLabel("Go to time", font: Theme.headlineFont)
        let hint = makeLabel(
            "Between 0:00 and \(Timecode.formatClock(seconds: duration)). Examples: 83, 1:23, 1:02:03.",
            font: Theme.captionFont, color: .secondaryLabelColor, wraps: true)
        field.stringValue = Timecode.formatClock(seconds: current)
        field.placeholderString = "1:23"
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        field.setAccessibilityLabel("Time to go to")
        field.delegate = self
        errorLabel.isHidden = true
        let cancel = makeButton("Cancel", tip: "Close without jumping (Esc)") { [weak self] in self?.close(returnCode: .cancel) }
        cancel.keyEquivalent = "\u{1b}"
        goButton = makeButton("Go", tip: "Jump to this time (Return)") { [weak self] in self?.go() }
        goButton.keyEquivalent = "\r"
        let buttons = hStack([flexibleSpacer(), cancel, goButton], spacing: Theme.spaceS)

        let stack = NSStackView(views: [title, hint, field, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.spaceS
        stack.edgeInsets = NSEdgeInsets(top: Theme.spaceL, left: Theme.spaceL, bottom: Theme.spaceL, right: Theme.spaceL)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.spaceL),
            hint.widthAnchor.constraint(equalTo: field.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: field.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        panel.initialFirstResponder = field
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Validates and jumps; on invalid input the sheet stays open with an explanation.
    func go() {
        do {
            let seconds = try Timecode.parseGoTo(field.stringValue, duration: duration)
            onGo(seconds)
            close(returnCode: .OK)
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            NSAccessibility.post(
                element: errorLabel, notification: .announcementRequested,
                userInfo: [.announcement: error.localizedDescription, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            NSSound.beep()
        }
    }

    func controlTextDidChange(_ obj: Notification) { errorLabel.isHidden = true }

    private func close(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: returnCode) } else { window.close() }
    }
}
