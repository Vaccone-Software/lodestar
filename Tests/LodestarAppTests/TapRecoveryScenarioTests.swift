import XCTest
@testable import lodestar
@testable import LodestarCore

/// macOS switches the event tap off when a callback runs long or input
/// interrupts it, and the keys that fall in the dark never arrive: a
/// release, the rest of a chain. A chain left waiting for them swallows
/// every key that follows, which is the keyboard freezing. The recovery
/// is to forget what was in flight.
final class TapRecoveryScenarioTests: XCTestCase {
    /// lode ' starts a breath, a chain that waits for its letters.
    private func chainInFlight(_ stage: Stage) {
        stage.hold()
        stage.press("'")
        guard case .chain = stage.engine.grammarState else {
            return XCTFail("a chain is under way: \(stage.engine.grammarState)")
        }
    }

    func testATapOutageMidChainLeavesTheKeyboardFree() {
        let stage = Stage()
        chainInFlight(stage)
        // The release and the rest of the chain fall while the tap is off.
        stage.tapDisabled()
        XCTAssertEqual(stage.engine.grammarState, .idle, "what was in flight is forgotten")
        XCTAssertFalse(stage.press("a"), "the next letter reaches the app")
        XCTAssertFalse(stage.press("s"))
    }

    func testAnInterruptionByInputRecoversTheSameWay() {
        let stage = Stage()
        chainInFlight(stage)
        stage.tapDisabled(byTimeout: false)
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertFalse(stage.press("a"))
    }

    /// A lens that holds the keys (scroll) lets them go after an outage:
    /// the escape that would have closed it may have fallen in the dark.
    func testALensLetsTheKeysGoAfterAnOutage() {
        let stage = Stage()
        stage.lode("`")
        XCTAssertEqual(stage.engine.grammarState, .scroll)
        stage.tapDisabled()
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertFalse(stage.engine.pill.isVisible, "the lens's pill goes with it")
        XCTAssertFalse(stage.press("j"), "j is a letter again")
    }

    func testAGestureWorksAgainAfterAnOutage() {
        let stage = Stage()
        stage.hold()
        stage.tapDisabled()
        // A fresh lode, a fresh gesture: the launcher, as ever.
        stage.lode("space")
        stage.pump(until: { stage.searcher.isVisible })
        stage.press("escape")
    }

    /// Presses whose release fell in the dark leave as records with no
    /// hold, rather than timing at however long the tap was out, and the
    /// outage is counted.
    func testPressesInFlightAreStrandedNotTimed() {
        let stage = Stage()
        var stranded: [KeyPress] = []
        stage.engine.onHumanPress = { press in if press.hold == nil { stranded.append(press) } }
        var resets = 0
        stage.engine.onTapReset = { resets += 1 }
        XCTAssertFalse(stage.keyDown("j"))
        stage.clock.advance(by: 30)
        stage.tapDisabled()
        XCTAssertEqual(resets, 1, "the outage is counted")
        XCTAssertEqual(stranded.count, 1, "the press whose release was lost leaves with no hold")
        // Its release, arriving late, is not a thirty second hold.
        var timed: [KeyPress] = []
        stage.engine.onHumanPress = { timed.append($0) }
        stage.keyUp("j")
        XCTAssertFalse(timed.contains { ($0.hold ?? 0) > 1 }, "no hold measured across the outage")
    }
}
