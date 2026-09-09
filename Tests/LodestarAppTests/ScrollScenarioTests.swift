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
        XCTAssertEqual(stage.hud.owner, .guide, "scroll mode shows its guide", file: file, line: line)
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
