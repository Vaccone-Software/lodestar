import XCTest
@testable import lodestar
@testable import LodestarCore

/// Tap, or hold. A tap of lode — down and up, shorter than a peek,
/// nothing struck inside — arms the next key as the gesture it would be
/// under the hold, for one second. The hold is unchanged. Through the
/// real engine on the virtual clock: the summon, the expiry, the
/// silence however long the hand waits, escape, the double-tap that is
/// assent and never an arm, the switch, and the record's mark.
final class LodeTapScenarioTests: XCTestCase {
    private var stage: Stage!

    override func setUp() {
        super.setUp()
        stage = Stage()
    }

    override func tearDown() {
        stage = nil
        super.tearDown()
    }

    private func setTap(_ on: Bool) {
        var config = stage.engine.config
        config.lodeTap = on
        stage.engine.config = config
    }

    func testATapThenALetterIsTheGestureTheHoldWouldBe() {
        stage.tapLode()
        stage.clock.advance(by: 0.2)
        let swallowed = stage.press("s")
        XCTAssertTrue(swallowed, "the letter was the instrument's")
        XCTAssertEqual(stage.actions.summoned.map(\.target), [.app("Slack")])
        XCTAssertTrue(stage.engine.isQuiet, "a plain summon: the phrase ended with the key")
    }

    func testTheArmSpendsItselfOnOneKey() {
        stage.tapLode()
        stage.clock.advance(by: 0.1)
        stage.press("s")
        stage.clock.advance(by: 0.1)
        XCTAssertFalse(stage.press("s"), "the second s is typing")
        XCTAssertEqual(stage.actions.summoned.count, 1)
    }

    func testATapFollowedByNothingExpiresSilently() {
        stage.tapLode()
        stage.clock.advance(by: HotkeyEngine.armSeconds + 0.1)
        XCTAssertFalse(stage.press("s"), "typed, not summoned")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    /// A tap puts nothing on the glass, however long the hand waits. A
    /// mark saying lode was armed was built and taken out again: nine
    /// gestures in ten strike inside 300 ms, so it would have been
    /// motion on almost every one, and what bounds the state the eye
    /// cannot see is the expiry, not something the eye has to find.
    func testATapPutsNothingOnTheGlass() {
        stage.tapLode()
        for _ in 0..<4 {
            stage.clock.advance(by: 0.2)
            XCTAssertFalse(stage.engine.pill.isVisible, "nothing appears while the arm stands")
        }
        XCTAssertTrue(stage.press("s"), "and the gesture still lands")
        XCTAssertFalse(stage.engine.pill.isVisible)
        XCTAssertEqual(stage.actions.summoned.map(\.target), [.app("Slack")])
    }

    func testEscapeDisarmsAndIsSwallowed() {
        stage.tapLode()
        stage.clock.advance(by: 0.1)
        XCTAssertTrue(stage.press("escape"), "aimed at the instrument")
        XCTAssertFalse(stage.press("s"), "typed")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    func testADoubleTapIsAssentAndNeverLeavesAnArm() {
        stage.raiseChip()
        stage.doubleTapLode()
        XCTAssertEqual(stage.edits, [.bindTarget(chain: ["n"], target: "Notes")])
        stage.clock.advance(by: 0.1)
        XCTAssertFalse(stage.press("s"), "no arm survives the second tap")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    func testAHoldStillPeeksAndStillGestures() {
        stage.hold()
        stage.clock.advance(by: 0.5)
        XCTAssertEqual(stage.hud.owner, .guide, "the map appears under a hold as ever")
        XCTAssertTrue(stage.press("s"))
        stage.release()
        XCTAssertEqual(stage.actions.summoned.map(\.target), [.app("Slack")])
        XCTAssertFalse(stage.presses.last?.armed ?? true, "a held gesture is not an armed one")
    }

    func testTheSwitchOffMakesATapMeanNothingAgain() {
        setTap(false)
        stage.tapLode()
        stage.clock.advance(by: 0.1)
        XCTAssertFalse(stage.press("s"), "typed")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    func testAPostedTapArmsNothing() {
        stage.tapLode(posted: true)
        stage.clock.advance(by: 0.1)
        XCTAssertFalse(stage.press("s"), "an agent's tap is not a hand's")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    /// The record carries the trade: a key that arrived armed says so,
    /// and is a gesture the hand made, so the tap's use can be read.
    func testTheRawRecordMarksTheArmedPress() {
        stage.tapLode()
        stage.clock.advance(by: 0.1)
        stage.press("s")
        let armed = stage.presses.last!
        XCTAssertTrue(armed.armed)
        XCTAssertTrue(armed.gesture, "swallowed, and still a hand's press")
        XCTAssertEqual(armed.kind, .letter)
        stage.press("a")
        XCTAssertFalse(stage.presses.last!.armed, "ordinary typing is not marked")
    }
}
