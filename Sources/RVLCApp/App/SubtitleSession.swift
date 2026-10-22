import Combine
import Foundation
import RVLCCore
import RVLCEngine

/// State behind Subtitle Studio and the subtitle editor.
///
/// How preview works:
/// * The imported file is parsed into a `SubtitleDocument` (editable copy).
/// * A preview file containing the edited lines — with the drift `scale`
///   applied but no offset — is written to the cache folder and loaded into
///   libmpv as an external track.
/// * The constant offset is applied live through libmpv's `sub-delay`, so
///   offset changes are instant and never rewrite timestamps.
/// * Export applies exactly the same transform (`scale`, `offsetMs`), so the
///   saved file matches what was previewed. The source file is never modified.
public final class SubtitleSession: ObservableObject {
    public struct Suggestion: Equatable {
        public enum Source: Equatable { case syncPoints, audioAnalysis(confidence: String) }
        public var transform: TimingTransform
        public var summary: String
        public var detail: String
        public var source: Source
        public var isPreviewing = false
        var restore: TimingTransform
    }

    @Published public private(set) var document: SubtitleDocument?
    @Published public private(set) var trackID: Int?
    @Published public private(set) var scale: Double = 1
    @Published public private(set) var syncPoints: [SyncPoint] = []
    @Published public private(set) var suggestion: Suggestion?
    @Published public private(set) var isAnalyzing = false
    @Published public private(set) var analysisProgress = 0.0
    /// Last audio-analysis error (shown in the automatic sync card).
    @Published public private(set) var lastError: String?
    /// Last failure to refresh the live preview (shown with the file).
    @Published public private(set) var previewError: String?
    /// Changes whenever a different document is loaded or removed, so views can
    /// discard edits that were started on the previous document.
    @Published public private(set) var documentGeneration = 0
    @Published public private(set) var editCount = 0
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    public let player: MPVPlayer
    public let messages = PassthroughSubject<String, Never>()

    private var original: SubtitleDocument?
    private var previewURL: URL?
    private var undoStack: [SubtitleDocument] = []
    private var redoStack: [SubtitleDocument] = []
    private var previewWork: DispatchWorkItem?
    private var extractor: AudioExtractor?
    private let cacheDirectory: URL

    public init(player: MPVPlayer, cacheDirectory: URL? = nil) {
        self.player = player
        self.cacheDirectory =
            cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RVLC/Subtitle Preview", isDirectory: true)
        purgeStalePreviews()
    }

    /// Preview files left behind by a session that did not shut down cleanly
    /// (crash, force quit) are removed once they are a few hours old.
    func purgeStalePreviews(olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files where file.lastPathComponent.hasPrefix("preview-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    // MARK: Derived state

    /// Constant offset in ms. Positive = subtitles later. Mirrors libmpv `sub-delay`.
    public var offsetMs: Int { player.currentSubtitleDelayMs }
    public var transform: TimingTransform { TimingTransform(scale: scale, offsetMs: offsetMs) }

    /// The timing the user has committed to: while a suggestion is only being
    /// previewed, this is the timing that would be restored on Discard.
    public var committedTransform: TimingTransform {
        if let s = suggestion, s.isPreviewing { return s.restore }
        return transform
    }
    public var hasDocument: Bool { document != nil }
    public var sourceName: String? { document?.sourceURL?.lastPathComponent }

    // MARK: Import

    /// Imports a subtitle file for the current media and selects it.
    public func load(_ url: URL, encoding: String? = nil, offsetMs: Int? = nil) throws {
        let doc = try SubtitleIO.load(url, encoding: encoding)
        cancelAnalysis()
        clearSuggestion(restore: false)
        original = doc
        documentGeneration += 1
        previewError = nil
        document = doc
        scale = 1
        syncPoints = []
        undoStack = []
        redoStack = []
        editCount = 0
        updateUndoState()
        lastError = nil
        try writePreviewAndAttach()
        if let offsetMs { setOffset(offsetMs) }
        if !doc.warnings.isEmpty {
            messages.send("Loaded with \(doc.warnings.count) warning(s): \(doc.warnings[0])")
        }
    }

    /// Re-imports the current file with a different text encoding.
    public func reload(encoding: String) throws {
        guard let url = document?.sourceURL else { return }
        // Keep the committed timing, including any drift correction.
        let timing = committedTransform
        try load(url, encoding: encoding, offsetMs: timing.offsetMs)
        if timing.hasScale { setScale(timing.scale) }
    }

    /// Removes the imported subtitle from playback (the file is untouched).
    public func remove() {
        documentGeneration += 1
        cancelAnalysis()
        if let trackID { player.removeTrack(.sub, id: trackID) }
        trackID = nil
        document = nil
        original = nil
        syncPoints = []
        suggestion = nil
        scale = 1
        editCount = 0
        undoStack = []
        redoStack = []
        updateUndoState()
        player.setSubtitleDelay(ms: 0)
        deletePreview()
    }

    /// Called when a new media file starts: imported subtitles belong to the previous file.
    public func mediaChanged() {
        documentGeneration += 1
        cancelAnalysis()
        trackID = nil
        document = nil
        original = nil
        syncPoints = []
        suggestion = nil
        scale = 1
        editCount = 0
        undoStack = []
        redoStack = []
        updateUndoState()
        deletePreview()
    }

    private func deletePreview() {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }

    private func writePreviewAndAttach() throws {
        guard let document else { return }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let (text, _) = try SubtitleIO.render(document, transform: TimingTransform(scale: scale, offsetMs: 0))
        // A fresh name each time makes libmpv treat it as a new track.
        let url = cacheDirectory.appendingPathComponent("preview-\(UUID().uuidString).\(document.format.fileExtension)")
        try Data(text.utf8).write(to: url, options: .atomic)
        let title = document.sourceURL?.lastPathComponent ?? "Subtitles"
        let oldTrack = trackID
        let oldURL = previewURL
        guard player.status.hasMedia || player.status == .loading else {
            previewURL = url
            if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
            return
        }
        let newID = try player.addSubtitle(url, title: title)
        if let oldTrack { player.removeTrack(.sub, id: oldTrack) }
        trackID = newID
        previewURL = url
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
    }

    /// Debounced preview refresh after edits.
    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do {
                try self?.writePreviewAndAttach()
                self?.previewError = nil
            } catch {
                self?.previewError = "The live preview could not be updated: \(error.localizedDescription)"
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Re-attaches the preview after the media was (re)loaded.
    public func reattachIfNeeded() {
        guard document != nil, trackID == nil else { return }
        try? writePreviewAndAttach()
    }

    // MARK: Offset

    public func setOffset(_ ms: Int) {
        player.setSubtitleDelay(ms: max(-600_000, min(600_000, ms)))
    }

    public func nudge(by delta: Int) { setOffset(offsetMs + delta) }

    public func resetTiming() {
        clearSuggestion(restore: false)
        setOffset(0)
        if scale != 1 { setScale(1) }
    }

    func setScale(_ newScale: Double) {
        guard abs(newScale - scale) > 1e-12 else { return }
        scale = newScale
        try? writePreviewAndAttach()
    }

    /// Applies a full transform (scale baked into the preview, offset via sub-delay).
    func apply(_ t: TimingTransform) {
        setScale(t.scale)
        setOffset(t.offsetMs)
    }

    // MARK: Manual synchronisation

    /// Records that line `index` is heard at `mediaSeconds` and proposes a correction.
    @discardableResult
    public func addSyncPoint(cueIndex index: Int, mediaSeconds: Double) -> SyncSuggestion? {
        guard let document, document.cues.indices.contains(index) else { return nil }
        let cue = document.cues[index]
        let label = ASSCodec.plainText(cue.text).replacingOccurrences(of: "\n", with: " ")
        let point = SyncPoint(subtitleMs: cue.startMs, mediaMs: Int((mediaSeconds * 1000).rounded()), label: String(label.prefix(60)))
        syncPoints.removeAll { $0.subtitleMs == point.subtitleMs }
        syncPoints.append(point)
        syncPoints.sort { $0.subtitleMs < $1.subtitleMs }
        return proposeFromSyncPoints()
    }

    public func removeSyncPoint(at index: Int) {
        guard syncPoints.indices.contains(index) else { return }
        syncPoints.remove(at: index)
        if syncPoints.isEmpty { clearSuggestion(restore: true) } else { proposeFromSyncPoints() }
    }

    public func clearSyncPoints() {
        syncPoints = []
        clearSuggestion(restore: true)
    }

    @discardableResult
    private func proposeFromSyncPoints() -> SyncSuggestion? {
        guard let fit = SyncFit.fit(syncPoints) else { return nil }
        var detail =
            fit.pointCount == 1
            ? "Based on 1 sync point. Add a second point later in the file to detect drift."
            : String(format: "Based on %d sync points (fit error %.0f ms).", fit.pointCount, fit.rmsErrorMs)
        if !fit.notes.isEmpty { detail += " " + fit.notes.joined(separator: " ") }
        propose(fit.transform, summary: fit.summary, detail: detail, source: .syncPoints)
        return fit
    }

    private func propose(_ t: TimingTransform, summary: String, detail: String, source: Suggestion.Source) {
        let restore = suggestion?.isPreviewing == true ? suggestion!.restore : transform
        if suggestion?.isPreviewing == true { apply(restore) }
        suggestion = Suggestion(transform: t, summary: summary, detail: detail, source: source, isPreviewing: false, restore: restore)
    }

    /// Temporarily applies the suggestion so the user can watch the result.
    public func previewSuggestion() {
        guard var s = suggestion, !s.isPreviewing else { return }
        s.restore = transform
        s.isPreviewing = true
        suggestion = s
        apply(s.transform)
    }

    /// Keeps the suggested correction.
    public func acceptSuggestion() {
        guard let s = suggestion else { return }
        if !s.isPreviewing { apply(s.transform) }
        suggestion = nil
        messages.send("Subtitle timing corrected: \(s.summary)")
    }

    /// Discards the suggestion, restoring the timing in effect before any preview.
    public func rejectSuggestion() { clearSuggestion(restore: true) }

    private func clearSuggestion(restore: Bool) {
        if restore, let s = suggestion, s.isPreviewing { apply(s.restore) }
        suggestion = nil
    }

    // MARK: Automatic synchronisation (audio analysis)

    /// Analyses the selected audio track and proposes an offset. Runs off the main thread.
    public func analyzeAudio(maxOffsetSeconds: Double = 60) {
        guard let document, !isAnalyzing, let media = player.currentURL else { return }
        let audio = player.selectedTrack(.audio)
        let source: URL
        var trackForExtraction: Int?
        if let audio, audio.isExternal, let path = audio.externalPath {
            source = URL(fileURLWithPath: path)
        } else {
            source = media
            trackForExtraction = audio?.id
        }
        let extractor = AudioExtractor()
        self.extractor = extractor
        isAnalyzing = true
        analysisProgress = 0
        lastError = nil
        let cues = document.cues
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<AutoSync.Result, Error>
            do {
                let activity = try extractor.speechActivity(from: source, audioTrack: trackForExtraction) { p in
                    DispatchQueue.main.async { self?.analysisProgress = p * 0.95 }
                }
                outcome = .success(try AutoSync.synchronize(activity: activity, cues: cues, maxOffsetSeconds: maxOffsetSeconds))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, self.extractor === extractor else { return }
                self.isAnalyzing = false
                self.analysisProgress = 1
                self.extractor = nil
                switch outcome {
                case .success(let r):
                    let direction = r.transform.offsetMs >= 0 ? "later" : "earlier"
                    var summary = String(format: "Shift subtitles %.3f s %@", Double(abs(r.transform.offsetMs)) / 1000, direction)
                    if let ratio = r.ratioName { summary += " and correct drift (\(ratio))" }
                    let detail = String(
                        format: "Suggested by audio analysis · confidence: %@ (%.0f%% agreement). Preview before applying.",
                        r.confidence.rawValue, r.agreement * 100)
                    self.propose(r.transform, summary: summary, detail: detail, source: .audioAnalysis(confidence: r.confidence.rawValue))
                case .failure(let error):
                    if case AudioExtractor.Failure.cancelled = error { return }
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    public func cancelAnalysis() {
        extractor?.cancel()
        extractor = nil
        isAnalyzing = false
    }

    // MARK: Editing

    private func edit(_ body: (inout SubtitleDocument) throws -> Void) rethrows {
        guard var doc = document else { return }
        let before = doc
        try body(&doc)
        guard doc != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        document = doc
        editCount += 1
        updateUndoState()
        schedulePreview()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    public func undo() {
        guard let previous = undoStack.popLast(), let current = document else { return }
        redoStack.append(current)
        document = previous
        editCount += 1
        updateUndoState()
        schedulePreview()
    }

    public func redo() {
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current)
        document = next
        editCount += 1
        updateUndoState()
        schedulePreview()
    }

    public func setText(_ text: String, at index: Int) {
        edit { doc in
            guard doc.cues.indices.contains(index) else { return }
            doc.cues[index].text = text
        }
    }

    public func setTimes(at index: Int, startMs: Int, endMs: Int) throws {
        try edit { doc in
            guard doc.cues.indices.contains(index) else { return }
            try SubtitleEditing.setTimes(cue: index, startMs: startMs, endMs: endMs, in: &doc)
        }
    }

    public func shiftLines(_ indices: [Int], by delta: Int) {
        edit { doc in
            for i in indices where doc.cues.indices.contains(i) { SubtitleEditing.shift(cue: i, by: delta, in: &doc) }
        }
    }

    @discardableResult
    public func replaceAll(_ query: String, with replacement: String, options: SubtitleEditing.SearchOptions) throws -> Int {
        var count = 0
        try edit { doc in count = try SubtitleEditing.replaceAll(query, with: replacement, in: &doc, options: options) }
        return count
    }

    public func revertEdits() {
        guard let original, document != original else { return }
        edit { $0 = original }
    }

    public var hasEdits: Bool { document != nil && document != original }

    // MARK: Lookup helpers

    /// Cue index displayed at the current playback time, honouring the transform.
    public func cueIndex(atMedia seconds: Double) -> Int? {
        document?.cueIndex(at: Int(seconds * 1000), transform: transform)
    }

    public func nearestCueIndex(toMedia seconds: Double) -> Int? {
        document?.nearestCueIndex(to: Int(seconds * 1000), transform: transform)
    }

    /// Media time (seconds) at which cue `index` is currently displayed.
    public func displayedStart(of index: Int) -> Double? {
        guard let cue = document?.cues[safe: index] else { return nil }
        return Double(transform.apply(cue.startMs)) / 1000
    }

    // MARK: Export

    public func export(to url: URL, format: SubtitleFormat, encoding: String) throws -> SubtitleIO.ExportReport {
        guard let document else { throw SubtitleError.noCues(.srt) }
        return try SubtitleIO.export(document, to: url, transform: transform, format: format, encoding: encoding)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
