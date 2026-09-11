import XCTest
@testable import lodestar
@testable import LodestarCore

/// Scroll mode through the tap: the wheel is caught before the window
/// server sees it, so what these hold is the physics the hand feels —
/// how far a tick moves, and that shift changes it without lifting the
/// key. The glide runs on its real 120Hz timer; the stage spins the run
/// loop until it has ticked.
final class ScrollScenarioTests: XCTestCase {

    private func enterScroll(_ stage: Stage, file: StaticString = #filePath, line: UInt = #line) {
        stage.lode("`")
        XCTAssertTrue(stage.engine.pill.isVisible, "scroll mode wears the pill", file: file, line: line)
    }

    /// Hold j, then press shift mid-glide: the next ticks are three times
    /// the distance. Release shift and they settle, key still down.
    func testShiftMidGlideTriplesTheWheelAndSettlesOnRelease() {
        let stage = Stage()
        enterScroll(stage)

        XCTAssertTrue(stage.keyDown("j"), "a direction key is swallowed")
        stage.pump(until: { !stage.wheel.isEmpty })
        let slow = Set(stage.wheel.map { abs($0.dy) })
        XCTAssertEqual(slow, [15], "1800 px/s over 120 ticks")

        stage.wheel = []
        stage.shift(true)
        XCTAssertTrue(stage.scroller.fast)
        stage.pump(until: { !stage.wheel.isEmpty })
        XCTAssertEqual(Set(stage.wheel.map { abs($0.dy) }), [45])

        stage.wheel = []
        stage.shift(false)
        XCTAssertFalse(stage.scroller.fast)
        stage.pump(until: { !stage.wheel.isEmpty })
        XCTAssertEqual(Set(stage.wheel.map { abs($0.dy) }), [15])

        stage.keyUp("j")
        stage.wheel = []
        stage.pump(until: { false }, turns: 5)
        XCTAssertTrue(stage.wheel.isEmpty, "the glide stops the instant the key lifts")
    }

    /// A direction that goes down with shift already held is fast from
    /// its first tick.
    func testShiftedDirectionIsFastFromTheFirstTick() {
        let stage = Stage()
        enterScroll(stage)

        stage.shift(true)
        stage.keyDown("j", shift: true)
        stage.pump(until: { !stage.wheel.isEmpty })
        XCTAssertEqual(Set(stage.wheel.map { abs($0.dy) }), [45])
        stage.keyUp("j", shift: true)
        stage.shift(false)
    }

    /// The aim landing on a stage: the pointer is not moved (the stage
    /// catches the wheel and has no pointer), the point is recorded, and
    /// the guide comes back naming the word. Nothing is pressed.
    func testAimedRecordsThePointAndNamesTheWordInTheGuide() {
        let stage = Stage()
        enterScroll(stage)
        stage.scroller.aimed(at: CGPoint(x: 300, y: 400), label: "Threads")
        XCTAssertEqual(stage.scroller.aimPoint, CGPoint(x: 300, y: 400))
        XCTAssertEqual(stage.scroller.aimLabel, "Threads")
        XCTAssertTrue(stage.wheel.isEmpty, "an aim posts no wheel and no click")
    }

    /// `/` with no window to read: the flash says so and scroll mode stays
    /// on — the j that follows is still a scroll.
    func testSlashWithoutAWindowStaysInScroll() {
        let stage = Stage()
        enterScroll(stage)
        XCTAssertTrue(stage.press("/"), "swallowed by the mode")
        XCTAssertTrue(stage.press("d"), "still scroll's key")
        XCTAssertEqual(stage.wheel.count, 1, "the half page landed: scroll mode is still on")
    }

    /// `0` and `$` glide to the horizontal edges in a window with no
    /// native pane: one axis, opposite signs.
    func testZeroAndDollarGlideToTheHorizontalEdges() {
        let stage = Stage()
        enterScroll(stage)
        XCTAssertTrue(stage.press("0"))
        stage.pump(until: { !stage.wheel.isEmpty })
        XCTAssertTrue(stage.wheel.allSatisfy { $0.dy == 0 && $0.dx != 0 }, "horizontal only")
        let leftward = stage.wheel[0].dx
        stage.wheel = []
        XCTAssertTrue(stage.press("4", shift: true))
        stage.pump(until: { !stage.wheel.isEmpty })
        XCTAssertTrue(stage.wheel.allSatisfy { $0.dy == 0 && $0.dx != 0 })
        XCTAssertEqual(stage.wheel[0].dx, -leftward, "$ is the other edge")
    }

    /// A click or the hand's own wheel ends the lens; the session record
    /// says so, with what the hands did in it.
    func testAClickEndsScrollModeAndTheRecordSaysSo() {
        let stage = Stage()
        enterScroll(stage)
        _ = stage.press("d")
        _ = stage.press("k")
        stage.engine.pointerInterrupted(.click)
        XCTAssertNotEqual(stage.hud.owner, .guide, "the guide is down")
        XCTAssertFalse(stage.press("j"), "j passes through: the mode is over")
        let record = stage.lastScroll
        XCTAssertEqual(record?.action, "click")
        XCTAssertEqual(record?.pages, 1)
        XCTAssertEqual(record?.keys, 1)
        XCTAssertEqual(record?.aims, 0)
    }

    func testAHumanWheelEndsScrollMode() {
        let stage = Stage()
        enterScroll(stage)
        stage.engine.pointerInterrupted(.wheel)
        XCTAssertFalse(stage.press("j"), "the mode is over")
        XCTAssertEqual(stage.lastScroll?.action, "wheel")
    }

    /// Escape's record: the way out, the ends, and an aim that landed
    /// outside the focused window counted as away.
    func testEscapeRecordCountsEndsAndAims() {
        let stage = Stage()
        enterScroll(stage)
        _ = stage.press("g", shift: true)
        stage.scroller.noteAimOpened()
        stage.scroller.aimed(at: CGPoint(x: -5000, y: -5000), label: "Elsewhere")
        _ = stage.press("escape")
        let record = stage.lastScroll
        XCTAssertEqual(record?.action, "escape")
        XCTAssertEqual(record?.ends, 1)
        XCTAssertEqual(record?.aims, 1)
        XCTAssertEqual(record?.aimsLanded, 1)
        XCTAssertGreaterThanOrEqual(record?.seconds ?? -1, 0)
    }

    /// The pill on entry: scroll's symbol and word on the leading wing,
    /// the app on the trailing wing, and nothing between them, because
    /// nothing has been said and scroll does not listen until `/`.
    func testEntryWearsTheStandingPill() {
        let stage = Stage()
        enterScroll(stage)
        let state = stage.engine.pill.state
        XCTAssertEqual(state?.mode, .scroll)
        XCTAssertEqual(state?.listening, false)
        XCTAssertNil(state?.text)
        XCTAssertEqual(ModePill.layout(for: state!).first, .symbol("arrow.up.and.down"))
        XCTAssertFalse(ModePill.layout(for: state!).contains(.caret), "scroll is not listening")
    }

    /// A landed aim folds the pill: the word is the only thing between
    /// the glyphs, and it is the hand's word.
    func testALandedAimFoldsThePillToTheWord() {
        let stage = Stage()
        enterScroll(stage)
        // The landing arrives off the keystroke, after the mode redrew;
        // the scroller tells the shell and the pill folds then.
        stage.scroller.aimed(at: CGPoint(x: 300, y: 400), label: "Threads")
        let state = stage.engine.pill.state
        XCTAssertEqual(state?.text, "Threads")
        XCTAssertEqual(ModePill.layout(for: state!),
                       [.symbol("arrow.up.and.down"), .text("Threads"), state?.icon == nil ? .appWord(state!.app) : .appIcon])
    }

    /// Leaving the mode takes the pill down.
    func testLeavingHidesThePill() {
        let stage = Stage()
        enterScroll(stage)
        _ = stage.press("escape")
        XCTAssertFalse(stage.engine.pill.isVisible)
        XCTAssertNil(stage.engine.pill.state)
    }

    /// lode ? inside the mode: the sheet shows scroll's own keys and the
    /// mode stays up; escape takes the sheet down and the mode is still
    /// there for the next key.
    func testTheSheetInsideScrollMode() {
        let stage = Stage()
        enterScroll(stage)
        XCTAssertTrue(stage.press("/", shift: true), "a plain ? is swallowed by the lens, never a door")
        XCTAssertFalse(stage.engine.cheatVisible, "and opens nothing")
        stage.hold()
        XCTAssertTrue(stage.press("/", shift: true), "lode ? is the one door")
        stage.release()
        XCTAssertTrue(stage.engine.cheatVisible, "the sheet is up")
        XCTAssertTrue(stage.engine.pill.isVisible, "and the mode is still up")
        XCTAssertTrue(stage.press("escape"), "escape is the sheet's")
        XCTAssertFalse(stage.engine.cheatVisible)
        XCTAssertTrue(stage.engine.pill.isVisible, "the mode survived the escape")
        XCTAssertTrue(stage.press("d"), "and still owns its keys")
        XCTAssertEqual(stage.wheel.count, 1)
    }

    /// d is half the pane; ⇧D is the whole of it.
    func testShiftDIsAFullPage() {
        let stage = Stage()
        enterScroll(stage)

        stage.press("d")
        XCTAssertEqual(stage.wheel.count, 1)
        let half = abs(stage.wheel[0].dy)
        XCTAssertGreaterThan(half, 0)

        stage.wheel = []
        stage.press("d", shift: true)
        XCTAssertEqual(stage.wheel.count, 1)
        let full = abs(stage.wheel[0].dy)
        XCTAssertLessThanOrEqual(abs(full - 2 * half), 1)
    }
}
