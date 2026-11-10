import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The shelf where a left field's marks wait for the hand's return: what
/// takes a ledger back, what does not, and what ends one.
final class EditorMarkShelfTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private let text = "We need to recieve them."
    private let typo = EditorIssue(range: NSRange(location: 11, length: 7), original: "recieve",
                                   replacement: "receive", kind: .spelling)

    /// A ledger whose one mark has stood `seconds`, drawn from second 0.
    private func ledger(stood seconds: TimeInterval = 1.5) -> EditorMarkLedger {
        var ledger = EditorMarkLedger()
        _ = ledger.sync(drawn: [typo], all: [typo], text: text, caret: 24, quiet: true, at: at(0))
        _ = ledger.sync(drawn: [typo], all: [typo], text: text, caret: 24, quiet: true, at: at(seconds))
        return ledger
    }

    private func field(_ words: String? = nil, pid: pid_t = 100, bundle: String? = "com.example.app",
                       element: AXUIElement? = nil) -> EditorField {
        let words = words ?? text
        return EditorField(element: element ?? AXUIElementCreateApplication(pid), pid: pid, appName: "Example",
                           bundleID: bundle, text: words, caret: words.utf16.count, frame: nil, windowFrame: nil)
    }

    private func stood(_ ended: [EditorMarkShelf.Ended]) -> [TimeInterval] {
        ended.flatMap(\.endings).map(\.stood)
    }

    // MARK: - Taking a ledger back

    func testAFieldComingBackTakesItsLedgerAndTheTimeAwayIsNotStanding() throws {
        var shelf = EditorMarkShelf()
        XCTAssertTrue(shelf.park(ledger(), of: field(), issues: [typo], hiddenAt: at(1.5), at: at(1.5)).isEmpty)
        XCTAssertEqual(shelf.count, 1)
        let back = shelf.resume(for: field(), at: at(300))
        XCTAssertTrue(back.ended.isEmpty)
        XCTAssertEqual(shelf.count, 0)
        var held = try XCTUnwrap(back.parked).ledger
        held.show(at: at(300))
        _ = held.sync(drawn: [typo], all: [typo], text: text, caret: 24, quiet: true, at: at(301.5))
        let ending = try XCTUnwrap(held.clear(text: text, all: [typo], at: at(301.5)).first)
        XCTAssertEqual(ending.stood, 3.0, accuracy: 0.001, "1.5 s before it was left, 1.5 s after it came back")
    }

    func testTheTextComingBackNearlyAsItWasIsTheSameDraft() {
        var shelf = EditorMarkShelf()
        _ = shelf.park(ledger(), of: field(), issues: [typo], hiddenAt: at(1.5), at: at(2))
        let back = shelf.resume(for: field(text + " Ok.", element: AXUIElementCreateSystemWide()), at: at(60))
        XCTAssertNotNil(back.parked, "a few words typed since, and another element for it")
    }

    func testAnotherAppAnotherBundleOrOtherWordsIsNotTheDraft() {
        var shelf = EditorMarkShelf()
        _ = shelf.park(ledger(), of: field(), issues: [typo], hiddenAt: at(1.5), at: at(2))
        let elsewhere = AXUIElementCreateSystemWide()
        for read in [field(pid: 200, element: elsewhere),
                     field(bundle: "com.example.other", element: elsewhere),
                     field("Lunch is at noon, and nobody has a typo to mention.", element: elsewhere)] {
            let back = shelf.resume(for: read, at: at(60))
            XCTAssertNil(back.parked)
            XCTAssertTrue(back.ended.isEmpty)
            XCTAssertEqual(shelf.count, 1, "the draft is still waiting")
        }
    }

    func testTheExactTextIsPreferredToANearOneInTheSameApp() throws {
        var shelf = EditorMarkShelf()
        let near = text + " Ok."
        _ = shelf.park(ledger(), of: field(near, element: AXUIElementCreateSystemWide()), issues: [typo], hiddenAt: at(1.5), at: at(2))
        _ = shelf.park(ledger(), of: field(text, element: AXUIElementCreateSystemWide()), issues: [typo], hiddenAt: at(1.5), at: at(3))
        let back = shelf.resume(for: field(text, element: AXUIElementCreateSystemWide()), at: at(10))
        XCTAssertEqual(try XCTUnwrap(back.parked).field.text, text)
        XCTAssertTrue(back.ended.isEmpty, "the near one is another draft's, not a draft written over")
        XCTAssertEqual(shelf.count, 1)
    }

    /// The same element with other words is written over in place, sent or
    /// cleared: the draft's text is gone, and its marks end at once.
    func testTheSameElementWithOtherTextEndsTheShelfedMarks() {
        var shelf = EditorMarkShelf()
        _ = shelf.park(ledger(), of: field(), issues: [typo], hiddenAt: at(1.5), at: at(1.5))
        let back = shelf.resume(for: field("Something else entirely, typed after a send."), at: at(60))
        XCTAssertNil(back.parked)
        XCTAssertEqual(stood(back.ended), [1.5], "with the time it really stood, not the time away")
        XCTAssertEqual(shelf.count, 0)
    }

    // MARK: - Letting go

    func testALedgerWithNothingStandingIsNotKept() {
        var shelf = EditorMarkShelf()
        XCTAssertTrue(shelf.park(EditorMarkLedger(), of: field(), issues: [], hiddenAt: at(0), at: at(0)).isEmpty)
        XCTAssertEqual(shelf.count, 0)
    }

    func testAShelvedMarkEndsWhenItsKeepingRunsOutAndWithTheTimeItStood() {
        var shelf = EditorMarkShelf()
        _ = shelf.park(ledger(), of: field(), issues: [typo], hiddenAt: at(1.5), at: at(1.5))
        XCTAssertTrue(shelf.expire(at: at(1.5 + EditorMarkShelf.keep - 1)).isEmpty)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(stood(shelf.expire(at: at(1.5 + EditorMarkShelf.keep))), [1.5], "not ten minutes")
        XCTAssertEqual(shelf.count, 0)
    }

    /// A hand cannot grow the shelf: past its capacity the oldest field's marks
    /// end, each with its own time.
    func testTheShelfHoldsAtMostItsCapacityAndTheOldestGoFirst() {
        var shelf = EditorMarkShelf()
        var ended: [EditorMarkShelf.Ended] = []
        for pid in 0..<100 {
            ended += shelf.park(ledger(stood: 2), of: field(pid: pid_t(1000 + pid)), issues: [typo],
                                hiddenAt: at(2), at: at(2 + Double(pid)))
            XCTAssertLessThanOrEqual(shelf.count, EditorMarkShelf.capacity)
        }
        XCTAssertEqual(shelf.count, EditorMarkShelf.capacity)
        XCTAssertEqual(ended.count, 100 - EditorMarkShelf.capacity, "each one over was ended, none dropped")
        XCTAssertEqual(stood(ended), Array(repeating: 2, count: 100 - EditorMarkShelf.capacity))
        XCTAssertEqual(shelf.parked.map(\.field.pid), (92..<100).map { pid_t(1000 + $0) }, "the newest are kept")
    }

    func testSwitchingTheEditorOffEndsEverythingOnTheShelf() {
        var shelf = EditorMarkShelf()
        _ = shelf.park(ledger(), of: field(pid: 1), issues: [typo], hiddenAt: at(1.5), at: at(2))
        _ = shelf.park(ledger(), of: field(pid: 2), issues: [typo], hiddenAt: at(1.5), at: at(3))
        XCTAssertEqual(stood(shelf.drain(at: at(50))), [1.5, 1.5])
        XCTAssertEqual(shelf.count, 0)
    }
}
