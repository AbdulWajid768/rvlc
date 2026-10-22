import AppKit
import RVLCCore

/// Routes key presses to player actions through a single local event monitor.
///
/// Player shortcuts are mostly single keys (Space, arrows, Z/X…), which must
/// never interfere with typing or with keyboard navigation of focused
/// controls. The router therefore declines a key when the focused view owns it:
/// * any text input (search fields, subtitle text, time fields),
/// * navigation keys in tables and lists,
/// * arrows/space in sliders, pop-ups and segmented controls,
/// * Space/Return on a keyboard-focused button (Full Keyboard Access).
final class KeyboardRouter {
    private var monitor: Any?
    private let controller: PlayerController
    /// Windows in which player shortcuts are active.
    var isEligibleWindow: (NSWindow) -> Bool = { _ in true }

    init(controller: PlayerController) {
        self.controller = controller
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, isEligibleWindow(window), window.attachedSheet == nil else { return false }
        guard let combo = Self.combo(for: event) else { return false }
        guard let action = controller.keyMap.action(for: combo) else { return false }
        if Self.responderOwnsKey(window.firstResponder, combo: combo) { return false }
        return controller.perform(action)
    }

    static let navigationKeys: Set<String> = ["up", "down", "left", "right", "home", "end", "pageup", "pagedown", "space", "return", "tab"]

    static func responderOwnsKey(_ responder: NSResponder?, combo: KeyCombo) -> Bool {
        guard let responder else { return false }
        // Text editing: the field editor (NSTextView) or any editable text control.
        // Command shortcuts (e.g. ⌘. Stop) still work while typing; everything else belongs to the text.
        if let textView = responder as? NSTextView, textView.isEditable || textView.isFieldEditor {
            return !combo.modifiers.contains(.command)
        }
        if let field = responder as? NSTextField, field.isEditable { return !combo.modifiers.contains(.command) }
        if responder is KeyRecorderField { return true }
        let isNavigation = navigationKeys.contains(combo.key) && combo.modifiers.subtracting([.shift]).isEmpty
        if responder is NSTableView || responder is NSOutlineView || responder is NSCollectionView {
            // Lists keep navigation, Return (activate) and Delete (remove); Space still plays/pauses.
            let listKeys = combo.modifiers.isEmpty && (combo.key == "backspace" || combo.key == "delete")
            return (isNavigation && combo.key != "space") || listKeys
        }
        if responder is NSSlider || responder is NSPopUpButton || responder is NSSegmentedControl || responder is NSStepper {
            return isNavigation
        }
        if responder is NSButton {
            return combo.key == "space" || combo.key == "return"
        }
        return false
    }

    /// Converts an AppKit key event into a `KeyCombo`.
    static func combo(for event: NSEvent) -> KeyCombo? {
        var mods: Set<KeyCombo.Modifier> = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        guard let key = keyName(for: event) else { return nil }
        return KeyCombo(key, mods)
    }

    static func keyName(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case 49: return "space"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 53: return "escape"
        case 36, 76: return "return"
        case 51: return "backspace"
        case 117: return "delete"
        case 116: return "pageup"
        case 121: return "pagedown"
        case 115: return "home"
        case 119: return "end"
        case 48: return "tab"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        default: break
        }
        // Use the unshifted character so "shift+/" is stored rather than "?".
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.first else { return nil }
        if event.modifierFlags.contains(.shift), let base = shiftedBase[first] { return String(base) }
        return String(first)
    }

    private static let shiftedBase: [Character: Character] = [
        "?": "/", "<": ",", ">": ".", "{": "[", "}": "]", "+": "=", "_": "-", ":": ";", "\"": "'", "|": "\\", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]
}

/// A field that records a key combination (used in Settings › Shortcuts).
final class KeyRecorderField: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var onRecord: ((KeyCombo?) -> Void)?
    private var recording = false { didSet { updateTitle() } }

    init(combo: KeyCombo?) {
        self.combo = combo
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = recording ? "Press keys…" : (combo?.description ?? "None")
        setAccessibilityLabel(recording ? "Recording shortcut, press a key or Escape to cancel" : "Shortcut \(title)")
    }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        recording = false
        if event.keyCode == 53 { return }  // Escape cancels
        if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            combo = nil  // Backspace clears
            onRecord?(nil)
            return
        }
        if let c = KeyboardRouter.combo(for: event) {
            combo = c
            onRecord?(c)
        }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
}
