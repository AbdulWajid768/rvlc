import CMpv
import Foundation

/// Explicit playback state derived from libmpv events (never from UI state).
public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case ended
    case error(String)

    public var hasMedia: Bool {
        switch self {
        case .playing, .paused, .ended: return true
        default: return false
        }
    }
}

public enum PlayerEvent: Equatable, Sendable {
    case fileLoaded(URL)
    case endOfFile
    case loadFailed(String)
}

public struct MPVError: LocalizedError, Equatable {
    public let code: Int32
    public let context: String

    public var errorDescription: String? {
        let message = String(cString: mpv_error_string(code))
        return "\(context): \(message)"
    }
}

/// A video, audio or subtitle track as reported by libmpv's `track-list`.
public struct MediaTrack: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case video, audio, sub }

    public var id: Int
    public var kind: Kind
    public var title: String?
    public var language: String?
    public var codec: String?
    public var isExternal: Bool
    public var externalPath: String?
    public var isSelected: Bool
    public var isDefault: Bool
    public var channels: Int?
    public var sampleRate: Int?
    public var width: Int?
    public var height: Int?
    public var fps: Double?

    init?(node: [String: Any]) {
        guard let id = node["id"] as? Int, let type = node["type"] as? String, let kind = Kind(rawValue: type) else { return nil }
        self.id = id
        self.kind = kind
        title = node["title"] as? String
        language = node["lang"] as? String
        codec = node["codec"] as? String
        isExternal = node["external"] as? Bool ?? false
        externalPath = node["external-filename"] as? String
        isSelected = node["selected"] as? Bool ?? false
        isDefault = node["default"] as? Bool ?? false
        channels = node["demux-channel-count"] as? Int
        sampleRate = node["demux-samplerate"] as? Int
        width = node["demux-w"] as? Int
        height = node["demux-h"] as? Int
        fps = node["demux-fps"] as? Double
    }

    public init(
        id: Int, kind: Kind, title: String? = nil, language: String? = nil, codec: String? = nil,
        isExternal: Bool = false, externalPath: String? = nil, isSelected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.isExternal = isExternal
        self.externalPath = externalPath
        self.isSelected = isSelected
        isDefault = false
    }

    /// Human-readable label, e.g. “English — AC-3 5.1” or “movie.en.srt (external)”.
    public var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append(title)
        } else if isExternal, let externalPath {
            parts.append(URL(fileURLWithPath: externalPath).lastPathComponent)
        }
        if let language, !language.isEmpty {
            let name = Locale.current.localizedString(forLanguageCode: language) ?? language
            if !parts.contains(name) { parts.append(name) }
        }
        var details: [String] = []
        if let codec { details.append(codec.uppercased()) }
        if let channels {
            details.append(
                channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "Stereo" : channels == 1 ? "Mono" : "\(channels) ch")
        }
        if let width, let height { details.append("\(width)×\(height)") }
        if parts.isEmpty { parts.append("Track \(id)") }
        var label = parts.joined(separator: " · ")
        if !details.isEmpty { label += " — " + details.joined(separator: " ") }
        if isExternal { label += " (external)" }
        return label
    }
}

/// Converts an `mpv_node` tree into Swift values.
enum MPVNode {
    static func value(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING:
            return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return Int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee else { return [Any]() }
            return (0..<Int(list.num)).map { value(list.values[$0]) as Any }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee else { return [String: Any]() }
            var map: [String: Any] = [:]
            for i in 0..<Int(list.num) {
                if let key = list.keys[i] { map[String(cString: key)] = value(list.values[i]) }
            }
            return map
        default:
            return nil
        }
    }
}
