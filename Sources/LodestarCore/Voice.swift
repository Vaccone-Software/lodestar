import Accelerate
import Foundation

/// The voice of one dictation, as numbers: pitch and its steadiness,
/// loudness, the cycle-to-cycle perturbations the speech literature reads
/// (jitter, shimmer), how much of the sound is the voice rather than
/// breath (harmonics-to-noise), and the timing of the speech itself
/// (pauses, rate). Parkinson's voice is quieter, flatter in pitch and more
/// perturbed, and its rate and pauses change, so these are the measures
/// the published voice studies are built on.
///
/// Computed in memory from the audio the draft already holds, once the
/// draft has closed, and never from anything kept: the audio is dropped as
/// it always was, and only these numbers go into the health record.
///
/// The methods follow Praat's definitions without being Praat:
/// autocorrelation pitch (Boersma 1993) between 75 and 500 Hz with a 0.45
/// voicing threshold, harmonics-to-noise from the same autocorrelation
/// peak, and local jitter and shimmer from glottal cycles placed by
/// cross-correlation within voiced stretches, a pair of cycles counted only
/// when both periods fall between 2 and 13.3 ms and differ by less than
/// a factor of 1.3, and their amplitudes by less than 1.6. Loudness is in
/// dB against the microphone's full scale, so it moves with the microphone
/// and its distance: `mic` says which kind was listening, and a session
/// that changed microphones says so.
public struct VoiceStats: Codable, Equatable, Sendable {
    /// Seconds of audio analysed.
    public var seconds: Double
    /// Seconds with sound above the session's own noise floor.
    public var speechSeconds: Double
    /// Seconds that were voiced (a pitch was found).
    public var voicedSeconds: Double
    /// Silences of a quarter second or more between the first sound and
    /// the last, in seconds.
    public var pauses: Moments
    /// Pitch, in hertz, over voiced frames; and its spread in semitones,
    /// which compares across voices.
    public var f0: Moments?
    public var f0SpreadSemitones: Double?
    /// Loudness of the sounding frames, dB against full scale.
    public var intensity: Moments?
    /// Local jitter and shimmer as fractions (Praat reports percent), and
    /// how many cycle pairs they rest on.
    public var jitter: Double?
    public var shimmer: Double?
    public var cyclePairs: Int
    /// Harmonics-to-noise ratio of voiced frames, dB.
    public var hnr: Moments?
    /// Words per second over the span from the first sound to the last
    /// (speech rate), and over the sounding time only (articulation rate).
    public var speechRate: Double?
    public var articulationRate: Double?
    public var words: Int
    /// The microphone's kind: built-in, bluetooth, usb, other.
    public var mic: String?
    /// The session listened through more than one microphone (the Mac's
    /// own stood in while a headset woke): loudness is not comparable.
    public var mixed: Bool?

    public static let rate = 16_000.0
    static let frame = 640
    static let hop = 160
    static let minLag = 32 // 500 Hz
    static let maxLag = 213 // 75 Hz
    static let voicingThreshold: Float = 0.45
    static let pauseFloor = 0.25

    /// Nil when there is too little sound to say anything (under a second
    /// of speech).
    public static func analyse(_ samples: [Float], words: Int, mic: String? = nil, mixed: Bool? = nil) -> VoiceStats? {
        guard samples.count >= frame else { return nil }
        let count = (samples.count - frame) / hop + 1
        let hopSeconds = Double(hop) / rate
        var dbs = [Float](repeating: -160, count: count)
        var lags = [Float](repeating: 0, count: count)
        var clarity = [Float](repeating: 0, count: count)
        var centred = [Float](repeating: 0, count: frame)
        samples.withUnsafeBufferPointer { all in
            for i in 0..<count {
                let start = all.baseAddress! + i * hop
                var mean: Float = 0
                vDSP_meanv(start, 1, &mean, vDSP_Length(frame))
                var negative = -mean
                vDSP_vsadd(start, 1, &negative, &centred, 1, vDSP_Length(frame))
                var power: Float = 0
                vDSP_measqv(centred, 1, &power, vDSP_Length(frame))
                dbs[i] = 10 * log10(max(power, 1e-16))
                let (lag, r) = pitch(centred)
                lags[i] = lag
                clarity[i] = r
            }
        }
        // Sound is what stands clear of the session's own quiet: the tenth
        // percentile of frame loudness is the room. A take that is nearly
        // all speech has no room in it to read, so anything within 25 dB of
        // the loud end counts as sound whatever the percentile says.
        let sorted = dbs.sorted()
        let floor = sorted[count / 10]
        let loud = sorted[min(count - 1, count * 95 / 100)]
        let threshold = max(min(floor + 12, loud - 25), -70)
        let sounding = dbs.map { $0 >= threshold }
        let speechFrames = sounding.filter { $0 }.count
        guard Double(speechFrames) * hopSeconds >= 1 else { return nil }
        let voiced = (0..<count).map { sounding[$0] && clarity[$0] >= voicingThreshold && lags[$0] > 0 }

        var f0 = Moments(), semis = Moments(), intensity = Moments(), hnr = Moments()
        for i in 0..<count where sounding[i] { intensity.add(Double(dbs[i])) }
        var f0s: [Double] = []
        for i in 0..<count where voiced[i] {
            let hz = rate / Double(lags[i])
            f0s.append(hz)
            f0.add(hz)
            let r = Double(min(clarity[i], 0.9999))
            hnr.add(10 * log10(r / (1 - r)))
        }
        if let median = f0s.sorted().dropFirst(f0s.count / 2).first {
            for hz in f0s { semis.add(12 * log2(hz / median)) }
        }

        // Pauses: quiet runs between the first sound and the last.
        var pauses = Moments()
        if let first = sounding.firstIndex(of: true), let last = sounding.lastIndex(of: true) {
            var run = 0
            for i in first...last {
                if sounding[i] { if Double(run) * hopSeconds >= pauseFloor { pauses.add(Double(run) * hopSeconds) }; run = 0 }
                else { run += 1 }
            }
        }
        let span = (sounding.lastIndex(of: true).map { Double($0 + 1) } ?? 0) * hopSeconds
            - (sounding.firstIndex(of: true).map(Double.init) ?? 0) * hopSeconds

        let cycles = perturbation(samples, lags: lags, voiced: voiced)
        let speechSeconds = Double(speechFrames) * hopSeconds
        return VoiceStats(
            seconds: Double(samples.count) / rate, speechSeconds: speechSeconds,
            voicedSeconds: Double(voiced.filter { $0 }.count) * hopSeconds, pauses: pauses,
            f0: f0.n > 0 ? f0 : nil, f0SpreadSemitones: semis.sd,
            intensity: intensity.n > 0 ? intensity : nil,
            jitter: cycles.jitter, shimmer: cycles.shimmer, cyclePairs: cycles.pairs,
            hnr: hnr.n > 0 ? hnr : nil,
            speechRate: words > 0 && span > 0 ? Double(words) / span : nil,
            articulationRate: words > 0 ? Double(words) / speechSeconds : nil,
            words: words, mic: mic, mixed: mixed)
    }

    /// The frame's period in samples (sub-sample, by a parabola through the
    /// peak) and the normalised autocorrelation there. The shortest lag
    /// within a tenth of the best wins, so a period is not read as two.
    static func pitch(_ x: [Float]) -> (lag: Float, r: Float) {
        let n = x.count
        var best: (lag: Int, r: Float) = (0, 0)
        var rs = [Float](repeating: 0, count: maxLag + 2)
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            for lag in (minLag - 1)...(maxLag + 1) {
                let length = vDSP_Length(n - lag)
                var dot: Float = 0, e0: Float = 0, e1: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, length)
                vDSP_svesq(base, 1, &e0, length)
                vDSP_svesq(base + lag, 1, &e1, length)
                let r = e0 > 0 && e1 > 0 ? dot / (e0 * e1).squareRoot() : 0
                rs[lag] = r
                if (minLag...maxLag).contains(lag), r > best.r { best = (lag, r) }
            }
        }
        guard best.lag > 0 else { return (0, 0) }
        var lag = best.lag
        for candidate in minLag..<best.lag where rs[candidate] >= best.r * 0.9
            && rs[candidate] >= rs[candidate - 1] && rs[candidate] >= rs[candidate + 1] {
            lag = candidate
            break
        }
        let (a, b, c) = (rs[lag - 1], rs[lag], rs[lag + 1])
        let denominator = a - 2 * b + c
        let shift = denominator != 0 ? 0.5 * (a - c) / denominator : 0
        return (Float(lag) + max(-0.5, min(0.5, shift)), b)
    }

    /// Glottal cycles inside each voiced stretch, each placed where the
    /// waveform best repeats the cycle before it (the cross-correlation
    /// Praat's cycle marks use, rather than the tallest peak, which jumps
    /// between formants on a real voice), and the local jitter and shimmer
    /// of consecutive pairs. A cycle's amplitude is its peak to peak, over a
    /// period centred on its mark.
    static func perturbation(_ x: [Float], lags: [Float], voiced: [Bool])
        -> (jitter: Double?, shimmer: Double?, pairs: Int) {
        var periodDiff = 0.0, periodSum = 0.0, ampDiff = 0.0, ampSum = 0.0, pairs = 0
        var i = 0
        while i < voiced.count {
            guard voiced[i] else { i += 1; continue }
            var j = i
            while j < voiced.count, voiced[j] { j += 1 }
            defer { i = j }
            guard j - i >= 3 else { continue }
            let end = min(x.count, (j - 1) * hop + frame)
            // The first mark: the largest peak in the stretch's first
            // frame, which may begin in the quiet before the voice does.
            guard var mark = peak(x, from: i * hop, to: min(end, i * hop + frame))?.at else { continue }
            var cycles: [(period: Double, amplitude: Double)] = []
            while true {
                let frameIndex = min(j - 1, max(i, mark / hop))
                let expected = Double(lags[frameIndex])
                guard expected > 0 else { break }
                let length = Int(expected.rounded())
                let low = mark + Int(0.8 * expected), high = mark + Int(1.25 * expected)
                guard high + length < end,
                      let best = repeatAt(x, cycle: mark, length: length, from: low, to: high),
                      best.r >= 0.6 else { break }
                // The cycle's amplitude, over a period centred on its mark,
                // so the next cycle's onset does not leak into it.
                let span = x[max(0, mark - length / 2)..<min(x.count, mark + length - length / 2)]
                cycles.append((best.offset, Double((span.max() ?? 0) - (span.min() ?? 0))))
                mark += Int(best.offset.rounded())
            }
            guard cycles.count >= 2 else { continue }
            for k in 1..<cycles.count {
                let (p1, a1) = cycles[k - 1], (p2, a2) = (cycles[k].period, cycles[k].amplitude)
                let periods = (p1 / rate, p2 / rate)
                guard (0.002...0.01333).contains(periods.0), (0.002...0.01333).contains(periods.1),
                      max(p1, p2) / min(p1, p2) < 1.3, a1 > 0, a2 > 0, max(a1, a2) / min(a1, a2) < 1.6
                else { continue }
                periodDiff += abs(periods.1 - periods.0)
                periodSum += (periods.0 + periods.1) / 2
                ampDiff += abs(a2 - a1)
                ampSum += (a1 + a2) / 2
                pairs += 1
            }
        }
        guard pairs > 0, periodSum > 0, ampSum > 0 else { return (nil, nil, 0) }
        return (periodDiff / periodSum, ampDiff / ampSum, pairs)
    }

    /// Where, between `from` and `to` samples on, the cycle starting at
    /// `cycle` repeats best: the offset from it (sub-sample, by a parabola
    /// through the peak) and the normalised correlation there.
    static func repeatAt(_ x: [Float], cycle: Int, length: Int, from: Int, to: Int) -> (offset: Double, r: Float)? {
        guard length > 0, from > cycle, to > from, to + length <= x.count else { return nil }
        var rs: [Float] = []
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            var e0: Float = 0
            vDSP_svesq(base + cycle, 1, &e0, vDSP_Length(length))
            for start in from...to {
                var dot: Float = 0, e1: Float = 0
                vDSP_dotpr(base + cycle, 1, base + start, 1, &dot, vDSP_Length(length))
                vDSP_svesq(base + start, 1, &e1, vDSP_Length(length))
                rs.append(e0 > 0 && e1 > 0 ? dot / (e0 * e1).squareRoot() : 0)
            }
        }
        guard let index = rs.indices.max(by: { rs[$0] < rs[$1] }) else { return nil }
        var shift: Float = 0
        if index > 0, index < rs.count - 1 {
            let (a, b, c) = (rs[index - 1], rs[index], rs[index + 1])
            let denominator = a - 2 * b + c
            if denominator != 0 { shift = max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return (Double(from + index - cycle) + Double(shift), rs[index])
    }

    private static func peak(_ x: [Float], from: Int, to: Int) -> (at: Int, amplitude: Float)? {
        guard from >= 0, to > from, to <= x.count else { return nil }
        var best = from
        for k in from..<to where x[k] > x[best] { best = k }
        return (best, x[best])
    }
}

extension VoiceStats {
    /// The doctor's line: how many drafts were measured, and each measure's
    /// median across them. Description, no verdict.
    public struct Summary: Equatable {
        public var drafts = 0
        public var f0: Double?
        public var jitter: Double?
        public var shimmer: Double?
        public var hnr: Double?
        public var rate: Double?
    }

    public static func summary(events: [ObservationEvent], days: Int, now: Date = Date()) -> Summary? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let voices = events.filter { $0.kind == .voice && $0.t >= cutoff }.compactMap(\.voice)
        guard !voices.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : HoldWindow.quantile(values.sorted(), 0.5)
        }
        return Summary(drafts: voices.count, f0: median(voices.compactMap { $0.f0?.mean }),
                       jitter: median(voices.compactMap(\.jitter)), shimmer: median(voices.compactMap(\.shimmer)),
                       hnr: median(voices.compactMap { $0.hnr?.mean }), rate: median(voices.compactMap(\.speechRate)))
    }
}
