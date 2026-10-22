import Foundation
import XCTest

/// Synthetic media generated with FFmpeg at test time (no copyrighted content
/// is stored in the repository). Tests are skipped when ffmpeg is unavailable.
public enum Fixtures {
    public struct Media {
        public let dir: URL
        /// 8 s, 320×240 @ 25 fps test pattern; 440 Hz "speech" bursts at
        /// [0.5, 1.3) + 2k seconds; AAC audio.
        public let video: URL
        /// Same timeline, different tone (660 Hz), as a separate audio file.
        public let externalAudio: URL
        /// Second short clip (4 s) for multi-file tests.
        public let shortVideo: URL
        /// Not a media file.
        public let broken: URL
        /// Cues: "Alpha" 2.0–3.0 s, "Bravo" 5.0–6.0 s.
        public let subtitle: URL
        /// Cues aligned with the audio bursts but authored 0.6 s too early.
        public let earlySubtitle: URL
    }

    public static let ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static var cached: Media?
    private static var failure: String?

    public static func media() throws -> Media {
        if let cached { return cached }
        if let failure { throw XCTSkip(failure) }
        guard let ffmpeg else {
            failure = "ffmpeg not found; engine integration tests need it to generate fixtures"
            throw XCTSkip(failure!)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rvlc-fixtures-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bursts = "between(mod(t\\,2)\\,0.5\\,1.3)"
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
            p.standardOutput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw NSError(domain: "Fixtures", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
            }
        }
        let video = dir.appendingPathComponent("pattern.mp4")
        try run([
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=8",
            "-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*440*t)*\(bursts):s=48000:d=8",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "25",
            "-c:a", "aac", "-shortest", video.path,
        ])
        let audio = dir.appendingPathComponent("dub.m4a")
        try run(["-f", "lavfi", "-i", "aevalsrc=0.4*sin(2*PI*660*t)*\(bursts):s=48000:d=8", "-c:a", "aac", audio.path])
        let short = dir.appendingPathComponent("short.mp4")
        try run([
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=4",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", short.path,
        ])
        let broken = dir.appendingPathComponent("broken.mp4")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: broken)
        let subtitle = dir.appendingPathComponent("pattern.srt")
        try Data("1\n00:00:02,000 --> 00:00:03,000\nAlpha\n\n2\n00:00:05,000 --> 00:00:06,000\nBravo\n".utf8).write(to: subtitle)
        var early = ""
        for k in 0..<4 {
            let s = Double(k) * 2 + 0.5 - 0.6, e = Double(k) * 2 + 1.3 - 0.6
            early +=
                "\(k + 1)\n00:00:0\(String(format: "%.3f", max(0, s)).replacingOccurrences(of: ".", with: ",")) --> 00:00:0\(String(format: "%.3f", e).replacingOccurrences(of: ".", with: ","))\nLine \(k + 1)\n\n"
        }
        let earlyURL = dir.appendingPathComponent("early.srt")
        try Data(early.utf8).write(to: earlyURL)
        let media = Media(
            dir: dir, video: video, externalAudio: audio, shortVideo: short, broken: broken,
            subtitle: subtitle, earlySubtitle: earlyURL)
        cached = media
        return media
    }
}

public extension XCTestCase {
    /// Spins the main run loop until `condition` holds (published player state
    /// is updated asynchronously on the main queue).
    @discardableResult
    func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for: \(description)")
        return false
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
