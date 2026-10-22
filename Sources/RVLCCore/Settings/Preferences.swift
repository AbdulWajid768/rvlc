import Foundation

public enum ThemePreference: String, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public extension Notification.Name {
    /// Posted with `userInfo["key"]` naming the preference that changed.
    static let rvlcPreferencesDidChange = Notification.Name("RVLCPreferencesDidChange")
}

/// Typed, validated access to persisted user preferences.
///
/// Backed by `UserDefaults`; tests inject an isolated suite.
public final class Preferences {
    public enum Key: String, CaseIterable {
        case theme, volume, muted, hardwareDecoding, rememberPosition, autoLoadSubtitles
        case subtitleFontSize, subtitlePosition, subtitleBackground, subtitleStepMs, audioStepMs, seekStepSeconds
        case allowAmplification, normalizeAudio, keyBindings, sidebarVisible, sidebarTab, lastOpenDirectory
    }

    public static let stepChoicesMs = [100, 250, 500]
    public static let seekChoicesSeconds = [5, 10, 15]

    public let defaults: UserDefaults
    private let center: NotificationCenter

    public init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = notificationCenter
    }

    private func changed(_ key: Key) {
        center.post(name: .rvlcPreferencesDidChange, object: self, userInfo: ["key": key.rawValue])
    }

    private func set(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        changed(key)
    }

    private func int(_ key: Key, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let stored = defaults.object(forKey: key.rawValue) as? Int else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private func bool(_ key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    // MARK: Appearance

    public var theme: ThemePreference {
        get { ThemePreference(rawValue: defaults.string(forKey: Key.theme.rawValue) ?? "") ?? .system }
        set { set(newValue.rawValue, .theme) }
    }

    // MARK: Playback

    public var maxVolume: Double { allowAmplification ? 200 : 100 }

    public var volume: Double {
        get { min(max(defaults.object(forKey: Key.volume.rawValue) as? Double ?? 80, 0), maxVolume) }
        set { set(min(max(newValue, 0), maxVolume), .volume) }
    }

    public var muted: Bool {
        get { bool(.muted, default: false) }
        set { set(newValue, .muted) }
    }

    public var hardwareDecoding: Bool {
        get { bool(.hardwareDecoding, default: true) }
        set { set(newValue, .hardwareDecoding) }
    }

    public var rememberPosition: Bool {
        get { bool(.rememberPosition, default: true) }
        set { set(newValue, .rememberPosition) }
    }

    public var autoLoadSubtitles: Bool {
        get { bool(.autoLoadSubtitles, default: true) }
        set { set(newValue, .autoLoadSubtitles) }
    }

    public var seekStepSeconds: Int {
        get {
            let v = int(.seekStepSeconds, default: 5, in: 1...60)
            return Preferences.seekChoicesSeconds.contains(v) ? v : 5
        }
        set { set(newValue, .seekStepSeconds) }
    }

    // MARK: Audio

    /// Allows volume above 100 %. A limiter is inserted to prevent clipping.
    public var allowAmplification: Bool {
        get { bool(.allowAmplification, default: false) }
        set {
            set(newValue, .allowAmplification)
            if !newValue, volume > 100 { volume = 100 }
        }
    }

    public var normalizeAudio: Bool {
        get { bool(.normalizeAudio, default: false) }
        set { set(newValue, .normalizeAudio) }
    }

    // MARK: Subtitles

    /// mpv `sub-font-size` in scaled pixels (mpv default 38).
    public var subtitleFontSize: Int {
        get { int(.subtitleFontSize, default: 44, in: 16...100) }
        set { set(min(max(newValue, 16), 100), .subtitleFontSize) }
    }

    /// mpv `sub-pos`: vertical position in % of the screen height (100 = default bottom margin).
    public var subtitlePosition: Int {
        get { int(.subtitlePosition, default: 100, in: 0...100) }
        set { set(min(max(newValue, 0), 100), .subtitlePosition) }
    }

    /// Draw a translucent box behind subtitle text for readability.
    public var subtitleBackground: Bool {
        get { bool(.subtitleBackground, default: false) }
        set { set(newValue, .subtitleBackground) }
    }

    public var subtitleStepMs: Int {
        get {
            let v = int(.subtitleStepMs, default: 100, in: 1...5000)
            return Preferences.stepChoicesMs.contains(v) ? v : 100
        }
        set { set(newValue, .subtitleStepMs) }
    }

    public var audioStepMs: Int {
        get {
            let v = int(.audioStepMs, default: 100, in: 1...5000)
            return Preferences.stepChoicesMs.contains(v) ? v : 100
        }
        set { set(newValue, .audioStepMs) }
    }

    // MARK: Shortcuts

    public var keyMap: KeyMap {
        get { KeyMap(overrides: defaults.dictionary(forKey: Key.keyBindings.rawValue) as? [String: [String]] ?? [:]) }
        set {
            let overrides = newValue.overrides
            set(overrides.isEmpty ? nil : overrides, .keyBindings)
        }
    }

    // MARK: Window state

    public var sidebarVisible: Bool {
        get { bool(.sidebarVisible, default: false) }
        set { set(newValue, .sidebarVisible) }
    }

    public var sidebarTab: String {
        get { defaults.string(forKey: Key.sidebarTab.rawValue) ?? "playlist" }
        set { set(newValue, .sidebarTab) }
    }

    public var lastOpenDirectory: URL? {
        get { defaults.string(forKey: Key.lastOpenDirectory.rawValue).map { URL(fileURLWithPath: $0) } }
        set { set(newValue?.path, .lastOpenDirectory) }
    }

    public func resetAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        // Notify for every key so all observers re-apply their defaults.
        for key in Key.allCases { changed(key) }
    }
}
