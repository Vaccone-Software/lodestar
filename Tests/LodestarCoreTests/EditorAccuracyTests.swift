import XCTest
@testable import LodestarCore

/// The filter over the model's recorded answers: sentences written for
/// these tests, a known right answer for each, and the answers each engine
/// gave when it was last recorded (EditorAccuracyLiveTests). A change to
/// the diff, the guards or the spell checker's merge that costs accuracy
/// fails here, on every run, with no model loaded.
final class EditorAccuracyTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/editor-accuracy.json")

    private func load() throws -> EditorBench.Fixture {
        try JSONDecoder().decode(EditorBench.Fixture.self, from: Data(contentsOf: Self.fixture))
    }

    func testEveryCaseHasItsQuestionsAnswered() throws {
        let fixture = try load()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 150)
        for item in fixture.cases {
            let asked = Set(EditorBench.questions(item.text))
            for engine in ["standard", "minimal", "full"] {
                XCTAssertEqual(Set(item.answers[engine]?.keys.map { $0 } ?? []), asked,
                               "re-record \(engine): the questions for \"\(item.text)\" changed")
            }
        }
    }

    func testTheStandardEngineHoldsItsAccuracy() throws {
        let score = EditorBench.score(try load().cases, engine: "standard")
        print("editor accuracy · standard · \(score)")
        if ProcessInfo.processInfo.environment["SHOW_MISSES"] != nil {
            score.misses.forEach { print("  missed  \($0)") }
            score.falseMarks.forEach { print("  wrong   \($0)") }
        }
        XCTAssertGreaterThanOrEqual(score.precision, 0.93, "marks that would not fix the slip")
        XCTAssertGreaterThanOrEqual(score.recall, 0.87, "slips the editor let pass")
        XCTAssertLessThanOrEqual(score.falsePerClean, 0.03, "marks on sentences with nothing wrong")
    }

    /// Minimal, the 8 GB Mac's engine: Apple's on-device model, a little
    /// less sharp, held to its own recorded mark.
    func testTheMinimalEngineHoldsItsAccuracy() throws {
        let score = EditorBench.score(try load().cases, engine: "minimal")
        print("editor accuracy · minimal · \(score)")
        XCTAssertGreaterThanOrEqual(score.precision, 0.89)
        XCTAssertGreaterThanOrEqual(score.recall, 0.77)
        XCTAssertLessThanOrEqual(score.falsePerClean, 0.06)
    }

    /// The 64 GB Mac's option: Qwen 3.6 35B, the sharpest reader.
    func testTheFullEngineHoldsItsAccuracy() throws {
        let score = EditorBench.score(try load().cases, engine: "full")
        print("editor accuracy · full · \(score)")
        XCTAssertGreaterThanOrEqual(score.precision, 0.94)
        XCTAssertGreaterThanOrEqual(score.recall, 0.88)
        XCTAssertLessThanOrEqual(score.falsePerClean, 0.05)
    }

    /// Spelling, no model: the spell checker and the fixed rules. Nearly
    /// every typo and doubled word, none of the grammar, and no marks on a
    /// clean sentence.
    func testSpellingAloneHoldsItsAccuracy() throws {
        let score = EditorBench.score(try load().cases, engine: "spelling")
        print("editor accuracy · spelling · \(score)")
        XCTAssertGreaterThanOrEqual(score.precision, 0.90)
        XCTAssertGreaterThanOrEqual(score.recall, 0.50)
        XCTAssertLessThanOrEqual(score.falsePerClean, 0.02)
    }

    func testCasualWritingIsNeverMarked() throws {
        let casual = try load().cases.filter { $0.src == "casual" }
        XCTAssertFalse(casual.isEmpty)
        let score = EditorBench.score(casual, engine: "standard")
        XCTAssertEqual(score.cleanMarks, 0, score.falseMarks.joined(separator: "\n"))
    }

    func testTheHandWrittenSlipsAreCaught() throws {
        let hand = try load().cases.filter { $0.src == "hand" }
        let score = EditorBench.score(hand, engine: "standard")
        print("editor accuracy · hand-written slips · \(score)")
        XCTAssertGreaterThanOrEqual(score.recall, 0.85, score.misses.joined(separator: "\n"))
    }
}
