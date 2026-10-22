import AppKit
import Combine
import RVLCCore
import RVLCEngine

/// Application coordinator: owns the engine, preferences, library and
/// subtitle session, and implements every player action exactly once.
/// Menus, buttons and keyboard shortcuts all call into this type.
public final class PlayerController: ObservableObject {
    public let player: MPVPlayer
    public let preferences: Preferences
    public let library: MediaLibrary
    public let subtitles: SubtitleSession

    @Published public private(set) var playlist: Playlist
    @Published public var audioEffects = AudioEffects()
    @Published public var videoAdjustments = VideoAdjustments()
    @Published public private(set) var keyMap: KeyMap
    @Published public private(set) var lastError: String?

    /// Short on-screen messages (volume, offsets, results).
    public let osd = PassthroughSubject<String, Never>()
    /// Requests that the UI toggles or exits full screen.
    public let fullscreenRequests = PassthroughSubject<Bool?, Never>()
    /// Requests that the UI shows the keyboard shortcut reference.
    public let showShortcutsRequests = PassthroughSubject<Void, Never>()
    /// Asks the UI which subtitle line is selected for “sync line to now”.
    public var selectedCueProvider: (() -> Int?)?
    /// Asks the user whether unexported subtitle edits may be discarded
    /// (the parameter describes the action). Returns true to continue.
    /// Without a handler (tests, headless use) edits are discarded.
    public var confirmDiscardEdits: ((String) -> Bool)?
    /// Commits a subtitle cell that is still being typed in, so it counts as an edit.
    public var commitPendingEdits: (() -> Void)?
    /// Set by the window controller; Escape only acts while in full screen.
    public var isFullscreen = false
    /// Fires after library contents change (history, favourites), e.g. to refresh menus.
    public let libraryChanged = PassthroughSubject<Void, Never>()

    private var bag = Set<AnyCancellable>()
    private var saveTimer: Timer?
    private var librarySaveWork: DispatchWorkItem?
    private var currentPath: String?

    /// `cacheDirectory` holds temporary subtitle preview files (tests pass a temporary folder).
    public init(player: MPVPlayer, preferences: Preferences, library: MediaLibrary, cacheDirectory: URL? = nil) {
        self.player = player
        self.preferences = preferences
        self.library = library
        subtitles = SubtitleSession(player: player, cacheDirectory: cacheDirectory)
        playlist = library.playlist
        keyMap = preferences.keyMap
        audioEffects.normalize = preferences.normalizeAudio
        audioEffects.limiter = preferences.allowAmplification

        library.onChange = { [weak self] in self?.scheduleLibrarySave() }
        library.onListsChange = { [weak self] in self?.libraryChanged.send(()) }
        player.events.sink { [weak self] in self?.handle($0) }.store(in: &bag)
        subtitles.messages.sink { [weak self] in self?.osd.send($0) }.store(in: &bag)
        NotificationCenter.default.publisher(for: .rvlcPreferencesDidChange, object: preferences)
            .sink { [weak self] note in self?.preferenceChanged(note.userInfo?["key"] as? String) }
            .store(in: &bag)
        applySubtitleStyle()
        player.setMuted(preferences.muted)
        try? player.apply(audioEffects)
        // Persist the resume position regularly while playing.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.player.status == .playing else { return }
            self.savePosition()
        }
    }

    deinit { saveTimer?.invalidate() }

    // MARK: Opening media

    /// One canonical path per file (e.g. `/var/…` and `/private/var/…`, or `a/../b`),
    /// so history, resume positions and per-file sync settings always match.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Returns true when there are no unexported subtitle edits or the user agreed to discard them.
    func mayDiscardSubtitleEdits(_ action: String) -> Bool {
        commitPendingEdits?()
        guard subtitles.hasEdits, let confirm = confirmDiscardEdits else { return true }
        return confirm(action)
    }

    /// Opens files from a dialog, drag & drop or Finder. Media files are queued
    /// (and the first one played); subtitle files are imported into Subtitle Studio.
    /// `fromStart` ignores any saved resume position.
    public func open(_ urls: [URL], playFirst: Bool = true, fromStart: Bool = false) {
        var media: [URL] = []
        var subtitleFiles: [URL] = []
        for url in urls.map(Self.canonical) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                media += MediaLibrary.mediaFiles(in: url)
            } else if SubtitleIO.fileExtensions.contains(url.pathExtension.lowercased()) {
                subtitleFiles.append(url)
            } else {
                media.append(url)
            }
        }
        if !media.isEmpty {
            let first = playlist.append(media.map(\.path))
            commitPlaylist()
            if playFirst, let first { play(at: first, fromStart: fromStart) }
        }
        if let sub = subtitleFiles.first {
            if player.status.hasMedia || player.status == .loading {
                loadSubtitle(sub)
            } else if media.isEmpty {
                fail("Open a video before adding subtitles.")
            }
        }
        if media.isEmpty, subtitleFiles.isEmpty, !urls.isEmpty {
            fail("The folder contains no supported media files.")
        }
    }

    public func play(at index: Int, fromStart: Bool = false) {
        guard playlist.items.indices.contains(index) else { return }
        guard mayDiscardSubtitleEdits("open another file") else { return }
        savePosition()
        playlist.currentIndex = index
        commitPlaylist()
        let path = playlist.items[index]
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            fail("“\(url.lastPathComponent)” can no longer be found or read.")
            return
        }
        subtitles.mediaChanged()
        let record = library.record(for: path)
        let resume = preferences.rememberPosition && !fromStart ? library.resumePosition(for: path) : nil
        do {
            try player.open(url, start: resume, audioDelayMs: record?.audioDelayMs ?? 0, subtitleDelayMs: 0)
            currentPath = path
            lastError = nil
            library.markOpened(path)
            if let resume { osd.send("Resumed at \(Timecode.formatClock(seconds: resume))") }
        } catch {
            fail(error.localizedDescription)
        }
    }

    public func next() {
        if let i = playlist.nextIndex() { play(at: i) } else { osd.send("End of playlist") }
    }

    public func previous() {
        // Like most players: restart the current item unless near its beginning.
        if player.position > 3 {
            player.seek(0)
        } else if let i = playlist.previousIndex() {
            play(at: i)
        } else {
            player.seek(0)
        }
    }

    public func stop() {
        guard mayDiscardSubtitleEdits("stop playback") else { return }
        savePosition()
        player.stop()
        subtitles.mediaChanged()
        currentPath = nil
    }

    private func handle(_ event: PlayerEvent) {
        switch event {
        case .fileLoaded(let url):
            let path = url.path
            let size = player.videoSize
            library.updateMetadata(
                path, title: nil, duration: player.duration, width: size.map { Int($0.width) },
                height: size.map { Int($0.height) })
            restoreOrAutoloadSubtitles(for: url)
            applyVideoAdjustments()
            // Capture resolution once video parameters arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let size = self.player.videoSize, self.player.currentURL == url else { return }
                self.library.updateMetadata(
                    path, title: nil, duration: self.player.duration, width: Int(size.width), height: Int(size.height))
            }
        case .endOfFile:
            if let path = currentPath { library.updatePosition(path, position: player.duration, duration: player.duration) }
            if let i = playlist.nextIndex(afterEnd: true) {
                if subtitles.hasEdits, i != playlist.currentIndex {
                    // Never discard subtitle edits by advancing automatically.
                    osd.send("Playlist paused: export or revert your subtitle edits to continue")
                } else if i == playlist.currentIndex {
                    player.seek(0)
                    player.play()
                } else {
                    play(at: i)
                }
            }
        case .loadFailed(let message):
            fail(message)
        }
    }

    private func restoreOrAutoloadSubtitles(for media: URL) {
        let record = library.record(for: media.path)
        var candidate: URL?
        if let saved = record?.subtitlePath, FileManager.default.isReadableFile(atPath: saved) {
            candidate = URL(fileURLWithPath: saved)
        } else if preferences.autoLoadSubtitles {
            candidate = MediaLibrary.matchingSubtitles(for: media).first
        }
        guard let candidate else { return }
        do {
            let remembered = record?.subtitlePath == candidate.path
            try subtitles.load(candidate, offsetMs: remembered ? record?.subtitleOffsetMs : 0)
            if remembered, let scale = record?.subtitleScale, scale != 1 {
                subtitles.apply(TimingTransform(scale: scale, offsetMs: record?.subtitleOffsetMs ?? 0))
            }
            if record?.subtitlePath == candidate.path, let offset = record?.subtitleOffsetMs, offset != 0 {
                osd.send("Subtitles: \(candidate.lastPathComponent) (offset \(formatOffset(offset)))")
            } else {
                osd.send("Subtitles: \(candidate.lastPathComponent)")
            }
        } catch {
            osd.send("Could not load \(candidate.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Subtitles and external audio

    public func loadSubtitle(_ url: URL) {
        let url = Self.canonical(url)
        guard player.status.hasMedia || player.status == .loading else {
            fail("Open a video before adding subtitles.")
            return
        }
        guard mayDiscardSubtitleEdits("replace the subtitle file") else { return }
        do {
            try subtitles.load(url)
            rememberSubtitleState()
            osd.send("Subtitles: \(url.lastPathComponent)")
        } catch {
            fail("“\(url.lastPathComponent)” could not be loaded. \(error.localizedDescription)")
        }
    }

    public func removeSubtitle() {
        guard mayDiscardSubtitleEdits("remove the subtitle file") else { return }
        subtitles.remove()
        if let path = currentPath { library.setSubtitleState(path, subtitlePath: nil, offsetMs: 0) }
    }

    func rememberSubtitleState() {
        guard let path = currentPath else { return }
        // Store the committed timing, never an unconfirmed preview.
        let t = subtitles.committedTransform
        library.setSubtitleState(path, subtitlePath: subtitles.document?.sourceURL?.path, offsetMs: t.offsetMs, scale: t.scale)
    }

    /// Removes an external audio track and falls back to the first remaining track.
    public func removeExternalAudio(id: Int) {
        player.removeTrack(.audio, id: id)
        if let fallback = player.currentTracks().first(where: { $0.kind == .audio && $0.id != id }) {
            player.selectTrack(.audio, id: fallback.id)
        }
    }

    public func loadExternalAudio(_ url: URL) {
        guard player.status.hasMedia else {
            fail("Open a video before adding an external audio track.")
            return
        }
        do {
            try player.addAudio(url)
            osd.send("Audio: \(url.lastPathComponent)")
        } catch {
            fail("“\(url.lastPathComponent)” could not be added as an audio track. \(error.localizedDescription)")
        }
    }

    // MARK: Offsets

    public func setSubtitleOffset(_ ms: Int) {
        subtitles.setOffset(ms)
        rememberSubtitleState()
        osd.send("Subtitle offset \(formatOffset(player.currentSubtitleDelayMs))")
    }

    public func adjustSubtitleOffset(by delta: Int) { setSubtitleOffset(player.currentSubtitleDelayMs + delta) }

    public func setAudioDelay(_ ms: Int) {
        let clamped = max(-600_000, min(600_000, ms))
        player.setAudioDelay(ms: clamped)
        if let path = currentPath { library.setAudioDelay(path, ms: clamped) }
        osd.send("Audio delay \(formatOffset(clamped))")
    }

    public func adjustAudioDelay(by delta: Int) { setAudioDelay(player.currentAudioDelayMs + delta) }

    /// “Sync selected line to now”: the selected (or nearest) line is the one heard right now.
    public func syncSelectedLineToNow() {
        guard subtitles.hasDocument else {
            osd.send("Load a subtitle file first")
            return
        }
        let now = player.currentPosition
        guard let index = selectedCueProvider?() ?? subtitles.nearestCueIndex(toMedia: now),
            let suggestion = subtitles.addSyncPoint(cueIndex: index, mediaSeconds: now)
        else { return }
        osd.send("Sync point added — \(suggestion.summary)")
    }

    // MARK: Volume and speed

    public func setVolume(_ value: Double, showOSD: Bool = true) {
        let v = min(max(0, value), preferences.maxVolume)
        player.setVolume(v)
        preferences.volume = v
        if player.isMuted, v > 0 { setMuted(false, showOSD: false) }
        if showOSD { osd.send("Volume \(Int(v.rounded()))%") }
    }

    public func setMuted(_ muted: Bool, showOSD: Bool = true) {
        player.setMuted(muted)
        preferences.muted = muted
        if showOSD { osd.send(muted ? "Muted" : "Volume \(Int(player.currentVolume.rounded()))%") }
    }

    public static let speedSteps: [Double] = [0.25, 0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0]

    public func setSpeed(_ value: Double) {
        player.setSpeed(value)
        osd.send(String(format: "Speed %g×", min(max(value, 0.25), 4)))
    }

    func stepSpeed(up: Bool) {
        let current = player.currentSpeed
        let next = up ? Self.speedSteps.first { $0 > current + 0.001 } : Self.speedSteps.last { $0 < current - 0.001 }
        if let next { setSpeed(next) }
    }

    // MARK: Action dispatch

    /// Performs a key-bindable action. Returns false when the action does not apply.
    @discardableResult
    public func perform(_ action: PlayerAction) -> Bool {
        let seekStep = Double(preferences.seekStepSeconds)
        switch action {
        case .playPause:
            if player.status == .idle || player.status == .loading {
                if let i = playlist.currentIndex ?? (playlist.isEmpty ? nil : 0), player.status == .idle {
                    play(at: i)
                    return true
                }
                return false
            }
            if case .error = player.status { return false }
            player.togglePause()
        case .stop: stop()
        case .previous: previous()
        case .next: next()
        case .seekBackward: seek(by: -seekStep)
        case .seekForward: seek(by: seekStep)
        case .seekBackwardSmall: seek(by: -1)
        case .seekForwardSmall: seek(by: 1)
        case .seekBackwardLarge: seek(by: -30)
        case .seekForwardLarge: seek(by: 30)
        case .frameBackStep: player.frameStep(forward: false)
        case .frameStep: player.frameStep(forward: true)
        case .volumeUp: setVolume(player.currentVolume + 5)
        case .volumeDown: setVolume(player.currentVolume - 5)
        case .mute: setMuted(!player.isMuted)
        case .speedDown: stepSpeed(up: false)
        case .speedUp: stepSpeed(up: true)
        case .speedReset: setSpeed(1)
        case .toggleFullscreen: fullscreenRequests.send(nil)
        case .exitFullscreen:
            // Outside full screen Escape keeps its normal meaning (cancel, close sheet…).
            guard isFullscreen else { return false }
            fullscreenRequests.send(false)
        case .subtitleEarlier: adjustSubtitleOffset(by: -preferences.subtitleStepMs)
        case .subtitleLater: adjustSubtitleOffset(by: preferences.subtitleStepMs)
        case .subtitleReset:
            subtitles.resetTiming()
            rememberSubtitleState()
            osd.send("Subtitle timing reset")
        case .toggleSubtitles:
            let visible = !(player.flag("sub-visibility") ?? true)
            player.setSubtitlesVisible(visible)
            osd.send(visible ? "Subtitles shown" : "Subtitles hidden")
        case .cycleSubtitle: cycleTrack(.sub)
        case .setSyncPoint: syncSelectedLineToNow()
        case .audioEarlier: adjustAudioDelay(by: -preferences.audioStepMs)
        case .audioLater: adjustAudioDelay(by: preferences.audioStepMs)
        case .audioReset: setAudioDelay(0)
        case .cycleAudio: cycleTrack(.audio)
        case .showShortcuts: showShortcutsRequests.send(())
        }
        return true
    }

    private func seek(by seconds: Double) {
        guard player.status.hasMedia else { return }
        player.seek(seconds, mode: .relative)
    }

    func cycleTrack(_ kind: MediaTrack.Kind) {
        let list = player.tracks(kind)
        guard !list.isEmpty else {
            osd.send(kind == .sub ? "No subtitle tracks" : "No audio tracks")
            return
        }
        let current = list.firstIndex { $0.isSelected }
        var nextTrack: MediaTrack?
        if let current {
            nextTrack = current + 1 < list.count ? list[current + 1] : nil
        } else {
            nextTrack = list.first
        }
        if kind == .audio, nextTrack == nil { nextTrack = list.first }
        player.selectTrack(kind, id: nextTrack?.id)
        osd.send("\(kind == .sub ? "Subtitles" : "Audio"): \(nextTrack?.displayName ?? "Off")")
    }

    // MARK: Playlist editing

    public func addToPlaylist(_ urls: [URL]) {
        var media: [URL] = []
        for url in urls.map(Self.canonical) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                media += MediaLibrary.mediaFiles(in: url)
            } else if !SubtitleIO.fileExtensions.contains(url.pathExtension.lowercased()) {
                media.append(url)
            }
        }
        playlist.append(media.map(\.path))
        commitPlaylist()
    }

    public func removeFromPlaylist(_ indices: IndexSet) {
        playlist.remove(at: indices)
        commitPlaylist()
    }

    public func movePlaylistItem(from: Int, to: Int) {
        playlist.move(from: from, to: to)
        commitPlaylist()
    }

    public func clearPlaylist() {
        playlist.clear()
        commitPlaylist()
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        playlist.repeatMode = mode
        commitPlaylist()
    }

    private func commitPlaylist() {
        library.playlist = playlist
        scheduleLibrarySave()
    }

    // MARK: Persistence

    public func savePosition() {
        guard let path = currentPath, player.status.hasMedia, player.duration > 0 else { return }
        library.updatePosition(path, position: player.currentPosition, duration: player.duration)
    }

    private func scheduleLibrarySave() {
        librarySaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveLibraryNow() }
        librarySaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    public func saveLibraryNow() {
        do { try library.save() } catch {
            let message = "Your library could not be saved: \(error.localizedDescription)"
            lastError = message
            osd.send(message)
        }
    }

    /// Called on quit: persist position, sync state and library.
    public func prepareForTermination() {
        savePosition()
        rememberSubtitleState()
        librarySaveWork?.cancel()
        saveLibraryNow()
        subtitles.mediaChanged()
    }

    // MARK: Preferences

    private func preferenceChanged(_ key: String?) {
        switch Preferences.Key(rawValue: key ?? "") {
        case .subtitleFontSize, .subtitlePosition, .subtitleBackground: applySubtitleStyle()
        case .allowAmplification:
            player.setMaxVolume(preferences.maxVolume)
            audioEffects.limiter = preferences.allowAmplification
            applyAudioEffects()
        case .normalizeAudio:
            audioEffects.normalize = preferences.normalizeAudio
            applyAudioEffects()
        case .hardwareDecoding: player.setHardwareDecoding(preferences.hardwareDecoding)
        case .keyBindings: keyMap = preferences.keyMap
        default: break
        }
    }

    func applySubtitleStyle() {
        try? player.setProperty("sub-font-size", String(preferences.subtitleFontSize))
        try? player.setProperty("sub-pos", String(preferences.subtitlePosition))
        if preferences.subtitleBackground {
            try? player.setProperty("sub-border-style", "opaque-box")
            try? player.setProperty("sub-back-color", "#99000000")
            try? player.setProperty("sub-outline-size", "4")
        } else {
            try? player.setProperty("sub-border-style", "outline-and-shadow")
            try? player.setProperty("sub-outline-size", "1.65")
        }
    }

    public func applyAudioEffects() {
        do {
            try player.apply(audioEffects)
        } catch {
            fail("This audio effect is not supported by the media engine: \(error.localizedDescription)")
            audioEffects = AudioEffects(limiter: preferences.allowAmplification)
            try? player.apply(audioEffects)
        }
    }

    public func applyVideoAdjustments() { player.apply(videoAdjustments) }

    // MARK: Errors

    func fail(_ message: String) {
        lastError = message
        osd.send(message)
    }

    public func clearError() { lastError = nil }

    public var currentMediaPath: String? { currentPath }
}
