import Stoic
import StoicTesting
import XCTest
@testable import lodestar
import LodestarCore

/// A model each of whose answers is let go by the test, and which says
/// whether the ask was cancelled while it waited. Cancelled, it still
/// returns its answer, the way a model that does not look does: what the
/// draft does with that late answer is the thing under test.
final class GatedIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    private var _released: Set<Int> = []
    private var _cancelled: Set<Int> = []
    private var _returned: Set<Int> = []
    private let answers: [String]
    init(answers: [String]) { self.answers = answers }

    var asked: [String] { lock.withLock { _asked } }
    var cancelled: Set<Int> { lock.withLock { _cancelled } }
    var returned: Set<Int> { lock.withLock { _returned } }
    func release(_ index: Int) { lock.withLock { _ = _released.insert(index) } }

    func rewrite(_ text: String) async -> String? {
        let index = lock.withLock { () -> Int in _asked.append(text); return _asked.count - 1 }
        while !Task.isCancelled, !lock.withLock({ _released.contains(index) }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        lock.withLock {
            if Task.isCancelled { _cancelled.insert(index) }
            _returned.insert(index)
        }
        return index < answers.count ? answers[index] : nil
    }
}

/// The intent pass asks one question at a time, and a newer question that
/// takes in the older one's words replaces it: the older is cancelled, its
/// late answer changes nothing, and only the newest is applied. What the
/// pass did before (an answer applied in place, nothing applied to a draft
/// that has gone or words that have moved) is pinned beside it.
final class DraftIntentSlotTests: XCTestCase {
    private let first = "Use the red one, actually no, the blue one."
    private let second = "Actually, wait, use the green one."

    private func stage(_ intent: GatedIntent) -> Stage {
        let stage = Stage()
        stage.draft.intend = { await intent.rewrite($0) }
        return stage
    }

    // MARK: - What the pass did before, and still does

    /// A lone question is answered and applied, as it always was.
    func testALoneQuestionIsAppliedInPlace() {
        let intent = GatedIntent(answers: ["Use the blue one."])
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        XCTAssertEqual(stage.draft.buffer.text, first, "still read: nothing applied")
        intent.release(0)
        stage.pump(until: { stage.draft.buffer.text == "Use the blue one." })
        XCTAssertEqual(stage.draft.intentChanged, 1)
        XCTAssertEqual(stage.draft.intentTimes.count, 1)
    }

    /// An answer for a draft that has landed and gone changes nothing, and
    /// is still counted in how long an ask takes (the record ⏎ reads to
    /// decide whether to wait).
    func testAnAnswerForAClosedDraftLandsNowhere() {
        let intent = GatedIntent(answers: ["Use the blue one."])
        let stage = stage(intent)
        stage.draft.intentTimes = [1.4, 1.6, 1.8]
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen, "landed at once: the ask will not finish inside the wait")
        XCTAssertEqual(stage.pasteboard.last, first)
        intent.release(0)
        stage.pump(until: { stage.draft.intentTimes.count == 4 })
        XCTAssertEqual(stage.draft.intentChanged, 0)
        XCTAssertEqual(stage.pasteboard, [first], "nothing was written after the landing")
        XCTAssertEqual(stage.draft.buffer.text, first, "the closed draft's words were not rewritten")
    }

    /// The answer of the draft before does not reach the draft after.
    func testAnAnswerForTheDraftBeforeDoesNotReachTheNextDraft() {
        let intent = GatedIntent(answers: ["Use the blue one."])
        let stage = stage(intent)
        stage.draft.intentTimes = [1.4, 1.6, 1.8]
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        stage.speech.settle(first)
        intent.release(0)
        stage.pump(until: { intent.returned.contains(0) })
        stage.pump(until: { stage.draft.intentTimes.count >= 4 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, first, "the new draft's words stand as they were said")
        XCTAssertEqual(stage.draft.intentChanged, 0)
    }

    /// A microphone that stopped and was asked for again starts the draft's
    /// recognizing over: the answer of the question under way, which is for
    /// what the old session heard, is not applied.
    func testAnAnswerForTheSessionBeforeARestartIsNotApplied() {
        let intent = GatedIntent(answers: ["Use the blue one."])
        let stage = stage(intent)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lodestar-journal-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        stage.draft.journal = DictationJournal(folder: folder, days: 1)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.speech.fail("the microphone stopped")
        stage.clock.advance(by: DraftController.retrySeconds[0])
        XCTAssertEqual(stage.speech.listens, 2, "the session began again inside the draft")
        intent.release(0)
        stage.pump(until: { intent.returned.contains(0) })
        stage.pump(until: { stage.draft.intentTimes.count == 1 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, first, "the old session's answer was not applied")
        XCTAssertEqual(stage.draft.intentChanged, 0)
        // Nor written to the record as a rewrite that did not stand: it
        // belongs to a session that is gone.
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        var written = ""
        for case let file as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            written += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        XCTAssertTrue(written.contains("Use the red one"), "the draft's record was written: \(written)")
        XCTAssertFalse(written.contains("moved on"), "the old session's answer is not in the record: \(written)")
    }

    /// A question whose words the newer one does not take in is not lost:
    /// it is waited for and its answer applied, as before.
    func testAQuestionTheNewerDoesNotTakeInIsWaitedFor() {
        let intent = GatedIntent(answers: ["Use the blue one.", "unused"])
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        // More than the pass sends at once, so the newer question starts
        // after the older one's words.
        let filler = (0..<(DraftController.intentWords + 10)).map { "word\($0)" }.joined(separator: " ")
        stage.speech.settle(filler + ". Open the, the file.")
        stage.settle(turns: 30)
        XCTAssertEqual(intent.asked.count, 1, "the older question is waited for, as before")
        XCTAssertEqual(intent.cancelled, [], "and it was not cancelled")
        intent.release(0)
        stage.pump(until: { stage.draft.buffer.text.hasPrefix("Use the blue one.") })
        XCTAssertEqual(intent.cancelled, [], "nothing was cancelled on the way")
    }

    // MARK: - A newer question replaces the older

    /// The newer question is asked at once, without waiting behind the
    /// older, and the older is cancelled: its work sees the cancellation.
    func testANewerQuestionCancelsTheOlder() {
        let intent = GatedIntent(answers: ["Use the blue one.", "Use the green one."])
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.speech.settle(second)
        stage.pump(until: { intent.asked.count == 2 })
        XCTAssertEqual(intent.asked.last, first + " " + second, "the newer takes in the older's words")
        stage.pump(until: { intent.cancelled == [0] })
        XCTAssertEqual(intent.cancelled, [0], "the older was cancelled, the newer was not")
    }

    /// The older's answer, late, changes nothing; the newest lands.
    func testTheOlderAnswerChangesNothingAndTheNewestLands() {
        let intent = GatedIntent(answers: ["Use the blue one.", "Use the green one."])
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.speech.settle(second)
        stage.pump(until: { intent.cancelled == [0] })
        stage.pump(until: { intent.returned.contains(0) })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, first + " " + second, "the cancelled question's late answer was not applied")
        XCTAssertEqual(stage.draft.intentChanged, 0)
        XCTAssertEqual(stage.draft.intentTimes.count, 1, "the cancelled ask that still answered says how long an ask takes")
        intent.release(1)
        stage.pump(until: { stage.draft.buffer.text == "Use the green one." })
        XCTAssertEqual(stage.draft.intentTimes.count, 2)
        XCTAssertEqual(stage.draft.intentChanged, 1)
        XCTAssertEqual(intent.cancelled, [0], "the newest was never cancelled")
    }

    /// ⏎ waits for the newest question, not for the cancelled one.
    func testReturnWaitsForTheNewestQuestion() {
        let intent = GatedIntent(answers: ["Use the blue one.", "Use the green one."])
        let stage = stage(intent)
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.speech.settle(second)
        stage.pump(until: { intent.asked.count == 2 })
        stage.press("return")
        XCTAssertTrue(stage.draft.isOpen, "waiting for the answer")
        intent.release(1)
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Use the green one.")
    }

    /// A question for a draft that has closed lands nowhere, even when it
    /// is the newest.
    func testTheNewestQuestionOfAClosedDraftLandsNowhere() {
        let intent = GatedIntent(answers: ["Use the blue one.", "Use the green one."])
        let stage = stage(intent)
        stage.draft.intentTimes = [1.4, 1.6, 1.8]
        stage.lode(".")
        stage.speech.settle(first)
        stage.pump(until: { intent.asked.count == 1 })
        stage.speech.settle(second)
        stage.pump(until: { intent.asked.count == 2 })
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        let landed = stage.pasteboard
        intent.release(0)
        intent.release(1)
        stage.pump(until: { intent.returned == [0, 1] })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.pasteboard, landed)
        XCTAssertEqual(stage.draft.intentChanged, 0)
    }
}
