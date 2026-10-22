import Foundation

/// Everything RVLC remembers about a media file. Stored locally only.
public struct MediaRecord: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var title: String
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var fileSize: Int64?
    public var addedAt: Date
    public var lastPlayed: Date?
    public var playCount: Int
    /// Last playback position in seconds (nil when finished or never played).
    public var position: Double?
    public var favorite: Bool
    /// Per-file audio delay in milliseconds (positive = audio later).
    public var audioDelayMs: Int
    /// Per-file subtitle offset in milliseconds (positive = subtitles later).
    public var subtitleOffsetMs: Int
    /// External subtitle file last used with this media.
    public var subtitlePath: String?
    /// Drift correction (subtitle timestamp scale) used with `subtitlePath`; nil means 1.
    public var subtitleScale: Double?

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, title: String? = nil, addedAt: Date = Date()) {
        self.path = path
        self.title = title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.addedAt = addedAt
        playCount = 0
        favorite = false
        audioDelayMs = 0
        subtitleOffsetMs = 0
    }

    public var resolutionText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// Fraction watched (0…1) for progress indicators.
    public var progress: Double? {
        guard let position, let duration, duration > 0 else { return nil }
        return min(1, max(0, position / duration))
    }
}

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// An ordered play queue.
public struct Playlist: Codable, Equatable, Sendable {
    public private(set) var items: [String] = []
    public var currentIndex: Int?
    public var repeatMode: RepeatMode = .off

    public init(items: [String] = [], currentIndex: Int? = nil) {
        self.items = items
        self.currentIndex = currentIndex
    }

    public var current: String? { currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    public var isEmpty: Bool { items.isEmpty }

    /// Appends paths, skipping ones already queued. Returns the index of the first given path.
    @discardableResult
    public mutating func append(_ paths: [String]) -> Int? {
        var first: Int?
        for path in paths {
            if let existing = items.firstIndex(of: path) {
                first = first ?? existing
            } else {
                items.append(path)
                first = first ?? items.count - 1
            }
        }
        return first
    }

    public mutating func remove(at offsets: IndexSet) {
        let current = self.current
        for index in offsets.sorted(by: >) where items.indices.contains(index) { items.remove(at: index) }
        currentIndex = current.flatMap { items.firstIndex(of: $0) }
    }

    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let current = self.current
        let item = items.remove(at: source)
        let target = min(max(0, destination > source ? destination - 1 : destination), items.count)
        items.insert(item, at: target)
        currentIndex = current.flatMap { items.firstIndex(of: $0) }
    }

    public mutating func clear() {
        items.removeAll()
        currentIndex = nil
    }

    public func nextIndex(afterEnd: Bool = false) -> Int? {
        guard !items.isEmpty else { return nil }
        if afterEnd, repeatMode == .one, let currentIndex { return currentIndex }
        guard let currentIndex else { return 0 }
        if currentIndex + 1 < items.count { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    public func previousIndex() -> Int? {
        guard !items.isEmpty, let currentIndex else { return items.isEmpty ? nil : 0 }
        if currentIndex > 0 { return currentIndex - 1 }
        return repeatMode == .all ? items.count - 1 : nil
    }
}

/// Local, file-based media library: history, resume positions, favourites,
/// per-file sync preferences and the play queue. No network access.
public final class MediaLibrary {
    struct Snapshot: Codable {
        var version = 1
        var records: [MediaRecord]
        var playlist: Playlist
    }

    public enum SortOrder: String, CaseIterable, Sendable {
        case recent = "Recently Played", title = "Title", duration = "Duration", added = "Date Added"
    }

    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "mts", "ogv", "3gp", "vob", "divx", "rmvb",
        "asf",
    ]
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "ac3", "eac3", "dts", "mka", "aiff", "alac",
    ]

    public let storeURL: URL
    public private(set) var records: [String: MediaRecord] = [:]
    public var playlist = Playlist()
    public var onChange: (() -> Void)?
    /// Called when what appears in lists changes (history, favourites, titles) —
    /// not for frequent resume-position updates.
    public var onListsChange: (() -> Void)?

    /// Minimum position and minimum remaining time for offering to resume.
    public static let resumeMinimumSeconds = 10.0
    public static let resumeTailSeconds = 15.0

    public init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    public static func defaultStoreURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RVLC", isDirectory: true).appendingPathComponent("library.json")
    }

    /// Decodes each record independently so one damaged entry cannot discard the library.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct LossySnapshot: Decodable {
        var records: [Lossy<MediaRecord>]
        var playlist: Lossy<Playlist>?
    }

    /// Number of records that could not be read on the last load (kept in a backup file).
    public private(set) var unreadableRecordCount = 0

    public func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(LossySnapshot.self, from: data) else {
            backUpUnreadableStore()
            return
        }
        let good = snapshot.records.compactMap(\.value)
        unreadableRecordCount = snapshot.records.count - good.count
        if unreadableRecordCount > 0 || snapshot.playlist?.value == nil { backUpUnreadableStore() }
        records = Dictionary(good.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        playlist = snapshot.playlist?.value ?? Playlist()
    }

    /// Copies the store aside before it is rewritten. Existing backups are never overwritten.
    private func backUpUnreadableStore() {
        let fm = FileManager.default
        var backup = storeURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        if fm.fileExists(atPath: backup.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            backup = storeURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        }
        try? fm.copyItem(at: storeURL, to: backup)
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = Snapshot(records: records.values.sorted { $0.path < $1.path }, playlist: playlist)
        try encoder.encode(snapshot).write(to: storeURL, options: .atomic)
    }

    private func mutate(_ path: String, _ body: (inout MediaRecord) -> Void) {
        var record = records[path] ?? MediaRecord(path: path)
        body(&record)
        records[path] = record
        onChange?()
    }

    public func record(for path: String) -> MediaRecord? { records[path] }

    public func markOpened(_ path: String, at date: Date = Date()) {
        mutate(path) {
            $0.lastPlayed = date
            $0.playCount += 1
            if $0.fileSize == nil {
                $0.fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            }
        }
        onListsChange?()
    }

    public func updateMetadata(_ path: String, title: String?, duration: Double?, width: Int?, height: Int?) {
        mutate(path) {
            if let title, !title.isEmpty { $0.title = title }
            if let duration, duration.isFinite, duration > 0 { $0.duration = duration }
            if let width, width > 0 { $0.width = width }
            if let height, height > 0 { $0.height = height }
        }
        onListsChange?()
    }

    /// Stores the playback position, clearing it near the end so finished files start over.
    public func updatePosition(_ path: String, position: Double, duration: Double?) {
        mutate(path) {
            if let duration, duration > 0, position >= duration - MediaLibrary.resumeTailSeconds {
                $0.position = nil
            } else {
                $0.position = max(0, position)
            }
            if let duration, duration > 0 { $0.duration = duration }
        }
    }

    public func resumePosition(for path: String) -> Double? {
        guard let record = records[path], let position = record.position, position >= MediaLibrary.resumeMinimumSeconds else { return nil }
        if let duration = record.duration, position >= duration - MediaLibrary.resumeTailSeconds { return nil }
        return position
    }

    public func setFavorite(_ path: String, _ favorite: Bool) {
        mutate(path) { $0.favorite = favorite }
        onListsChange?()
    }
    public func setAudioDelay(_ path: String, ms: Int) { mutate(path) { $0.audioDelayMs = ms } }
    public func setSubtitleState(_ path: String, subtitlePath: String?, offsetMs: Int, scale: Double = 1) {
        mutate(path) {
            $0.subtitlePath = subtitlePath
            $0.subtitleOffsetMs = offsetMs
            $0.subtitleScale = abs(scale - 1) < 1e-9 ? nil : scale
        }
    }

    public func removeFromHistory(_ path: String) {
        guard var record = records[path] else { return }
        record.lastPlayed = nil
        record.position = nil
        if record.favorite { records[path] = record } else { records.removeValue(forKey: path) }
        onChange?()
        onListsChange?()
    }

    public func clearHistory() {
        for (path, var record) in records {
            record.lastPlayed = nil
            record.position = nil
            if record.favorite { records[path] = record } else { records.removeValue(forKey: path) }
        }
        onChange?()
        onListsChange?()
    }

    public func recent(limit: Int = 200) -> [MediaRecord] {
        Array(records.values.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(limit))
    }

    public func favorites() -> [MediaRecord] {
        records.values.filter(\.favorite).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func search(_ query: String, in items: [MediaRecord], sort: SortOrder) -> [MediaRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered =
            q.isEmpty
            ? items
            : items.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
            }
        switch sort {
        case .recent: return filtered.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration: return filtered.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case .added: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    // MARK: File discovery

    public static func isPlayableMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }

    /// Media files in a folder (non-recursive by default), naturally sorted.
    public static func mediaFiles(in folder: URL, recursive: Bool = false) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        if recursive, let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where isPlayableMedia(url) { urls.append(url) }
        } else if let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            urls = contents.filter(isPlayableMedia)
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// External subtitle files that belong to `media`: same base name, optionally
    /// with a language suffix (`movie.en.srt`). Exact matches come first.
    public static func matchingSubtitles(for media: URL) -> [URL] {
        let folder = media.deletingLastPathComponent()
        let stem = media.deletingPathExtension().lastPathComponent.lowercased()
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return contents.filter { url in
            guard SubtitleIO.fileExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return name == stem || name.hasPrefix(stem + ".")
        }.sorted { a, b in
            let an = a.deletingPathExtension().lastPathComponent.lowercased() == stem
            let bn = b.deletingPathExtension().lastPathComponent.lowercased() == stem
            if an != bn { return an }
            return a.lastPathComponent < b.lastPathComponent
        }
    }
}
