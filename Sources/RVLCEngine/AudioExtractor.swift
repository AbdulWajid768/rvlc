import CMpv
import Foundation
import RVLCCore

/// Decodes the audio of a media file to 16 kHz mono PCM using a private,
/// headless libmpv instance (`ao=pcm`). Used by automatic subtitle sync.
///
/// Nothing leaves the machine: the PCM is written to a temporary file that is
/// deleted as soon as it has been read.
public final class AudioExtractor {
    public enum Failure: LocalizedError {
        case createFailed
        case decodeFailed(String)
        case cancelled
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .createFailed: return "The audio decoder could not be started."
            case .decodeFailed(let message): return "The audio could not be decoded: \(message)"
            case .cancelled: return "Audio analysis was cancelled."
            case .noAudio: return "This file has no audio to analyse."
            }
        }
    }

    public static let sampleRate = 16_000

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Blocking; call from a background queue. `audioTrack` selects an embedded
    /// track id (nil = default). `progress` receives values in 0…1.
    /// Decodes the whole audio track into memory. Fine for short clips; use
    /// `speechActivity(from:)` for full-length films.
    public func extract(from url: URL, audioTrack: Int? = nil, progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let tmp = try decode(url, audioTrack: audioTrack, progress: progress)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = (try? Data(contentsOf: tmp)) ?? Data()
        guard data.count >= 2 else { throw Failure.noAudio }
        progress?(1)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
    }

    /// Decodes the audio and runs speech detection on it in fixed-size chunks,
    /// so memory stays constant regardless of the film's length.
    public func speechActivity(from url: URL, audioTrack: Int? = nil, progress: ((Double) -> Void)? = nil) throws -> [Bool] {
        let tmp = try decode(url, audioTrack: audioTrack) { progress?($0 * 0.9) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let handle = try FileHandle(forReadingFrom: tmp)
        defer { try? handle.close() }
        let total = Double((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var detector = AutoSync.SpeechDetector(sampleRate: Self.sampleRate)
        var read = 0.0
        while true {
            if isCancelled { throw Failure.cancelled }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            read += Double(chunk.count)
            let samples = chunk.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
            detector.consume(samples)
            if total > 0 { progress?(0.9 + 0.1 * read / total) }
        }
        guard detector.frameCount > 0 else { throw Failure.noAudio }
        return detector.activity()
    }

    /// Writes the selected audio track as 16 kHz mono s16 PCM to a temporary file.
    private func decode(_ url: URL, audioTrack: Int?, progress: ((Double) -> Void)?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rvlc-audio-\(UUID().uuidString).pcm")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: tmp) } }
        guard let h = mpv_create() else { throw Failure.createFailed }
        defer { mpv_terminate_destroy(h) }
        let options: [(String, String)] = [
            ("config", "no"), ("load-scripts", "no"), ("terminal", "no"), ("ytdl", "no"),
            ("vo", "null"), ("vid", "no"), ("sid", "no"),
            ("aid", audioTrack.map(String.init) ?? "auto"),
            ("ao", "pcm"), ("ao-pcm-file", tmp.path), ("ao-pcm-waveheader", "no"),
            ("audio-format", "s16"), ("audio-samplerate", String(Self.sampleRate)), ("audio-channels", "mono"),
            ("audio-delay", "0"), ("speed", "1"), ("volume", "100"),
            ("idle", "no"), ("keep-open", "no"),
        ]
        for (k, v) in options { mpv_set_option_string(h, k, v) }
        guard mpv_initialize(h) >= 0 else { throw Failure.createFailed }
        var cargs: [UnsafeMutablePointer<CChar>?] = [strdup("loadfile"), strdup(url.path), nil]
        defer { for p in cargs { free(p) } }
        let rc = cargs.withUnsafeMutableBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: b.count) { mpv_command(h, $0) }
        }
        guard rc >= 0 else { throw Failure.decodeFailed(String(cString: mpv_error_string(rc))) }

        var duration = 0.0
        var lastProgress = Date.distantPast
        loop: while true {
            if isCancelled { throw Failure.cancelled }
            guard let event = mpv_wait_event(h, 0.2)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                var d = 0.0
                if mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &d) >= 0 { duration = d }
                var aid: Int64 = 0
                if mpv_get_property(h, "current-tracks/audio/id", MPV_FORMAT_INT64, &aid) < 0 { throw Failure.noAudio }
            case MPV_EVENT_END_FILE:
                let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end?.reason == MPV_END_FILE_REASON_ERROR {
                    throw Failure.decodeFailed(String(cString: mpv_error_string(end?.error ?? 0)))
                }
                break loop
            case MPV_EVENT_SHUTDOWN:
                break loop
            default:
                break
            }
            if duration > 0, let progress, Date().timeIntervalSince(lastProgress) > 0.2 {
                var pos = 0.0
                if mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &pos) >= 0 { progress(min(1, pos / duration)) }
                lastProgress = Date()
            }
        }
        guard FileManager.default.fileExists(atPath: tmp.path) else { throw Failure.noAudio }
        succeeded = true
        return tmp
    }
}
