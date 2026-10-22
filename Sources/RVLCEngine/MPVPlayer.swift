import CMpv
import Combine
import Foundation
import os

/// Owns one libmpv instance and exposes its state to the UI.
///
/// * All commands are issued on the main thread.
/// * libmpv events are drained on a private serial queue and applied to the
///   published state on the main thread, so every `@Published` value reflects
///   what the media engine reports rather than what the UI assumes.
public final class MPVPlayer: ObservableObject {
    public struct Configuration {
        /// Use null video/audio outputs (automated tests, audio analysis).
        public var headless: Bool
        public var hardwareDecoding: Bool
        public var initialVolume: Double
        public var maxVolume: Double
        /// Extra mpv options applied before initialisation.
        public var extraOptions: [String: String]

        public init(
            headless: Bool = false, hardwareDecoding: Bool = true, initialVolume: Double = 100,
            maxVolume: Double = 100, extraOptions: [String: String] = [:]
        ) {
            self.headless = headless
            self.hardwareDecoding = hardwareDecoding
            self.initialVolume = initialVolume
            self.maxVolume = maxVolume
            self.extraOptions = extraOptions
        }
    }

    // MARK: Published state (main thread only)

    @Published public private(set) var status: PlaybackStatus = .idle
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isSeeking = false
    @Published public private(set) var volume: Double = 100
    @Published public private(set) var isMuted = false
    @Published public private(set) var speed: Double = 1
    /// Positive = subtitles appear later.
    @Published public private(set) var subtitleDelayMs = 0
    /// Positive = audio plays later relative to the video.
    @Published public private(set) var audioDelayMs = 0
    @Published public private(set) var subtitlesVisible = true
    @Published public private(set) var tracks: [MediaTrack] = []
    @Published public private(set) var videoSize: CGSize?
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var mediaTitle: String?
    @Published public private(set) var hardwareDecoder: String?
    @Published public private(set) var isPaused = false

    public let events = PassthroughSubject<PlayerEvent, Never>()
    public let configuration: Configuration

    /// The raw handle, used by the video layer to create a render context.
    public let handle: OpaquePointer

    private let eventQueue = DispatchQueue(label: "rvlc.mpv.events")
    private let eventQueueKey = DispatchSpecificKey<Bool>()
    private var isShutDown = false
    /// libmpv playlist entry of the most recent `open`; events for older entries are ignored
    /// so rapid successive loads never attribute one file's events to another.
    private var expectedEntryID: Int64?
    private var currentEntryID: Int64?
    private var entryURLs: [Int64: URL] = [:]
    private var wakeupBox: Unmanaged<WeakPlayerBox>?

    /// Lets the C wakeup callback reach the player without keeping it alive. The
    /// callback only touches the queue; the player is resolved on the event queue,
    /// so it can never be deallocated on libmpv's thread inside the callback.
    private final class WeakPlayerBox {
        weak var player: MPVPlayer?
        let queue: DispatchQueue
        init(_ player: MPVPlayer, queue: DispatchQueue) {
            self.player = player
            self.queue = queue
        }
    }
    private let log = Logger(subsystem: "RVLCPlayer", category: "mpv")

    private enum Observed: UInt64, CaseIterable {
        case timePos = 1, duration, pause, eofReached, idleActive, volume, mute, speed, subDelay, audioDelay
        case subVisibility, trackList, videoParams, seeking, hwdecCurrent, mediaTitle

        var name: String {
            switch self {
            case .timePos: return "time-pos"
            case .duration: return "duration"
            case .pause: return "pause"
            case .eofReached: return "eof-reached"
            case .idleActive: return "idle-active"
            case .volume: return "volume"
            case .mute: return "mute"
            case .speed: return "speed"
            case .subDelay: return "sub-delay"
            case .audioDelay: return "audio-delay"
            case .subVisibility: return "sub-visibility"
            case .trackList: return "track-list"
            case .videoParams: return "video-params"
            case .seeking: return "seeking"
            case .hwdecCurrent: return "hwdec-current"
            case .mediaTitle: return "media-title"
            }
        }

        var format: mpv_format {
            switch self {
            case .timePos, .duration, .volume, .speed, .subDelay, .audioDelay: return MPV_FORMAT_DOUBLE
            case .pause, .eofReached, .idleActive, .mute, .subVisibility, .seeking: return MPV_FORMAT_FLAG
            case .trackList, .videoParams: return MPV_FORMAT_NODE
            case .hwdecCurrent, .mediaTitle: return MPV_FORMAT_STRING
            }
        }
    }

    private enum RawEvent {
        case property(Observed, Any?)
        case startFile(entry: Int64)
        case fileLoaded
        case endFile(reason: mpv_end_file_reason, error: Int32, entry: Int64)
        case log(level: String, prefix: String, text: String)
        case shutdown
    }

    // MARK: Lifecycle

    public init(configuration: Configuration = Configuration()) throws {
        guard let h = mpv_create() else { throw MPVError(code: MPV_ERROR_NOMEM.rawValue, context: "mpv_create") }
        handle = h
        self.configuration = configuration
        volume = configuration.initialVolume

        var options: [(String, String)] = [
            // Playback is controlled exclusively by RVLC.
            ("config", "no"),
            ("load-scripts", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("terminal", "no"),
            // Privacy: never resolve network URLs through yt-dlp.
            ("ytdl", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            // External subtitles are loaded through Subtitle Studio instead.
            ("sub-auto", "no"),
            ("audio-file-auto", "no"),
            ("volume-max", String(Int(configuration.maxVolume))),
            ("volume", String(configuration.initialVolume)),
            ("hwdec", configuration.hardwareDecoding ? "auto-safe" : "no"),
            ("screenshot-directory", "~~desktop/"),
        ]
        if configuration.headless {
            options += [("vo", "null"), ("ao", "null")]
        } else {
            options += [("vo", "libmpv")]
        }
        for (key, value) in configuration.extraOptions { options.append((key, value)) }
        for (key, value) in options {
            let rc = mpv_set_option_string(h, key, value)
            if rc < 0 { log.error("Option \(key, privacy: .public) rejected: \(String(cString: mpv_error_string(rc)), privacy: .public)") }
        }
        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_terminate_destroy(h)
            throw MPVError(code: rc, context: "mpv_initialize")
        }
        mpv_request_log_messages(h, "warn")
        for prop in Observed.allCases {
            mpv_observe_property(h, prop.rawValue, prop.name, prop.format)
        }
        eventQueue.setSpecific(key: eventQueueKey, value: true)
        let box = Unmanaged.passRetained(WeakPlayerBox(self, queue: eventQueue))
        wakeupBox = box
        mpv_set_wakeup_callback(
            h,
            { context in
                guard let context else { return }
                let box = Unmanaged<WeakPlayerBox>.fromOpaque(context).takeUnretainedValue()
                box.queue.async { [weak box] in box?.player?.drainEvents() }
            }, box.toOpaque())
    }

    deinit {
        shutdown()
    }

    /// Stops playback and destroys the libmpv instance. The video layer must
    /// free its render context before this is called.
    public func shutdown() {
        guard !isShutDown else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        if DispatchQueue.getSpecific(key: eventQueueKey) == true {
            isShutDown = true
        } else {
            eventQueue.sync { isShutDown = true }
        }
        mpv_terminate_destroy(handle)
        wakeupBox?.release()
        wakeupBox = nil
        if Thread.isMainThread { status = .idle }
    }

    /// True once `shutdown()` has run; every API call is then a safe no-op.
    public var isTerminated: Bool { isShutDown }

    // MARK: Event processing

    private func drainEvents() {
        guard !isShutDown else { return }
        var batch: [RawEvent] = []
        while true {
            guard let event = mpv_wait_event(handle, 0)?.pointee else { break }
            if event.event_id == MPV_EVENT_NONE { break }
            if let raw = translate(event) { batch.append(raw) }
            if event.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for raw in batch { self.apply(raw) }
        }
    }

    private func translate(_ event: mpv_event) -> RawEvent? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                let observed = Observed(rawValue: event.reply_userdata)
            else { return nil }
            return .property(observed, Self.read(prop))
        case MPV_EVENT_START_FILE:
            let entry = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id ?? 0
            return .startFile(entry: entry)
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            return .endFile(reason: end.reason, error: end.error, entry: end.playlist_entry_id)
        case MPV_EVENT_LOG_MESSAGE:
            guard let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { return nil }
            return .log(
                level: String(cString: msg.level), prefix: String(cString: msg.prefix),
                text: String(cString: msg.text).trimmingCharacters(in: .newlines))
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }

    private static func read(_ prop: mpv_event_property) -> Any? {
        guard let data = prop.data else { return nil }
        switch prop.format {
        case MPV_FORMAT_DOUBLE: return data.load(as: Double.self)
        case MPV_FORMAT_FLAG: return data.load(as: Int32.self) != 0
        case MPV_FORMAT_STRING:
            guard let cstr = data.load(as: UnsafePointer<CChar>?.self) else { return nil }
            return String(cString: cstr)
        case MPV_FORMAT_NODE: return MPVNode.value(data.load(as: mpv_node.self))
        default: return nil  // MPV_FORMAT_NONE: property unavailable
        }
    }

    private func apply(_ event: RawEvent) {
        switch event {
        case .startFile(let entry):
            currentEntryID = entry
            guard entry == expectedEntryID else { return }
            status = .loading
            position = 0
            duration = 0
            videoSize = nil
        case .fileLoaded:
            guard let entry = currentEntryID, entry == expectedEntryID else { return }
            status = isPaused ? .paused : .playing
            if let url = entryURLs[entry] {
                currentURL = url
                events.send(.fileLoaded(url))
            }
        case let .endFile(reason, error, entry):
            entryURLs.removeValue(forKey: entry)
            if reason == MPV_END_FILE_REASON_ERROR, entry == expectedEntryID {
                let message = Self.describeLoadError(error)
                status = .error(message)
                events.send(.loadFailed(message))
            }
        case .property(let prop, let value):
            applyProperty(prop, value)
        case let .log(level, prefix, text):
            // File contents are never logged; mpv messages may contain paths, so they are private.
            if level == "error" || level == "fatal" {
                log.error("[\(prefix, privacy: .public)] \(text, privacy: .private)")
            } else {
                log.debug("[\(prefix, privacy: .public)] \(text, privacy: .private)")
            }
        case .shutdown:
            status = .idle
        }
    }

    static func describeLoadError(_ error: Int32) -> String {
        switch error {
        case MPV_ERROR_UNKNOWN_FORMAT.rawValue:
            return "This file format is not supported or the file is damaged."
        case MPV_ERROR_LOADING_FAILED.rawValue:
            return "The file could not be opened. It may be missing, unreadable or not a media file."
        case MPV_ERROR_NOTHING_TO_PLAY.rawValue:
            return "The file contains no playable audio or video."
        default:
            return "Playback failed: \(String(cString: mpv_error_string(error)))."
        }
    }

    private func applyProperty(_ prop: Observed, _ value: Any?) {
        switch prop {
        case .timePos:
            position = value as? Double ?? 0
        case .duration:
            duration = value as? Double ?? 0
        case .pause:
            isPaused = value as? Bool ?? false
            if status == .playing || status == .paused { status = isPaused ? .paused : .playing }
        case .eofReached:
            let reached = value as? Bool ?? false
            if reached, status == .playing || status == .paused {
                status = .ended
                events.send(.endOfFile)
            } else if !reached, status == .ended {
                status = isPaused ? .paused : .playing
            }
        case .idleActive:
            if value as? Bool == true {
                if case .error = status { break }
                if status != .loading { status = .idle }
                currentURL = nil
                tracks = []
            }
        case .volume:
            volume = value as? Double ?? volume
        case .mute:
            isMuted = value as? Bool ?? false
        case .speed:
            speed = value as? Double ?? 1
        case .subDelay:
            subtitleDelayMs = Int(((value as? Double ?? 0) * 1000).rounded())
        case .audioDelay:
            audioDelayMs = Int(((value as? Double ?? 0) * 1000).rounded())
        case .subVisibility:
            subtitlesVisible = value as? Bool ?? true
        case .trackList:
            tracks = (value as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(MediaTrack.init(node:)) }
        case .videoParams:
            if let params = value as? [String: Any], let w = params["dw"] as? Int, let h = params["dh"] as? Int, w > 0, h > 0 {
                videoSize = CGSize(width: w, height: h)
            } else {
                videoSize = nil
            }
        case .seeking:
            isSeeking = value as? Bool ?? false
        case .hwdecCurrent:
            let v = value as? String
            hardwareDecoder = (v == nil || v == "no" || v == "") ? nil : v
        case .mediaTitle:
            mediaTitle = value as? String
        }
    }

    // MARK: Low-level API

    public func command(_ args: [String]) throws {
        guard !isShutDown else { throw MPVError(code: MPV_ERROR_UNINITIALIZED.rawValue, context: args.first ?? "command") }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        let rc = cargs.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                mpv_command(handle, $0)
            }
        }
        if rc < 0 { throw MPVError(code: rc, context: args.first ?? "command") }
    }

    /// Runs a command and returns its result node (e.g. `loadfile` → `playlist_entry_id`).
    func commandWithResult(_ args: [String]) throws -> Any? {
        guard !isShutDown else { throw MPVError(code: MPV_ERROR_UNINITIALIZED.rawValue, context: args.first ?? "command") }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var result = mpv_node()
        let rc = cargs.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                mpv_command_ret(handle, $0, &result)
            }
        }
        if rc < 0 { throw MPVError(code: rc, context: args.first ?? "command") }
        defer { mpv_free_node_contents(&result) }
        return MPVNode.value(result)
    }

    public func setProperty(_ name: String, _ value: String) throws {
        guard !isShutDown else { throw MPVError(code: MPV_ERROR_UNINITIALIZED.rawValue, context: name) }
        let rc = mpv_set_property_string(handle, name, value)
        if rc < 0 { throw MPVError(code: rc, context: name) }
    }

    public func setFlag(_ name: String, _ value: Bool) throws {
        guard !isShutDown else { throw MPVError(code: MPV_ERROR_UNINITIALIZED.rawValue, context: name) }
        var flag: Int32 = value ? 1 : 0
        let rc = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        if rc < 0 { throw MPVError(code: rc, context: name) }
    }

    public func setDouble(_ name: String, _ value: Double) throws {
        guard !isShutDown else { throw MPVError(code: MPV_ERROR_UNINITIALIZED.rawValue, context: name) }
        var v = value
        let rc = mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        if rc < 0 { throw MPVError(code: rc, context: name) }
    }

    public func string(_ name: String) -> String? {
        guard !isShutDown, let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    public func double(_ name: String) -> Double? {
        guard !isShutDown else { return nil }
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    public func flag(_ name: String) -> Bool? {
        guard !isShutDown else { return nil }
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }

    public func node(_ name: String) -> Any? {
        guard !isShutDown else { return nil }
        var n = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &n) >= 0 else { return nil }
        defer { mpv_free_node_contents(&n) }
        return MPVNode.value(n)
    }

    // MARK: Playback commands

    /// Loads a local file. Per-file options (start position, delays) apply
    /// before the first frame and are reset by mpv when the file ends.
    public func open(_ url: URL, start: Double? = nil, audioDelayMs: Int = 0, subtitleDelayMs: Int = 0, paused: Bool = false) throws {
        var fileOptions = [
            "audio-delay=\(Double(audioDelayMs) / 1000)",
            "sub-delay=\(Double(subtitleDelayMs) / 1000)",
            "pause=\(paused ? "yes" : "no")",
        ]
        if let start, start > 0 { fileOptions.append("start=\(start)") }
        let result = try commandWithResult(["loadfile", url.path, "replace", "-1", fileOptions.joined(separator: ",")])
        guard let entry = (result as? [String: Any])?["playlist_entry_id"] as? Int else {
            throw MPVError(code: MPV_ERROR_GENERIC.rawValue, context: "loadfile")
        }
        expectedEntryID = Int64(entry)
        // Entries replaced before they started never send events; keep only live ones.
        entryURLs = entryURLs.filter { $0.key == currentEntryID }
        entryURLs[Int64(entry)] = url
        status = .loading
    }

    public func play() {
        if status == .ended { try? command(["seek", "0", "absolute+exact"]) }
        try? setFlag("pause", false)
    }

    public func pause() { try? setFlag("pause", true) }

    public func togglePause() {
        switch status {
        case .playing: pause()
        case .paused, .ended: play()
        default: break
        }
    }

    public func stop() {
        expectedEntryID = nil
        try? command(["stop"])
        // Stopping during a load: the superseded load's events are ignored, so no
        // later event would leave the loading state.
        if status == .loading {
            status = .idle
            currentURL = nil
        }
        // After a failed load libmpv is already idle, so no idle-active change
        // event follows; leave the error state explicitly.
        if flag("idle-active") == true {
            status = .idle
            currentURL = nil
            tracks = []
        }
    }

    public enum SeekMode { case absolute, relative }

    /// Seeks to an absolute time or by a relative amount. `exact` decodes to the
    /// precise frame; keyframe seeks are faster for scrubbing.
    public func seek(_ seconds: Double, mode: SeekMode = .absolute, exact: Bool = true) {
        guard status.hasMedia || status == .loading else { return }
        var target = seconds
        if mode == .absolute, duration > 0 { target = min(max(0, seconds), duration) }
        let flags = (mode == .absolute ? "absolute" : "relative") + (exact ? "+exact" : "+keyframes")
        try? command(["seek", String(target), flags])
    }

    public func frameStep(forward: Bool) {
        guard status.hasMedia else { return }
        try? command([forward ? "frame-step" : "frame-back-step"])
    }

    /// Upper volume limit in percent (100, or up to 200 with amplification).
    public private(set) lazy var maxVolume: Double = configuration.maxVolume

    public func setVolume(_ value: Double) {
        try? setDouble("volume", min(max(0, value), maxVolume))
    }

    public func setMaxVolume(_ value: Double) {
        maxVolume = value
        try? setProperty("volume-max", String(Int(value)))
        if currentVolume > value { setVolume(value) }
    }

    public func setMuted(_ muted: Bool) { try? setFlag("mute", muted) }

    public static let speedRange = 0.25...4.0

    public func setSpeed(_ value: Double) {
        try? setDouble("speed", min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound))
    }

    /// Positive values show subtitles later.
    public func setSubtitleDelay(ms: Int) { try? setDouble("sub-delay", Double(ms) / 1000) }

    /// Positive values play audio later relative to the video.
    public func setAudioDelay(ms: Int) { try? setDouble("audio-delay", Double(ms) / 1000) }

    /// Current subtitle delay read synchronously from libmpv. Use this (not the
    /// published value, which updates asynchronously) when computing relative
    /// adjustments so rapid key presses never lose a step.
    public var currentSubtitleDelayMs: Int { Int(((double("sub-delay") ?? 0) * 1000).rounded()) }

    /// Current audio delay read synchronously from libmpv.
    public var currentAudioDelayMs: Int { Int(((double("audio-delay") ?? 0) * 1000).rounded()) }

    public var currentVolume: Double { double("volume") ?? volume }
    public var currentSpeed: Double { double("speed") ?? speed }
    public var currentPosition: Double { double("time-pos") ?? position }

    public func setSubtitlesVisible(_ visible: Bool) { try? setFlag("sub-visibility", visible) }

    // MARK: Tracks

    public func tracks(_ kind: MediaTrack.Kind) -> [MediaTrack] { tracks.filter { $0.kind == kind } }
    public func selectedTrack(_ kind: MediaTrack.Kind) -> MediaTrack? { tracks.first { $0.kind == kind && $0.isSelected } }

    private static func trackProperty(_ kind: MediaTrack.Kind) -> String {
        switch kind {
        case .video: return "vid"
        case .audio: return "aid"
        case .sub: return "sid"
        }
    }

    /// Selects a track, or disables the track type when `id` is nil.
    public func selectTrack(_ kind: MediaTrack.Kind, id: Int?) {
        try? setProperty(Self.trackProperty(kind), id.map(String.init) ?? "no")
    }

    /// Reads the current track list synchronously (the published list may lag by one event).
    public func currentTracks() -> [MediaTrack] {
        (node("track-list") as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(MediaTrack.init(node:)) }
    }

    /// Adds an external subtitle file, selects it and returns its track id.
    @discardableResult
    public func addSubtitle(_ url: URL, title: String? = nil) throws -> Int? {
        var args = ["sub-add", url.path, "select"]
        if let title { args.append(title) }
        try command(args)
        return currentTracks().last { $0.kind == .sub && $0.externalPath == url.path }?.id
    }

    /// Adds an external audio file, selects it and returns its track id.
    @discardableResult
    public func addAudio(_ url: URL) throws -> Int? {
        try command(["audio-add", url.path, "select"])
        return currentTracks().last { $0.kind == .audio && $0.externalPath == url.path }?.id
    }

    public func removeTrack(_ kind: MediaTrack.Kind, id: Int) {
        switch kind {
        case .sub: try? command(["sub-remove", String(id)])
        case .audio: try? command(["audio-remove", String(id)])
        case .video: try? command(["video-remove", String(id)])
        }
    }

    /// Text of the subtitle currently on screen (formatting stripped), from libmpv.
    public var currentSubtitleText: String? { string("sub-text") }

    // MARK: Output and enhancement settings

    public func setHardwareDecoding(_ enabled: Bool) { try? setProperty("hwdec", enabled ? "auto-safe" : "no") }

    /// Applies an audio filter chain (empty string clears it).
    public func setAudioFilters(_ chain: String) throws { try setProperty("af", chain) }

    public struct AudioDevice: Equatable, Sendable {
        public var name: String
        public var description: String
    }

    public func audioDevices() -> [AudioDevice] {
        (node("audio-device-list") as? [Any] ?? []).compactMap { item in
            guard let map = item as? [String: Any], let name = map["name"] as? String else { return nil }
            return AudioDevice(name: name, description: map["description"] as? String ?? name)
        }
    }

    public func setAudioDevice(_ name: String) throws { try setProperty("audio-device", name) }

    public var currentAudioDevice: String? { string("audio-device") }
}
