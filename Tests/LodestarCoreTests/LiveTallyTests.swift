import XCTest
@testable import LodestarCore

/// The live recognizer's count for a draft's log line: which step lost the
/// words when a draft stays empty with the meter moving.
final class LiveTallyTests: XCTestCase {
    private func value(_ tally: LiveTally, _ key: String) -> Any? {
        tally.fields.first { $0.key == key }?.value
    }

    func testADraftThatHeardWordsSaysHowMuchAndHowLoud() {
        var tally = LiveTally()
        tally.gave([Float](repeating: 0.1, count: 16_000))
        tally.gave([0.5, -0.25])
        tally.heard(chunks: 2, pieces: 5)
        tally.heard(chunks: 1, pieces: 0)
        tally.settled()
        XCTAssertEqual(tally.fields.map(\.key), ["seconds", "peakDb", "chunks", "pieces", "phrases"],
                       "nothing about refusals or failures when there were none")
        XCTAssertEqual(value(tally, "seconds") as? Double, 1.0)
        XCTAssertEqual(value(tally, "peakDb") as? Int, -6, "0.5 is -6 dBFS")
        XCTAssertEqual(value(tally, "chunks") as? Int, 3)
        XCTAssertEqual(value(tally, "pieces") as? Int, 5)
        XCTAssertEqual(value(tally, "phrases") as? Int, 1)
    }

    /// Audio the model heard and wrote nothing for: the empty draft of
    /// 2026-11-17, now told apart from the others.
    func testAudioHeardWithNoWordsIsPlain() {
        var tally = LiveTally()
        tally.gave([Float](repeating: 0.05, count: 32_000))
        tally.heard(chunks: 4, pieces: 0)
        XCTAssertEqual(value(tally, "chunks") as? Int, 4)
        XCTAssertEqual(value(tally, "pieces") as? Int, 0)
    }

    /// A session the stream no longer served, and a model that threw, say
    /// so, with the first error.
    func testRefusalsAndFailuresAreCounted() {
        var tally = LiveTally()
        tally.notCurrent()
        tally.notCurrent()
        tally.failed("deadEncoder")
        tally.failed("later")
        XCTAssertEqual(value(tally, "refused") as? Int, 2)
        XCTAssertEqual(value(tally, "failures") as? Int, 2)
        XCTAssertEqual(value(tally, "failure") as? String, "deadEncoder")
    }

    func testSilenceReadsAsTheDeafFloor() {
        var tally = LiveTally()
        tally.gave([0, 0, 0])
        XCTAssertEqual(value(tally, "peakDb") as? Int, -140)
        XCTAssertEqual(LiveTally().fields.first { $0.key == "seconds" }?.value as? Double, 0)
    }
}
