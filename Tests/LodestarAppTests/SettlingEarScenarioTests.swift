import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// A settling ear that answers what it is told to, after a pause.
final class FakeEar: SettlingEar, @unchecked Sendable {
    let name = "fake"
    var isLoaded = true
    var answers: [String]
    var delay: Double
    private(set) var heard: [Int] = []
    /// Answers returned, so a test that expects nothing to change waits
    /// for the answer it is refusing instead of for a while.
    private(set) var answered = 0
    init(answer: String, delay: Double = 0) {
        self.answers = [answer]
        self.delay = delay
    }
    init(answers: [String]) {
        self.answers = answers
        self.delay = 0
    }
    func load() async throws {}
    func unload() {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        heard.append(samples.count)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        defer { answered += 1 }
        return Heard(answers[min(heard.count, answers.count) - 1])
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

    // MARK: - Ink drying

    /// Grey can still change; ink is final. A settled phrase stays grey
    /// while the second ear hears it again, and turns to ink when the ear
    /// is done, whether or not it changed a word.
    func testWordsStayGreyUntilTheEarHasHeardThem() {
        let ear = FakeEar(answer: "Ship it today.", delay: 0.2)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship it today.", 0, 2))
        XCTAssertEqual(stage.draft.state["wet"] as? String, "Ship it today.", "heard, still being checked")
        stage.pump(until: { stage.draft.state["wet"] == nil }, turns: 400)
        XCTAssertNil(stage.draft.state["wet"], "the ear is done: ink")
        XCTAssertEqual(stage.draft.state["revised"] as? [String], [], "nothing changed, nothing underlined")
    }

    /// A word the ear rewrote is underlined, the word alone and not the
    /// phrase, until the hand's next key.
    func testARewriteIsUnderlinedUntilTheNextKey() {
        let ear = FakeEar(answer: "Then rerun the build.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Then rerun the bill.", 0, 2))
        stage.pump(until: { stage.draft.buffer.text.contains("build") })
        XCTAssertEqual(stage.draft.state["revised"] as? [String], ["build"])
        stage.press("space")
        XCTAssertEqual(stage.draft.state["revised"] as? [String], [], "the hand's next key clears it")
    }

    /// With no second ear and no intent pass there is nothing to wait for:
    /// settled words are ink at once, as they always were.
    func testWithoutAPassSettledWordsAreInkAtOnce() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle(timed("Plain words.", 0, 1.5))
        XCTAssertNil(stage.draft.state["wet"])
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
        stage.pump(until: { ear.answered == 1 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "Okay.")
    }

    func testAPhraseTheHandHasEditedIsLeftAlone() {
        let ear = FakeEar(answer: "Ship the build tonight.", delay: 0.2)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship the bill tonight.", 0, 2))
        stage.press("escape")
        stage.press("x")
        stage.pump(until: { ear.answered == 1 })
        stage.settle(turns: 20)
        XCTAssertFalse(stage.draft.buffer.text.contains("build"), "the hand's edit wins")
    }

    func testTwoPhrasesAreHeardAgainAsOneRun() {
        let ear = FakeEar(answer: "Open the file and look at the function that closes it.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Open the file and look at the.", 0, 2))
        stage.pump(until: { ear.heard.count == 1 })
        stage.speech.settle(timed("Function that clothes it.", 3, 5))
        stage.pump(until: { stage.draft.buffer.text.contains("closes") })
        XCTAssertEqual(stage.draft.buffer.text, "Open the file and look at the function that closes it.")
        XCTAssertEqual(ear.heard.last.map { $0 >= 16_000 * 5 }, true, "the second hearing spans the whole run")
    }

    func testTheHandEndsTheRun() {
        let ear = FakeEar(answers: ["First part.", "Second part."])
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("First part.", 0, 1.5))
        stage.pump(until: { ear.heard.count == 1 })
        stage.press("space")
        stage.speech.settle(timed("Second bart.", 3, 4.5))
        stage.pump(until: { stage.draft.buffer.text.contains("Second part") })
        XCTAssertEqual(stage.draft.buffer.text, "First part. Second part.")
        XCTAssertEqual(ear.heard.last.map { $0 < 16_000 * 3 }, true, "only what came after the hand")
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

    func testTheJournalKeepsADictationWhenAsked() throws {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stageWithAudio(ear)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        stage.draft.journal = DictationJournal(folder: dir, days: 14)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.pump(until: { stage.draft.buffer.text.contains("local/dev") })
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let text = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("Rebase local dev on main."), "what the live recognizer heard")
        XCTAssertTrue(text.contains("\"ear\""), "what the ear heard")
    }
}
