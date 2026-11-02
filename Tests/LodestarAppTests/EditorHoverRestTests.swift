import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// "A pointer crossing the text opens nothing": the card waits for the
/// pointer to rest on the word, not merely to be over it for a while.
final class EditorHoverRestTests: XCTestCase {
    private let word = EditorController.Mark(
        issue: EditorIssue(range: NSRange(location: 100, length: 5), original: "Their", replacement: "They're",
                           kind: .grammar),
        rect: CGRect(x: 100, y: 300, width: 160, height: 18))

    private func rig(_ marks: [EditorController.Mark]) -> (EditorHover, VirtualClock, (CGPoint) -> Void) {
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        var point = CGPoint(x: 0, y: 0)
        hover.marks = { marks }
        hover.pointer = { point }
        addTeardownBlock { hover.panel?.close() }
        return (hover, clock, { point = $0 })
    }

    /// A sweep across a long word at hand speed: ten points an event, an
    /// event every sixteen milliseconds, so the pointer is over the word
    /// for a quarter second and has never rested.
    func testAPointerSweepingAcrossAWordOpensNothing() {
        let (hover, clock, move) = rig([word])
        var x: CGFloat = 96
        while x < 270 {
            move(CGPoint(x: x, y: 309))
            hover.moved()
            clock.advance(by: 0.016)
            x += 10
        }
        XCTAssertNil(hover.shown, "over the word for longer than the dwell, and never still")
        clock.advance(by: 1)
        XCTAssertNil(hover.shown)
    }

    func testASlowCrawlAcrossAWordOpensNothing() {
        let (hover, clock, move) = rig([word])
        var x: CGFloat = 100
        while x < 250 {
            move(CGPoint(x: x, y: 309))
            hover.moved()
            clock.advance(by: 0.05)
            x += 2.5
        }
        XCTAssertNil(hover.shown, "each step is within the rest, the drift is not")
    }

    func testAPointerThatStopsOnTheWordOpensItsCard() {
        let (hover, clock, move) = rig([word])
        var x: CGFloat = 96
        while x < 150 {
            move(CGPoint(x: x, y: 309))
            hover.moved()
            clock.advance(by: 0.016)
            x += 10
        }
        XCTAssertNil(hover.shown, "still moving")
        clock.advance(by: EditorHover.dwell + 0.01)
        XCTAssertEqual(hover.shown, word, "it stopped, and the dwell ran from there")
    }

    func testAHandThatTremblesStillRests() {
        let (hover, clock, move) = rig([word])
        for jitter: CGFloat in [0, 1.5, -1, 2, 0.5] {
            move(CGPoint(x: 140 + jitter, y: 309 + jitter / 2))
            hover.moved()
            clock.advance(by: 0.02)
        }
        clock.advance(by: EditorHover.dwell)
        XCTAssertEqual(hover.shown, word)
    }

    func testRestingBeginsAgainFromWhereThePointerMovedTo() {
        let (hover, clock, move) = rig([word])
        move(CGPoint(x: 110, y: 309))
        hover.moved()
        clock.advance(by: EditorHover.dwell - 0.03)
        move(CGPoint(x: 200, y: 309))
        hover.moved()
        clock.advance(by: 0.05)
        XCTAssertNil(hover.shown, "the first rest was spent when the pointer moved")
        clock.advance(by: EditorHover.dwell)
        XCTAssertEqual(hover.shown, word)
    }

    func testAnOpenCardStillHandsOffToTheNextMarkAtOnce() {
        let second = EditorController.Mark(
            issue: EditorIssue(range: NSRange(location: 300, length: 7), original: "recieve", replacement: "receive",
                               kind: .spelling),
            rect: CGRect(x: 300, y: 300, width: 60, height: 18))
        let (hover, clock, move) = rig([word, second])
        move(CGPoint(x: 120, y: 309))
        hover.moved()
        clock.advance(by: EditorHover.dwell + 0.01)
        XCTAssertEqual(hover.shown, word)
        move(CGPoint(x: 330, y: 309))
        hover.moved()
        XCTAssertEqual(hover.shown, second, "no rest asked of a pointer already reading cards")
    }
}
