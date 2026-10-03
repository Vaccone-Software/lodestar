import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// A settling ear that answers what it is told to, after a pause.
final class FakeEar: SettlingEar, @unchecked Sendable {
    let name = "fake"
    var isLoaded = true
    var answer: String
    var delay: Double
    private(set) var heard: [Int] = []
    init(answer: String, delay: Double = 0) {
        self.answer = answer
        self.delay = delay
    }
    func load() async throws {}
    func unload() {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        heard.append(samples.count)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return Heard(answer)
    }
}

/// The second recognizer through the real draft: each settled phrase is
/// heard again from the held audio, its words replace the live ones in
/// place as one undo step, a read-back of the list is refused, and ⏎
/// waits for the last phrase.
final class SettlingEarScenarioTests: XCTestCase {
    private func timed(_ text: String, _ start: Double, _ end: Double) -> Heard {
        Heard(text, words: [Heard.Word(text, start: start, end: end)])
    }

    private func stageWithAudio(_ ear: FakeEar) -> Stage {
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 6), rate: 16_000)
        return stage
    }

    func testAPhraseIsHeardAgainAndReplacedInPlace() {
        let ear = FakeEar(answer: "Ask Claude Code to fix the panel.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ask clone code to fix the panel.", 0, 2.5))
        stage.pump(until: { stage.draft.buffer.text.contains("Claude") })
        XCTAssertEqual(stage.draft.buffer.text, "Ask Claude Code to fix the panel.")
        XCTAssertEqual(ear.heard.first.map { $0 >= 16_000 * 2 }, true, "the phrase's audio, with a margin")
        stage.press("escape")
        stage.press("u")
        XCTAssertEqual(stage.draft.buffer.text, "Ask clone code to fix the panel.", "u brings the live words back")
    }

    func testAReadBackOfTheListIsRefused() {
        let ear = FakeEar(answer: "Lodestar, Ghostty, Xonar, Kindora.")
        let stage = stageWithAudio(ear)
        stage.draft.earContext = ["Lodestar", "Ghostty", "Xonar", "Kindora"]
        stage.lode(".")
        stage.speech.settle(timed("Okay.", 0, 1.5))
        stage.pump(until: { ear.heard.count == 1 && false }, turns: 50)
        XCTAssertEqual(stage.draft.buffer.text, "Okay.")
    }

    func testAPhraseTheHandHasEditedIsLeftAlone() {
        let ear = FakeEar(answer: "Ship the build tonight.", delay: 0.2)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship the bill tonight.", 0, 2))
        stage.press("escape")
        stage.press("x")
        stage.pump(until: { ear.heard.count == 1 && false }, turns: 60)
        XCTAssertFalse(stage.draft.buffer.text.contains("build"), "the hand's edit wins")
    }

    func testReturnWaitsForTheLastPhrase() {
        let ear = FakeEar(answer: "Rebase local/dev on main.", delay: 0.15)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Rebase local/dev on main.")
    }
}
