import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the record keeps of the hand after Keep closes: how a left opening
/// closed, and the first thing the hand did next. The opening's event waits
/// for that word and keeps the time it ended at, not the watch's.
final class KeepAfterwardsTests: XCTestCase {
    private let command: CGEventFlags = .maskCommand

    /// Every strip record written so far, without settling the watch.
    private func written(_ stage: Stage) -> [ObservationEvent] {
        stage.observations.flush()
        return stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
            .filter { $0.kind == .paste }
    }

    private func opened() -> Stage {
        let stage = Stage()
        stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        return stage
    }

    func testEscapeThenAPasteWithinTenSecondsIsClosedByEscapeAndFollowedByPaste() {
        let stage = opened()
        stage.clock.advance(by: 1)
        stage.press("escape")
        XCTAssertTrue(written(stage).isEmpty, "held until the hand has said what it did")
        stage.clock.advance(by: 9)
        stage.chord("v", command)
        let events = written(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "abandoned")
        XCTAssertEqual(events.first?.closed, "escape")
        XCTAssertEqual(events.first?.after, "paste")
        XCTAssertEqual(events.first?.seconds ?? 0, 1, accuracy: 0.01, "the opening's duration, not the watch's")
    }

    func testTheEventKeepsTheTimeTheOpeningEnded() throws {
        let stage = opened()
        stage.clock.advance(by: 1)
        stage.press("escape")
        let ended = stage.clock.now
        stage.clock.advance(by: 4)
        stage.chord("c", command)
        let event = try XCTUnwrap(written(stage).first)
        XCTAssertEqual(event.t.timeIntervalSince(ended), 0, accuracy: 0.01)
        XCTAssertEqual(event.after, "copy")
    }

    func testNoKeyForTenSecondsWritesTheOpeningWithNothingAfter() {
        let stage = opened()
        stage.press("escape")
        stage.clock.advance(by: 9)
        XCTAssertTrue(written(stage).isEmpty)
        stage.clock.advance(by: 2)
        let events = written(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.closed, "escape")
        XCTAssertNil(events.first?.after)
    }

    func testAKeyAfterTheWindowIsNoPartOfIt() {
        let stage = opened()
        stage.press("escape")
        stage.clock.advance(by: 11)
        stage.chord("v", command)
        XCTAssertNil(written(stage).first?.after)
        XCTAssertEqual(written(stage).count, 1, "written once, by the clock")
    }

    func testAnyOtherKeyEndsTheWatchAsTyped() {
        let stage = opened()
        stage.press("escape")
        stage.clock.advance(by: 2)
        stage.press("q")
        stage.chord("v", command)
        let events = written(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.after, "typed", "the first key decides and the rest are not read")
    }

    func testHowAnOpeningClosed() {
        // The toggle.
        var stage = opened()
        stage.openStrip()
        stage.press("q")
        XCTAssertEqual(written(stage).last?.closed, "toggle")
        // A click.
        stage = opened()
        stage.engine.clickedAway()
        stage.press("q")
        XCTAssertEqual(written(stage).last?.closed, "click")
        // A lode gesture.
        stage = opened()
        stage.hold()
        stage.press("s")
        stage.release()
        stage.press("q")
        XCTAssertEqual(written(stage).last?.closed, "lode")
        // The tap going dark.
        stage = opened()
        stage.tapDisabled()
        stage.press("q")
        XCTAssertEqual(written(stage).last?.closed, "other")
    }

    func testAPasteAndAnActLeaveClosedEmpty() {
        let stage = opened()
        stage.press("j")
        stage.press("q")
        let events = written(stage)
        XCTAssertEqual(events.first?.action, "pasted")
        XCTAssertNil(events.first?.closed)
    }

    func testAPasteThenUndoIsUndone() {
        let stage = opened()
        stage.press("j")
        XCTAssertEqual(stage.stripPastes, 1)
        stage.clock.advance(by: 3)
        stage.chord("z", command)
        let events = written(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "pasted")
        XCTAssertEqual(events.first?.after, "undo")
    }

    func testUndoMeansNothingAfterALook() {
        let stage = opened()
        stage.press("escape")
        stage.chord("z", command)
        XCTAssertEqual(written(stage).first?.after, "typed")
    }

    func testAPasteIsWatchedForFiveSecondsNotTen() {
        let stage = opened()
        stage.press("j")
        stage.clock.advance(by: 4)
        XCTAssertTrue(written(stage).isEmpty)
        stage.clock.advance(by: 2)
        XCTAssertEqual(written(stage).count, 1)
        XCTAssertNil(written(stage).first?.after)
    }

    func testLodestarsOwnPasteAfterThePasteIsNotTheHandPasting() {
        let stage = opened()
        stage.press("j")
        // The ⌘V a paste posts, arriving through the tap a moment later,
        // from this process and not from a hand.
        stage.chord("v", command, posted: true)
        XCTAssertTrue(written(stage).isEmpty, "a posted key does not end the watch")
        stage.clock.advance(by: 1)
        stage.chord("v", command)
        XCTAssertEqual(written(stage).first?.after, "paste", "the hand's own ⌘V does")
    }

    func testMatchStylePasteAndCopyAndCutAreTheirWords() {
        let flags: [(String, CGEventFlags, String)] = [
            ("v", [.maskCommand, .maskShift, .maskAlternate], "paste"),
            ("x", [.maskCommand], "copy"),
            ("v", [.maskCommand, .maskAlternate], "typed"),
            ("c", [.maskCommand, .maskShift], "typed"),
        ]
        for (key, held, word) in flags {
            let stage = opened()
            stage.press("escape")
            stage.chord(key, held)
            XCTAssertEqual(written(stage).first?.after, word, "\(key) with \(held.rawValue)")
        }
    }

    func testANewOpeningWritesThePendingOneAsReopen() {
        let stage = opened()
        stage.press("escape")
        stage.clock.advance(by: 2)
        stage.openStrip()
        let events = written(stage)
        XCTAssertEqual(events.count, 1, "the second opening is still open")
        XCTAssertEqual(events.first?.closed, "escape")
        XCTAssertEqual(events.first?.after, "reopen")
        stage.press("escape")
        stage.clock.advance(by: 11)
        XCTAssertEqual(written(stage).count, 2)
        XCTAssertNil(written(stage).last?.after)
    }

    func testBringAndBackIsStillOneOpeningWithNoPendingBetween() {
        let stage = opened()
        stage.engine.bringFront = { 4242 }
        stage.engine.bringTypes = { _, _ in }
        stage.engine.bringWindows = {
            [BringReader.Window(source: Bring.Source(app: "Ghostty", window: "~/web", rank: 0), pid: 1,
                                lines: ["ssh build-02.internal"])]
        }
        stage.press("=")
        stage.press("escape")
        XCTAssertTrue(written(stage).isEmpty)
        stage.press("escape")
        stage.press("q")
        let events = written(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "acted")
        XCTAssertNil(events.first?.closed)
        XCTAssertEqual(events.first?.after, "typed")
    }
}
