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

}
