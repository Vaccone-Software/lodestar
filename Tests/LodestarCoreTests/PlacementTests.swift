import XCTest
@testable import LodestarCore

final class PlacementTests: XCTestCase {
    func testBesideAlwaysArranges() {
        XCTAssertEqual(Placement.decide(beside: true, memberOfDisplay: 2, activeDisplay: 1), .add)
        XCTAssertEqual(Placement.decide(beside: true, memberOfDisplay: nil, activeDisplay: 1), .add)
        XCTAssertEqual(Placement.decide(beside: true, memberOfDisplay: 1, activeDisplay: 1), .add)
    }

    func testPlainVisitsCrossDisplay() {
        XCTAssertEqual(Placement.decide(beside: false, memberOfDisplay: 2, activeDisplay: 1), .visit)
    }

    func testPlainReplacesLocallyAndForHidden() {
        XCTAssertEqual(Placement.decide(beside: false, memberOfDisplay: 1, activeDisplay: 1), .replace)
        XCTAssertEqual(Placement.decide(beside: false, memberOfDisplay: nil, activeDisplay: 1), .replace)
    }

    func testReorderInsertAndShift() {
        XCTAssertEqual(Placement.reorder([10, 20, 30, 40], move: 40, toDigit: 1), [40, 10, 20, 30])
        XCTAssertEqual(Placement.reorder([10, 20, 30, 40], move: 10, toDigit: 3), [20, 30, 10, 40])
    }

    func testReorderNineMeansLast() {
        XCTAssertEqual(Placement.reorder([10, 20, 30], move: 10, toDigit: 9), [20, 30, 10])
    }

    func testReorderRejectsNoopsAndInvalid() {
        XCTAssertNil(Placement.reorder([10, 20, 30], move: 10, toDigit: 1), "already there")
        XCTAssertNil(Placement.reorder([10, 20, 30], move: 99, toDigit: 1), "not a member")
        XCTAssertNil(Placement.reorder([10, 20, 30], move: 10, toDigit: 5), "out of range")
        XCTAssertNil(Placement.reorder([10, 20, 30], move: 30, toDigit: 9), "already last")
    }


    func testHistoryRecordsAndBounces() {
        let history = FocusHistory()
        history.recordFocus(1)
        history.recordFocus(2)
        history.recordFocus(3)
        XCTAssertEqual(history.stepBack(isAlive: { _ in true }), 2)
        // The jump's own focus event must not truncate.
        history.recordFocus(2)
        XCTAssertEqual(history.stepBack(isAlive: { _ in true }), 1)
        history.recordFocus(1)
        XCTAssertEqual(history.stepForward(isAlive: { _ in true }), 2)
        history.recordFocus(2)
        XCTAssertEqual(history.stepForward(isAlive: { _ in true }), 3)
    }

    func testFreshNavigationTruncatesForward() {
        let history = FocusHistory()
        history.recordFocus(1)
        history.recordFocus(2)
        history.recordFocus(3)
        _ = history.stepBack(isAlive: { _ in true })   // at 2
        history.recordFocus(2)
        history.recordFocus(9)                          // fresh branch
        XCTAssertNil(history.stepForward(isAlive: { _ in true }), "3 was truncated")
        XCTAssertEqual(history.stepBack(isAlive: { _ in true }), 2)
    }

    func testDeadWindowsAreSkipped() {
        let history = FocusHistory()
        history.recordFocus(1)
        history.recordFocus(2)
        history.recordFocus(3)
        XCTAssertEqual(history.stepBack(isAlive: { $0 != 2 }), 1, "2 is dead; land on 1")
    }

    func testNothingFurtherBack() {
        let history = FocusHistory()
        history.recordFocus(1)
        XCTAssertNil(history.stepBack(isAlive: { _ in true }))
    }

    func testCapacityBounds() {
        let history = FocusHistory(capacity: 5)
        for id in 1...20 { history.recordFocus(CGWindowID(id)) }
        XCTAssertEqual(history.entries.count, 5)
        XCTAssertEqual(history.entries.last, 20)
    }
}
