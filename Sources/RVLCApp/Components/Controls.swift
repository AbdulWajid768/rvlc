import AppKit
import RVLCCore

/// Closure-based target/action so every control owns exactly one action.
final class ActionTrampoline: NSObject {
    let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

private var trampolineKey: UInt8 = 0

extension NSControl {
    /// Attaches a single closure action (replacing any previous one).
    func onAction(_ handler: @escaping (Any?) -> Void) {
        let trampoline = ActionTrampoline(handler)
        objc_setAssociatedObject(self, &trampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
        target = trampoline
        action = #selector(ActionTrampoline.fire(_:))
    }
}

extension NSMenuItem {
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(ActionTrampoline.fire(_:)), keyEquivalent: "")
        let trampoline = ActionTrampoline { _ in handler() }
        objc_setAssociatedObject(self, &trampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
        target = trampoline
    }

    /// Shows a single-key shortcut right-aligned without registering it as a
    /// key equivalent (single-key equivalents would steal typing in text fields;
    /// those shortcuts are routed by `KeyboardRouter` instead).
    func showShortcutHint(_ combo: KeyCombo?) {
        guard let combo else { return }
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
        let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        text.append(
            NSAttributedString(
                string: combo.description,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
                ]))
        attributedTitle = text
    }
}

/// Borderless icon button with tooltip and accessibility label.
final class IconButton: NSButton {
    var symbol: Symbol { didSet { updateImage() } }
    private let pointSize: CGFloat
    private let label: String

    init(_ symbol: Symbol, label: String, size: CGFloat = 15, handler: @escaping () -> Void) {
        self.symbol = symbol
        self.pointSize = size
        self.label = label
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .labelColor
        toolTip = label
        setAccessibilityLabel(label)
        // Clicking must not steal keyboard focus from the player (Space would
        // otherwise re-trigger this button instead of play/pause).
        refusesFirstResponder = true
        updateImage()
        onAction { _ in handler() }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        image = symbol.image(label, size: pointSize)
    }

    func setToolTip(_ text: String, shortcut: KeyCombo?) {
        toolTip = shortcut.map { "\(text) (\($0))" } ?? text
        setAccessibilityLabel(text)
    }
}

/// A rounded, subtly bordered container used for sections in side panels.
final class CardView: NSView {
    let stack = NSStackView()

    init(title: String? = nil, spacing: CGFloat = Theme.spaceS) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.cornerRadius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.spaceM),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.spaceM),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.spaceM),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.spaceM),
        ])
        if let title { stack.addArrangedSubview(SectionLabel(title)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Adds a view that stretches to the card width.
    func addFull(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

final class SectionLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text.uppercased()
        font = Theme.sectionFont
        textColor = .secondaryLabelColor
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }
}

func makeLabel(_ text: String, font: NSFont = Theme.bodyFont, color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
    let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    if !wraps { label.lineBreakMode = .byTruncatingMiddle }
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// A text button. `tip` is its hover tooltip; every button has one.
func makeButton(
    _ title: String, symbol: Symbol? = nil, style: NSButton.BezelStyle = .rounded, tip: String? = nil, handler: @escaping () -> Void
) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = style
    button.toolTip = tip ?? title
    if let symbol {
        // The image is described by the title so VoiceOver reads “Open File…”, not the symbol name.
        button.image = symbol.image(title, size: 12)
        button.imagePosition = .imageLeading
    }
    button.onAction { _ in handler() }
    return button
}

extension NSView {
    /// Lets text and pop-up menus in this view shrink with their container
    /// instead of widening it: labels wrap or truncate, pop-ups truncate their
    /// titles (before neighbouring labels do). Used by the sidebar, whose width
    /// is set only by the user's divider, never by the panel being shown.
    func allowHorizontalShrinking() {
        for view in subviews { view.allowHorizontalShrinking() }
        let target: NSLayoutConstraint.Priority
        switch self {
        case is NSPopUpButton: target = .init(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        case let field as NSTextField:
            target = .defaultLow
            if field.cell?.wraps == false, field.lineBreakMode == .byClipping { field.lineBreakMode = .byTruncatingTail }
        default: return
        }
        if contentCompressionResistancePriority(for: .horizontal) > target {
            setContentCompressionResistancePriority(target, for: .horizontal)
        }
    }
}

func hStack(_ views: [NSView], spacing: CGFloat = Theme.spaceS, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = spacing
    stack.alignment = alignment
    return stack
}

func flexibleSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return v
}

/// Shared control for signed millisecond offsets (subtitle offset, audio delay).
///
/// Shows a large signed readout, an explanation of what the current value
/// means, quick-adjust buttons, an exact numeric field and a reset button.
final class OffsetControl: NSView {
    struct Wording {
        var positive: String  // e.g. "Subtitles appear %@ later"
        var negative: String
        var zero: String
    }

    private let readout = NSTextField(labelWithString: "+0.000 s")
    private let explanation = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let wording: Wording
    private let onChange: (Int) -> Void
    private(set) var value = 0
    var range = -600_000...600_000

    init(wording: Wording, steps: [Int] = [500, 250, 100], accessibilityName: String, onChange: @escaping (Int) -> Void) {
        self.wording = wording
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        readout.font = Theme.readoutFont
        readout.alignment = .center
        readout.setAccessibilityLabel(accessibilityName)
        explanation.font = Theme.captionFont
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .center
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 2

        var minus: [NSView] = []
        var plus: [NSView] = []
        // Two rows, smallest step first, so −100 sits above +100 and the control
        // fits the narrowest sidebar.
        for step in steps.sorted() {
            let m = NSButton(title: "−\(step)", target: nil, action: nil)
            m.bezelStyle = .rounded
            m.controlSize = .small
            m.toolTip = String(format: wording.negative, "\(step) ms") + " (−\(step) ms)"
            m.setAccessibilityLabel("Decrease \(accessibilityName.lowercased()) by \(step) milliseconds")
            m.onAction { [weak self] _ in self?.nudge(-step) }
            minus.append(m)
            let p = NSButton(title: "+\(step)", target: nil, action: nil)
            p.bezelStyle = .rounded
            p.controlSize = .small
            p.toolTip = String(format: wording.positive, "\(step) ms") + " (+\(step) ms)"
            p.setAccessibilityLabel("Increase \(accessibilityName.lowercased()) by \(step) milliseconds")
            p.onAction { [weak self] _ in self?.nudge(step) }
            plus.append(p)
        }
        let minusRow = hStack(minus, spacing: 4)
        let plusRow = hStack(plus, spacing: 4)
        let quick = NSStackView(views: [minusRow, plusRow])
        quick.orientation = .vertical
        quick.spacing = 4
        for row in [minusRow, plusRow] {
            row.distribution = .fillEqually
            row.widthAnchor.constraint(equalTo: quick.widthAnchor).isActive = true
        }

        field.placeholderString = "ms"
        field.alignment = .right
        field.font = Theme.monoDigits
        field.controlSize = .small
        field.setAccessibilityLabel("\(accessibilityName) in milliseconds")
        field.toolTip = "Type an exact value in milliseconds and press Return (negative = earlier)"
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.onAction { [weak self] _ in self?.commitField() }
        let msLabel = makeLabel("ms", font: Theme.captionFont, color: .secondaryLabelColor)
        let reset = makeButton("Reset", symbol: .reset, tip: "Reset \(accessibilityName.lowercased()) to zero") { [weak self] in
            self?.setValue(0, notify: true)
        }
        reset.controlSize = .small
        reset.setAccessibilityLabel("Reset \(accessibilityName.lowercased()) to zero")
        let exact = hStack(
            [makeLabel("Exact:", font: Theme.captionFont, color: .secondaryLabelColor), field, msLabel, flexibleSpacer(), reset], spacing: 6
        )

        let stack = NSStackView(views: [readout, explanation, quick, exact])
        stack.orientation = .vertical
        stack.spacing = Theme.spaceS
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            quick.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exact.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    func nudge(_ delta: Int) { setValue(value + delta, notify: true) }

    func setValue(_ newValue: Int, notify: Bool) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let changed = clamped != value
        value = clamped
        render()
        if notify, changed || newValue == 0 { onChange(value) }
    }

    private func commitField() {
        let text = field.stringValue.replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        guard let ms = Int(text) else {
            NSSound.beep()
            render()
            return
        }
        setValue(ms, notify: true)
        // Hand the keyboard back to the player so shortcuts (Space, Z/X…) work again.
        // Deferred: after the action AppKit re-selects the field's text, which would
        // otherwise keep it focused.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, let editor = self?.field.currentEditor(), window.firstResponder === editor else { return }
            window.makeFirstResponder(nil)
        }
    }

    private func render() {
        readout.stringValue = formatOffset(value)
        readout.textColor = value == 0 ? .labelColor : .controlAccentColor
        let amount = String(format: "%.3f s", Double(abs(value)) / 1000)
        if value > 0 {
            explanation.stringValue = String(format: wording.positive, amount)
        } else if value < 0 {
            explanation.stringValue = String(format: wording.negative, amount)
        } else {
            explanation.stringValue = wording.zero
        }
        if field.currentEditor() == nil { field.stringValue = String(value) }
        readout.setAccessibilityValue("\(formatOffset(value)). \(explanation.stringValue)")
    }
}

/// Transient on-screen message shown over the video (volume, offsets, errors).
final class OSDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 8
        alphaValue = 0
        translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.font(14, .medium)
        label.textColor = .white
        // Several stacked messages, and long error messages, wrap instead of overflowing.
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 520
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String { label.stringValue }

    private var lines: [String] = []
    private var lastShown = Date.distantPast

    /// Shows a message. Messages arriving together (e.g. “Resumed at 0:12” and
    /// “Subtitles: movie.srt” when a file opens) are stacked instead of
    /// replacing each other; a repeated kind of message (volume, offsets)
    /// replaces its previous value.
    func show(_ message: String, duration: TimeInterval = 1.6) {
        let recent = Date().timeIntervalSince(lastShown) < 1.2 && alphaValue > 0
        if !recent { lines = [] }
        let kind = Self.kind(of: message)
        if let last = lines.last, Self.kind(of: last) == kind {
            lines[lines.count - 1] = message
        } else {
            lines.append(message)
        }
        lines = Array(lines.suffix(3))
        lastShown = Date()
        label.stringValue = lines.joined(separator: "\n")
        setAccessibilityLabel(label.stringValue)
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }
            self?.lines = []
        }
        hideWork = work
        // Longer text stays a little longer so it can be read.
        let readingTime = duration + Double(max(0, label.stringValue.count - 40)) * 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + min(readingTime, 6), execute: work)
    }

    /// Text before the first value, e.g. “Volume ” or “Subtitle offset ”.
    static func kind(of message: String) -> String {
        String(message.prefix { !$0.isNumber && $0 != "+" && $0 != "−" && $0 != "-" })
    }
}

/// Table view with keyboard actions: Return activates, Delete removes.
final class ActionTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let code = Int(event.keyCode)
        // (A `case a, b where …` clause would apply the condition to `b` only.)
        if plain, selectedRow >= 0 {
            if code == 36 || code == 76, let onReturn {
                onReturn()
                return
            }
            if code == 51 || code == 117, let onDelete {
                onDelete()
                return
            }
        }
        super.keyDown(with: event)
    }
}
