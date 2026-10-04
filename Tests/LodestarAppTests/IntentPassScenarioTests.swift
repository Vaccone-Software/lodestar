import XCTest
@testable import lodestar
import LodestarCore

/// A model that answers what it is told to, after a pause, and says what
/// it was asked.
final class FakeIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    var answer: (String) -> String
    var delay: Double
    init(delay: Double = 0, answer: @escaping (String) -> String) {
        self.answer = answer
        self.delay = delay
    }
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
    func rewrite(_ text: String) async -> String? {
        lock.lock(); _asked.append(text); lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return answer(text)
    }
}

/// The intent pass through the real draft: a take-back said is written as
/// meant, in place and as one undo step; whatever the checker refuses,
/// the hand touched, or the ear is still hearing stays as it stands.
final class IntentPassScenarioTests: XCTestCase {
    private func stage(_ intent: FakeIntent) -> Stage {
        let stage = Stage()
        stage.draft.intend = { await intent.rewrite($0) }
        return stage
    }

    func testATakeBackIsWrittenAsMeantAndUndoneInOneStep() {
        let intent = FakeIntent { _ in "Use the blue one." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Use the red one, actually no, the blue one.")
        stage.pump(until: { stage.draft.buffer.text == "Use the blue one." })
        XCTAssertEqual(stage.draft.buffer.text, "Use the blue one.")
        XCTAssertEqual(intent.asked, ["Use the red one, actually no, the blue one."])
        stage.press("escape")
        stage.press("u")
        XCTAssertEqual(stage.draft.buffer.text, "Use the red one, actually no, the blue one.", "u brings the words as said")
    }

    func testAnAnswerTheCheckerRefusesChangesNothing() {
        let intent = FakeIntent { _ in "Use the green one." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Use the red one, actually no, the blue one.")
        stage.pump(until: { intent.asked.count == 1 && false }, turns: 40)
        XCTAssertEqual(intent.asked.count, 1)
        XCTAssertEqual(stage.draft.buffer.text, "Use the red one, actually no, the blue one.")
    }

    func testOrdinarySpeechIsNeverSent() {
        let intent = FakeIntent { $0 }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Make the hint labels a little bigger.")
        stage.pump(until: { false }, turns: 20)
        XCTAssertEqual(intent.asked, [])
    }

    func testATakeBackReachesIntoTheSentenceBefore() {
        let intent = FakeIntent { _ in "Send it to Ana." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Send it to Mahavir.")
        stage.pump(until: { false }, turns: 10)
        XCTAssertEqual(intent.asked, [], "nothing to act on yet")
        stage.speech.settle("Wait, I didn't mean him, send it to Ana.")
        stage.pump(until: { stage.draft.buffer.text == "Send it to Ana." })
        XCTAssertEqual(intent.asked, ["Send it to Mahavir. Wait, I didn't mean him, send it to Ana."])
    }

    func testWhatTheHandTypedIsNeverSent() {
        let intent = FakeIntent { $0 }
        let stage = stage(intent)
        stage.lode(".")
        for key in ["h", "i", ".", "space"] { stage.press(key) }
        stage.speech.settle("Open the, the settings pane.")
        stage.pump(until: { !intent.asked.isEmpty })
        XCTAssertEqual(intent.asked, ["Open the, the settings pane."])
        XCTAssertTrue(stage.draft.buffer.text.hasPrefix("hi."))
    }

    func testAnEditWhileItThinksWins() {
        let intent = FakeIntent(delay: 0.2) { _ in "Ship the build tonight." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Ship the, the build tonight.")
        stage.pump(until: { !intent.asked.isEmpty })
        stage.press("escape")
        stage.press("x")
        let edited = stage.draft.buffer.text
        stage.pump(until: { false }, turns: 150)
        XCTAssertEqual(stage.draft.buffer.text, edited, "the hand's edit wins")
    }

    func testItWaitsForTheEarAndReadsItsWords() {
        let ear = FakeEar(answer: "Rename it to draft controller dot swift.", delay: 0.1)
        let intent = FakeIntent { _ in "Rename it to DraftController.swift." }
        let stage = stage(intent)
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 4), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(Heard("Rename it to draft control or dot swift.",
                                  words: [Heard.Word("Rename it to draft control or dot swift.", start: 0, end: 2.5)]))
        stage.pump(until: { stage.draft.buffer.text == "Rename it to DraftController.swift." })
        XCTAssertEqual(intent.asked, ["Rename it to draft controller dot swift."], "the ear's words, not the live ones")
    }

    func testReturnWaitsForARewriteUnderWay() {
        let intent = FakeIntent(delay: 0.1) { _ in "Archive the cache folder." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Delete the cache folder. Scratch that. Archive the cache folder.")
        stage.pump(until: { !intent.asked.isEmpty })
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Archive the cache folder.")
    }

    func testAnUndoneRewriteIsNotOfferedAgain() {
        let intent = FakeIntent { _ in "Open the settings pane." }
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle("Open the, the settings pane.")
        stage.pump(until: { stage.draft.buffer.text == "Open the settings pane." })
        stage.press("escape")
        stage.press("u")
        stage.press("a", shift: true)
        stage.pump(until: { false }, turns: 20)
        XCTAssertEqual(intent.asked.count, 1)
        XCTAssertEqual(stage.draft.buffer.text, "Open the, the settings pane.")
    }

    func testOffMeansNeverAsked() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("Use the red one, actually no, the blue one.")
        stage.pump(until: { false }, turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "Use the red one, actually no, the blue one.")
    }
}
