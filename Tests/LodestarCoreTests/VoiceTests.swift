import XCTest
@testable import LodestarCore

/// The voice measures, checked on synthetic voices whose answers are known:
/// a glottal pulse train shaped by one resonance, at a pitch that is a whole
/// number of samples, with the period and the amplitude perturbed exactly.
final class VoiceTests: XCTestCase {
    /// Seconds of voice: a pulse every `period` samples, each period drawn
    /// within `jitter` of it and each pulse's amplitude within `shimmer` of
    /// 0.5, at random. Returns the signal and the local jitter and shimmer
    /// of the cycles it was made of: the answers.
    private func voice(seconds: Double, period: Int = 100, jitter: Double = 0, shimmer: Double = 0)
        -> (signal: [Float], jitter: Double, shimmer: Double) {
        var random = SeededRandom(seed: 7)
        let count = Int(seconds * VoiceStats.rate)
        var out = [Float](repeating: 0, count: count)
        var at = 0
        var periods: [Double] = [], amplitudes: [Double] = []
        while at < count {
            let amplitude = 0.5 * (1 + shimmer * random.unit())
            amplitudes.append(amplitude)
            // A damped resonance at 800 Hz, gone within a period.
            for n in 0..<min(period, count - at) {
                let t = Double(n) / VoiceStats.rate
                out[at + n] += Float(amplitude * exp(-t / 0.002) * sin(2 * .pi * 800 * t))
            }
            let step = Int((Double(period) * (1 + jitter * random.unit())).rounded())
            periods.append(Double(step))
            at += step
        }
        func local(_ xs: [Double]) -> Double {
            let diffs = zip(xs.dropFirst(), xs).map { abs($0 - $1) }
            return (diffs.reduce(0, +) / Double(diffs.count)) / (xs.reduce(0, +) / Double(xs.count))
        }
        return (out, local(periods), local(amplitudes))
    }

    /// Uniform in -1...1, the same every run.
    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * VoiceStats.rate)).map { _ in Float.random(in: -1e-4...1e-4, using: &generator) }
    }

    func testASteadyVoiceReadsItsPitchAndNoPerturbation() throws {
        let stats = try XCTUnwrap(VoiceStats.analyse(quiet(0.5) + voice(seconds: 2).signal + quiet(0.5), words: 5))
        XCTAssertEqual(try XCTUnwrap(stats.f0?.mean), 160, accuracy: 2)
        XCTAssertLessThan(try XCTUnwrap(stats.f0SpreadSemitones), 0.2)
        XCTAssertLessThan(try XCTUnwrap(stats.jitter), 0.002)
        XCTAssertLessThan(try XCTUnwrap(stats.shimmer), 0.01)
        XCTAssertGreaterThan(stats.cyclePairs, 200)
        XCTAssertGreaterThan(try XCTUnwrap(stats.hnr?.mean), 15)
        XCTAssertEqual(stats.speechSeconds, 2, accuracy: 0.1)
        XCTAssertEqual(stats.pauses.n, 0, "the quiet before the first sound and after the last is not a pause")
        XCTAssertEqual(try XCTUnwrap(stats.articulationRate), 2.5, accuracy: 0.15)
    }

    func testJitterAndShimmerAreReadOffTheCycles() throws {
        let jittery = voice(seconds: 3, jitter: 0.02)
        let read = try XCTUnwrap(VoiceStats.analyse(jittery.signal + quiet(0.3), words: 0))
        XCTAssertGreaterThan(jittery.jitter, 0.008, "the voice was made perturbed")
        XCTAssertEqual(try XCTUnwrap(read.jitter), jittery.jitter, accuracy: jittery.jitter * 0.25)
        XCTAssertEqual(try XCTUnwrap(read.f0?.mean), 160, accuracy: 4)
        let shimmery = voice(seconds: 3, shimmer: 0.1)
        let heard = try XCTUnwrap(VoiceStats.analyse(shimmery.signal + quiet(0.3), words: 0))
        XCTAssertEqual(try XCTUnwrap(heard.shimmer), shimmery.shimmer, accuracy: shimmery.shimmer * 0.25)
        XCTAssertLessThan(try XCTUnwrap(heard.jitter), 0.002, "shimmer does not leak into jitter")
        XCTAssertNil(heard.speechRate, "no words, no rate")
    }

    func testAPauseBetweenSoundsIsCounted() throws {
        let stats = try XCTUnwrap(VoiceStats.analyse(voice(seconds: 1).signal + quiet(0.5) + voice(seconds: 1).signal + quiet(0.1),
                                                     words: 6, mic: "built-in", mixed: false))
        XCTAssertEqual(stats.pauses.n, 1)
        XCTAssertEqual(try XCTUnwrap(stats.pauses.mean), 0.5, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(stats.speechRate), 6 / 2.5, accuracy: 0.2)
        XCTAssertEqual(stats.mic, "built-in")
    }

    func testAVoiceIsAHealthEventThatRoundTripsAndSummarises() throws {
        let stats = try XCTUnwrap(VoiceStats.analyse(quiet(0.5) + voice(seconds: 2).signal + quiet(0.5), words: 5,
                                                     mic: "bluetooth", mixed: true))
        XCTAssertTrue(ObservationEvent.healthKinds.contains(.voice), "it lives in the health log, beside the hands")
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 1_790_000_000), kind: .voice)
        event.voice = stats
        event.app = "Ghostty"
        let back = try JSONDecoder().decode(ObservationEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(back.voice, stats)
        let summary = try XCTUnwrap(VoiceStats.summary(events: [back, back], days: 28,
                                                       now: Date(timeIntervalSince1970: 1_790_000_100)))
        XCTAssertEqual(summary.drafts, 2)
        XCTAssertEqual(try XCTUnwrap(summary.f0), 160, accuracy: 2)
        XCTAssertNil(VoiceStats.summary(events: [back], days: 1, now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testTooLittleSoundSaysNothing() {
        XCTAssertNil(VoiceStats.analyse(quiet(3), words: 0))
        XCTAssertNil(VoiceStats.analyse(voice(seconds: 0.5).signal + quiet(1), words: 1))
        XCTAssertNil(VoiceStats.analyse([], words: 0))
        // Shorter than one frame: nothing is read past the end.
        for count in [1, 160, 481, 639] {
            XCTAssertNil(VoiceStats.analyse([Float](repeating: 0.1, count: count), words: 1))
        }
    }
}
