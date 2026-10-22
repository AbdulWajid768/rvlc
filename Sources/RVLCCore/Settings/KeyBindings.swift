import Foundation

/// A keyboard shortcut independent of AppKit, e.g. `shift+left` or `z`.
public struct KeyCombo: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Modifier: String, Codable, CaseIterable, Sendable, Comparable {
        case control, option, shift, command
        public static func < (a: Modifier, b: Modifier) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    /// Lower-case key name: a single character ("z", "[", ".") or a named key
    /// ("space", "left", "right", "up", "down", "escape", "return", "backspace",
    /// "pageup", "pagedown", "home", "end", "f1"…).
    public var key: String
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses `"shift+left"`, `"cmd+o"`, `"z"`.
    public init?(string: String) {
        var text = string.lowercased().trimmingCharacters(in: .whitespaces)
        var plusKey = false
        // "+" as the key itself: "+", "shift++", "cmd++".
        if text == "+" {
            self.init("+")
            return
        } else if text.hasSuffix("++") {
            plusKey = true
            text = String(text.dropLast(2))
        }
        var parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        if plusKey { parts.append("+") }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "opt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        self.init(last, mods)
    }

    public var storageString: String {
        let names: [Modifier: String] = [.command: "cmd", .shift: "shift", .option: "alt", .control: "ctrl"]
        return (modifiers.sorted().map { names[$0]! } + [key]).joined(separator: "+")
    }

    static let keySymbols: [String: String] = [
        "space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "escape": "Esc",
        "return": "↩", "backspace": "⌫", "delete": "⌦", "pageup": "Page Up", "pagedown": "Page Down",
        "home": "Home", "end": "End", "tab": "⇥",
    ]

    /// macOS-style display, e.g. `⇧←` or `⌘O`.
    public var description: String {
        let keyText = KeyCombo.keySymbols[key] ?? key.uppercased()
        return modifiers.sorted().map(\.symbol).joined() + keyText
    }
}

/// Player commands that can be bound to keys and are configurable by the user.
public enum PlayerAction: String, CaseIterable, Codable, Sendable {
    case playPause, stop, previous, next
    case seekBackward, seekForward, seekBackwardSmall, seekForwardSmall, seekBackwardLarge, seekForwardLarge
    case frameBackStep, frameStep
    case volumeUp, volumeDown, mute
    case speedDown, speedUp, speedReset
    case toggleFullscreen, exitFullscreen
    case subtitleEarlier, subtitleLater, subtitleReset, toggleSubtitles, cycleSubtitle, setSyncPoint
    case audioEarlier, audioLater, audioReset, cycleAudio
    case showShortcuts

    public enum Category: String, CaseIterable, Sendable {
        case playback = "Playback", seeking = "Seeking", audio = "Volume & Speed", view = "View",
            subtitles = "Subtitle Sync", audioSync = "Audio Sync", help = "Help"
    }

    public var category: Category {
        switch self {
        case .playPause, .stop, .previous, .next: return .playback
        case .seekBackward, .seekForward, .seekBackwardSmall, .seekForwardSmall, .seekBackwardLarge, .seekForwardLarge,
            .frameBackStep, .frameStep:
            return .seeking
        case .volumeUp, .volumeDown, .mute, .speedDown, .speedUp, .speedReset: return .audio
        case .toggleFullscreen, .exitFullscreen: return .view
        case .subtitleEarlier, .subtitleLater, .subtitleReset, .toggleSubtitles, .cycleSubtitle, .setSyncPoint: return .subtitles
        case .audioEarlier, .audioLater, .audioReset, .cycleAudio: return .audioSync
        case .showShortcuts: return .help
        }
    }

    public var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .stop: return "Stop"
        case .previous: return "Previous item"
        case .next: return "Next item"
        case .seekBackward: return "Seek back (step)"
        case .seekForward: return "Seek forward (step)"
        case .seekBackwardSmall: return "Seek back 1 s"
        case .seekForwardSmall: return "Seek forward 1 s"
        case .seekBackwardLarge: return "Seek back 30 s"
        case .seekForwardLarge: return "Seek forward 30 s"
        case .frameBackStep: return "Previous frame"
        case .frameStep: return "Next frame"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute / Unmute"
        case .speedDown: return "Slower"
        case .speedUp: return "Faster"
        case .speedReset: return "Normal speed"
        case .toggleFullscreen: return "Toggle full screen"
        case .exitFullscreen: return "Exit full screen"
        case .subtitleEarlier: return "Subtitles earlier"
        case .subtitleLater: return "Subtitles later"
        case .subtitleReset: return "Reset subtitle offset"
        case .toggleSubtitles: return "Show / hide subtitles"
        case .cycleSubtitle: return "Next subtitle track"
        case .setSyncPoint: return "Sync selected line to now"
        case .audioEarlier: return "Audio earlier"
        case .audioLater: return "Audio later"
        case .audioReset: return "Reset audio delay"
        case .cycleAudio: return "Next audio track"
        case .showShortcuts: return "Keyboard shortcuts"
        }
    }
}

/// Mapping between actions and key combos with user overrides.
public struct KeyMap: Equatable, Sendable {
    public private(set) var bindings: [PlayerAction: [KeyCombo]]

    public static let defaults: [PlayerAction: [KeyCombo]] = [
        .playPause: [KeyCombo("space")],
        .stop: [KeyCombo(".", [.command])],
        .previous: [KeyCombo("p"), KeyCombo("pageup")],
        .next: [KeyCombo("n"), KeyCombo("pagedown")],
        .seekBackward: [KeyCombo("left")],
        .seekForward: [KeyCombo("right")],
        .seekBackwardSmall: [KeyCombo("left", [.shift])],
        .seekForwardSmall: [KeyCombo("right", [.shift])],
        .seekBackwardLarge: [KeyCombo("left", [.option])],
        .seekForwardLarge: [KeyCombo("right", [.option])],
        .frameBackStep: [KeyCombo(",")],
        .frameStep: [KeyCombo(".")],
        .volumeUp: [KeyCombo("up")],
        .volumeDown: [KeyCombo("down")],
        .mute: [KeyCombo("m")],
        .speedDown: [KeyCombo("[")],
        .speedUp: [KeyCombo("]")],
        .speedReset: [KeyCombo("backspace")],
        .toggleFullscreen: [KeyCombo("f")],
        .exitFullscreen: [KeyCombo("escape")],
        .subtitleEarlier: [KeyCombo("z")],
        .subtitleLater: [KeyCombo("x")],
        .subtitleReset: [KeyCombo("z", [.shift])],
        .toggleSubtitles: [KeyCombo("s")],
        .cycleSubtitle: [KeyCombo("j")],
        .setSyncPoint: [KeyCombo("y")],
        .audioEarlier: [KeyCombo("c")],
        .audioLater: [KeyCombo("v")],
        .audioReset: [KeyCombo("c", [.shift])],
        .cycleAudio: [KeyCombo("a")],
        .showShortcuts: [KeyCombo("/", [.shift]), KeyCombo("f1")],
    ]

    public init(overrides: [String: [String]] = [:]) {
        var map = KeyMap.defaults
        for (name, combos) in overrides {
            guard let action = PlayerAction(rawValue: name) else { continue }
            map[action] = combos.compactMap(KeyCombo.init(string:))
        }
        bindings = map
    }

    public func combos(for action: PlayerAction) -> [KeyCombo] { bindings[action] ?? [] }

    public func action(for combo: KeyCombo) -> PlayerAction? {
        // Deterministic lookup even if a user created a conflict.
        PlayerAction.allCases.first { bindings[$0]?.contains(combo) == true }
    }

    /// Actions sharing `combo`, excluding `action`.
    public func conflicts(for combo: KeyCombo, excluding action: PlayerAction) -> [PlayerAction] {
        PlayerAction.allCases.filter { $0 != action && bindings[$0]?.contains(combo) == true }
    }

    public mutating func set(_ combos: [KeyCombo], for action: PlayerAction) {
        bindings[action] = combos
    }

    /// Only bindings that differ from the defaults, for persistence.
    public var overrides: [String: [String]] {
        var result: [String: [String]] = [:]
        for action in PlayerAction.allCases where bindings[action] != KeyMap.defaults[action] {
            result[action.rawValue] = (bindings[action] ?? []).map(\.storageString)
        }
        return result
    }
}
