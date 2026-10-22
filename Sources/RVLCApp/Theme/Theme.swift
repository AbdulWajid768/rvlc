import AppKit
import RVLCCore

/// Design tokens for RVLC.
///
/// The interface is built from macOS semantic colours (label, separator,
/// control accent…) so light, dark and high-contrast appearances work
/// everywhere automatically. Only a handful of brand values live here.
enum Theme {
    // MARK: Spacing (4-pt grid)
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 24

    static let cornerRadius: CGFloat = 8
    static let controlBarHeight: CGFloat = 76
    static let sidebarWidth: CGFloat = 340
    static let minimumWindowSize = NSSize(width: 520, height: 360)

    // MARK: Typography
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static let titleFont = font(15, .semibold)
    static let headlineFont = font(13, .semibold)
    static let bodyFont = font(13)
    static let captionFont = font(11)
    static let sectionFont = font(11, .semibold)
    /// Tabular digits keep time and offset readouts from jittering.
    static let monoDigits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold)

    // MARK: Colour
    /// Brand indigo used for the logo and empty state accents.
    static let brand = NSColor(name: "RVLCBrand") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.49, green: 0.56, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.27, green: 0.33, blue: 0.86, alpha: 1)
    }
    static let videoBackground = NSColor.black
    static let positive = NSColor.systemGreen
    static let warning = NSColor.systemOrange
    static let danger = NSColor.systemRed

    // MARK: Appearance

    static func apply(_ preference: ThemePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// SF Symbols used across the app, in one place for consistency.
enum Symbol: String {
    case play = "play.fill"
    case pause = "pause.fill"
    case stop = "stop.fill"
    case previous = "backward.end.fill"
    case next = "forward.end.fill"
    case seekBack = "gobackward.10"
    case seekForward = "goforward.10"
    case seekBack5 = "gobackward.5"
    case seekForward5 = "goforward.5"
    case seekBack15 = "gobackward.15"
    case seekForward15 = "goforward.15"
    case volumeHigh = "speaker.wave.3.fill"
    case volumeMid = "speaker.wave.2.fill"
    case volumeLow = "speaker.wave.1.fill"
    case volumeMuted = "speaker.slash.fill"
    case fullscreen = "arrow.up.left.and.arrow.down.right"
    case exitFullscreen = "arrow.down.right.and.arrow.up.left"
    case subtitles = "captions.bubble"
    case audioTrack = "waveform"
    case speed = "gauge.with.dots.needle.50percent"
    case sidebar = "sidebar.right"
    case playlist = "list.bullet"
    case library = "rectangle.stack"
    case adjust = "slider.horizontal.3"
    case folder = "folder"
    case file = "doc"
    case plus = "plus"
    case minus = "minus"
    case trash = "trash"
    case star = "star"
    case starFill = "star.fill"
    case info = "info.circle"
    case warning = "exclamationmark.triangle.fill"
    case wand = "wand.and.stars"
    case target = "scope"
    case reset = "arrow.counterclockwise"
    case export = "square.and.arrow.up"
    case edit = "pencil"
    case close = "xmark"
    case repeatAll = "repeat"
    case repeatOne = "repeat.1"
    case film = "film"
    case music = "music.note"
    case headphones = "headphones"
    case eye = "eye"
    case eyeSlash = "eye.slash"
    case search = "magnifyingglass"
    case findLine = "text.magnifyingglass"
    case chevronDown = "chevron.down"
    case clock = "clock"
    case keyboard = "keyboard"
    case checkmark = "checkmark.circle.fill"

    /// Seek icon whose number matches the configured step (5, 10 or 15 s).
    static func seek(forward: Bool, seconds: Int) -> Symbol {
        switch seconds {
        case 5: return forward ? .seekForward5 : .seekBack5
        case 15: return forward ? .seekForward15 : .seekBack15
        default: return forward ? .seekForward : .seekBack
        }
    }

    func image(_ description: String? = nil, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image =
            NSImage(systemSymbolName: rawValue, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: description)!
        return image.withSymbolConfiguration(config) ?? image
    }
}
