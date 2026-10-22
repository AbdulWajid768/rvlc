import Accelerate
import Foundation

/// Audio-based automatic subtitle synchronisation.
///
/// Method (similar in spirit to ffsubsync):
/// 1. Band-pass the audio to the speech band (300–3400 Hz), split it into
///    10 ms frames and mark frames whose energy rises clearly above the noise
///    floor (adaptive threshold, gap filling and minimum run length).
/// 2. Mark the same frames as "subtitle active" while a cue is displayed.
/// 3. Cross-correlate both ±1 signals with an FFT and choose the lag with the
///    most agreement, optionally trying common frame-rate ratios for drift.
///
/// The result is a *suggestion* with a confidence score. The UI never applies
/// it without the user previewing and accepting it, because speech detection
/// can be fooled by music or effects-heavy soundtracks.
public enum AutoSync {
    public static let frameMs = 10

    public struct Result: Equatable, Sendable {
        public var transform: TimingTransform
        /// Fraction of frames where speech and subtitle activity agree (0…1).
        public var agreement: Double
        /// How much better the chosen alignment agrees than the best alternative
        /// alignment more than one second away (0…1). Larger is more trustworthy.
        public var margin: Double
        public var ratioName: String?

        public enum Confidence: String, Sendable { case high = "High", medium = "Medium", low = "Low" }

        /// Heuristic label for the UI; thresholds are deliberately conservative.
        public var confidence: Confidence {
            if margin >= 0.05 && agreement >= 0.7 { return .high }
            if margin >= 0.02 { return .medium }
            return .low
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case noCues
        case noSpeech
        case cuesOutsideAudio

        public var errorDescription: String? {
            switch self {
            case .noCues: return "The subtitle has no lines to synchronise."
            case .noSpeech: return "No speech-like audio was detected, so automatic sync is not possible for this file."
            case .cuesOutsideAudio: return "The subtitle lines fall outside the analysed audio."
            }
        }
    }

    // MARK: Speech activity

    /// RBJ biquad coefficients `[b0, b1, b2, a1, a2]` normalised by `a0`.
    static func biquad(highpass: Bool, cutoff: Double, rate: Double, q: Double = 0.707) -> [Double] {
        let w0 = 2 * Double.pi * cutoff / rate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let b0, b1, b2: Double
        if highpass {
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
        } else {
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
        }
        return [b0 / a0, b1 / a0, b2 / a0, (-2 * cosw) / a0, (1 - alpha) / a0]
    }

    /// Streaming speech detector: feed PCM in chunks of any size; memory use is
    /// one Float per 10 ms frame (≈1 M values for three hours), independent of
    /// the amount of audio.
    public struct SpeechDetector {
        public let sampleRate: Int
        private var filter: vDSP.Biquad<Float>?
        private var frameDB: [Float] = []
        private var sumSquares: Float = 0
        private var countInFrame = 0
        private var consumed = 0
        private var nextBoundary: Int

        public init(sampleRate: Int) {
            self.sampleRate = max(1, sampleRate)
            let rate = Double(self.sampleRate)
            let coefficients =
                AutoSync.biquad(highpass: true, cutoff: 300, rate: rate)
                + AutoSync.biquad(highpass: false, cutoff: min(3400, rate * 0.45), rate: rate)
            filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self)
            nextBoundary = Self.boundary(1, rate: self.sampleRate)
        }

        /// Sample index where frame `i` starts; exact for rates not divisible by 100.
        static func boundary(_ frame: Int, rate: Int) -> Int { frame * rate * AutoSync.frameMs / 1000 }

        public var frameCount: Int { frameDB.count }
        /// Per-frame band energy in dB (for diagnostics and tests).
        public var frameEnergies: [Float] { frameDB }

        public mutating func consume(_ chunk: [Float]) {
            guard !chunk.isEmpty else { return }
            // Apply in place: a copy of vDSP.Biquad starts with cleared delay
            // lines, which would add a filter transient at every chunk boundary.
            let filtered: [Float]
            if filter != nil {
                filtered = filter!.apply(input: chunk)
            } else {
                filtered = chunk
            }
            for x in filtered {
                sumSquares += x * x
                countInFrame += 1
                consumed += 1
                if consumed >= nextBoundary {
                    frameDB.append(10 * log10(sumSquares / Float(max(1, countInFrame)) + 1e-10))
                    sumSquares = 0
                    countInFrame = 0
                    nextBoundary = Self.boundary(frameDB.count + 1, rate: sampleRate)
                }
            }
        }

        /// Speech flags per frame (a trailing partial frame is ignored).
        public func activity() -> [Bool] { AutoSync.activity(fromFrameDB: frameDB) }
    }

    /// One boolean per 10 ms frame, true where speech is likely.
    public static func speechActivity(samples: [Float], sampleRate: Int) -> [Bool] {
        var detector = SpeechDetector(sampleRate: sampleRate)
        detector.consume(samples)
        return detector.activity()
    }

    /// Adaptive threshold over per-frame band energy (dB).
    static func activity(fromFrameDB db: [Float]) -> [Bool] {
        guard !db.isEmpty else { return [] }
        let sorted = db.sorted()
        func percentile(_ p: Double) -> Float { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let floor = percentile(0.15), peak = percentile(0.95)
        guard peak - floor >= 6 else { return [Bool](repeating: false, count: db.count) }
        let threshold = floor + max(6, 0.35 * (peak - floor))
        return smooth(db.map { $0 > threshold }, fillGap: 20, minRun: 8)
    }

    /// Fills short silent gaps inside speech and removes very short bursts.
    static func smooth(_ input: [Bool], fillGap: Int, minRun: Int) -> [Bool] {
        var out = input
        for (s, e) in runs(out, value: false) where s > 0 && e < out.count && e - s <= fillGap {
            for k in s..<e { out[k] = true }
        }
        for (s, e) in runs(out, value: true) where e - s < minRun {
            for k in s..<e { out[k] = false }
        }
        return out
    }

    static func runs(_ mask: [Bool], value: Bool) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for (i, v) in mask.enumerated() {
            if v == value, start == nil { start = i }
            if v != value, let s = start { result.append((s, i)); start = nil }
        }
        if let s = start { result.append((s, mask.count)) }
        return result
    }

    public static func subtitleActivity(cues: [Cue], frameCount: Int, scale: Double = 1) -> [Bool] {
        var active = [Bool](repeating: false, count: frameCount)
        for cue in cues where !cue.isComment {
            let s = max(0, Int((Double(cue.startMs) * scale / Double(frameMs)).rounded()))
            let e = min(frameCount, Int((Double(cue.endMs) * scale / Double(frameMs)).rounded()))
            if e > s { for k in s..<e { active[k] = true } }
        }
        return active
    }

    // MARK: Correlation

    /// FFT-based cross-correlation of two ±1 signals.
    final class Correlator {
        let n: Int
        let size: Int
        let log2n: vDSP_Length
        let setup: FFTSetupD
        var audioReal: [Double]
        var audioImag: [Double]

        init?(audio: [Bool]) {
            n = audio.count
            guard n > 1 else { return nil }
            var l = 1
            while (1 << l) < 2 * n { l += 1 }
            size = 1 << l
            log2n = vDSP_Length(l)
            guard let s = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return nil }
            setup = s
            audioReal = [Double](repeating: 0, count: size)
            audioImag = [Double](repeating: 0, count: size)
            for i in 0..<n { audioReal[i] = audio[i] ? 1 : -1 }
            forward(&audioReal, &audioImag)
        }

        deinit { vDSP_destroy_fftsetupD(setup) }

        func forward(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
                }
            }
        }

        /// Returns (lag, agreement, margin). Positive lag: subtitles must be shown later.
        func bestLag(subs: [Bool], maxLag: Int) -> (Int, Double, Double) {
            var re = [Double](repeating: 0, count: size)
            var im = [Double](repeating: 0, count: size)
            for i in 0..<n { re[i] = i < subs.count && subs[i] ? 1 : -1 }
            forward(&re, &im)
            // A · conj(S)
            for k in 0..<size {
                let ar = audioReal[k], ai = audioImag[k], sr = re[k], si = im[k]
                re[k] = ar * sr + ai * si
                im[k] = ai * sr - ar * si
            }
            forward(&re, &im, inverse: true)
            // Keep at least half of the signals overlapping so scores stay meaningful.
            let limit = max(0, min(maxLag, n / 2))
            var lags: [Int] = []
            var values: [Double] = []
            lags.reserveCapacity(2 * limit + 1)
            values.reserveCapacity(2 * limit + 1)
            for lag in -limit...limit {
                let idx = lag >= 0 ? lag : size + lag
                lags.append(lag)
                // Normalise by the overlap length so large lags are not penalised.
                values.append(re[idx] / Double(size) / Double(n - abs(lag)))
            }
            guard let best = values.indices.max(by: { values[$0] < values[$1] }) else { return (0, 0, 0) }
            let peak = values[best]
            let exclusion = 1000 / frameMs  // alternatives must differ by more than one second
            var runnerUp: Double?
            for i in values.indices where abs(lags[i] - lags[best]) > exclusion { runnerUp = max(runnerUp ?? -1, values[i]) }
            // Values are mean ±1 products: convert to the fraction of agreeing frames.
            let agreement = (peak + 1) / 2
            // Without an alternative alignment to compare against there is no evidence of a unique match.
            let margin = runnerUp.map { (peak - $0) / 2 } ?? 0
            return (lags[best], agreement, margin)
        }
    }

    public static func synchronize(
        samples: [Float], sampleRate: Int, cues: [Cue], maxOffsetSeconds: Double = 60,
        tryFrameRateRatios: Bool = true
    ) throws -> Result {
        guard !cues.isEmpty else { throw Failure.noCues }
        return try synchronize(
            activity: speechActivity(samples: samples, sampleRate: sampleRate), cues: cues,
            maxOffsetSeconds: maxOffsetSeconds, tryFrameRateRatios: tryFrameRateRatios)
    }

    /// Aligns subtitles to precomputed speech activity (10 ms frames), e.g. from `SpeechDetector`.
    public static func synchronize(
        activity audio: [Bool], cues: [Cue], maxOffsetSeconds: Double = 60, tryFrameRateRatios: Bool = true
    ) throws -> Result {
        guard !cues.isEmpty else { throw Failure.noCues }
        guard audio.contains(true), let correlator = Correlator(audio: audio) else { throw Failure.noSpeech }
        let maxLag = Int(maxOffsetSeconds * 1000) / frameMs
        var candidates: [(Double, String?)] = [(1, nil)]
        if tryFrameRateRatios { candidates += SyncFit.knownRatios.map { ($0.ratio, $0.name) } }
        var best: Result?
        for (scale, name) in candidates {
            let subs = subtitleActivity(cues: cues, frameCount: audio.count, scale: scale)
            guard subs.contains(true) else { continue }
            let (lag, agreement, margin) = correlator.bestLag(subs: subs, maxLag: maxLag)
            let result = Result(
                transform: TimingTransform(scale: scale, offsetMs: lag * frameMs),
                agreement: agreement, margin: margin, ratioName: name)
            guard let current = best else { best = result; continue }
            // A drift model must beat the constant model clearly to be chosen.
            let required = scale != 1 && !current.transform.hasScale ? 0.01 : 0
            if result.agreement > current.agreement + required { best = result }
        }
        guard let best else { throw Failure.cuesOutsideAudio }
        return best
    }
}
