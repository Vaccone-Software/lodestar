import CoreGraphics
import XCTest
@testable import LodestarCore

/// The one rule every synthetic press shares: the pointer walks before
/// it presses. Ghostty takes a press with no position — the position is
/// whatever the last move or drag carried — so a press without a move
/// before it landed wherever the pointer had last rested.
final class SyntheticPointerTests: XCTestCase {
    private let a = CGPoint(x: 100, y: 200)
    private let b = CGPoint(x: 300, y: 200)

    private func assertWalksBeforePressing(_ steps: [SyntheticPointer.Step],
                                           file: StaticString = #filePath, line: UInt = #line) {
        for (index, step) in steps.enumerated()
        where step.type == .leftMouseDown || step.type == .rightMouseDown {
            let before = index > 0 ? steps[index - 1] : nil
            XCTAssertEqual(before?.type, .mouseMoved,
                           "a press is preceded by a move", file: file, line: line)
            XCTAssertEqual(before?.point, step.point,
                           "the move lands where the press will", file: file, line: line)
        }
    }

    func testAClickWalksThenPressesThenReleases() {
        let steps = SyntheticPointer.click(at: a)
        assertWalksBeforePressing(steps)
        XCTAssertEqual(steps.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertTrue(steps.allSatisfy { $0.point == a })
    }

    func testARightClickUsesTheRightButton() {
        let steps = SyntheticPointer.click(at: a, right: true)
        assertWalksBeforePressing(steps)
        XCTAssertEqual(steps.map(\.type), [.mouseMoved, .rightMouseDown, .rightMouseUp])
    }

    func testADragWalksToTheStartAndReleasesAtTheEnd() {
        let steps = SyntheticPointer.drag(from: a, to: b)
        assertWalksBeforePressing(steps)
        XCTAssertEqual(steps.first, SyntheticPointer.Step(.mouseMoved, a))
        XCTAssertEqual(steps.last, SyntheticPointer.Step(.leftMouseUp, b))
        XCTAssertEqual(steps.filter { $0.type == .leftMouseDragged }.count, 2,
                       "through the middle, then to the end")
        XCTAssertEqual(steps.filter { $0.type == .leftMouseDragged }.last?.point, b)
    }

    func testHomeIsAMoveNotAWarp() {
        XCTAssertEqual(SyntheticPointer.home(a), [SyntheticPointer.Step(.mouseMoved, a)])
    }
}
