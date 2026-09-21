import XCTest
@testable import lodestar
@testable import LodestarCore

/// The health pulse through the real tap.
///
/// `HealthTests` proves the accumulator's arithmetic on a value type.
/// This proves the half that lives in the event tap and cannot be reached
/// from there: that a press is timed from the hand's own key-down to its
/// key-up, that a key the OS repeated never becomes a very slow
/// keystroke, that a key Lodestar swallows is still a key a hand pressed,
/// and that nothing an agent posts is ever counted as a hand at all.
final class HealthScenarioTests: XCTestCase {
    private var stage: Stage!

    override func setUp() {
        super.setUp()
        stage = Stage()
    }

    override func tearDown() {
        stage = nil
        super.tearDown()
    }

    /// The raw record: a press leaves with its hand, its kind and its
    /// hold, and a press the engine kept leaves marked as a gesture.
    func testARawPressNamesTheHandAndTheKindAndNeverTheKey() throws {
        stage.pressHeld("a", for: 0.085)
        stage.pressHeld("j", for: 0.11, shift: true)
        stage.pressHeld("space", for: 0.07)
        XCTAssertEqual(stage.presses.count, 3)
        let a = stage.presses[0], j = stage.presses[1], space = stage.presses[2]
        XCTAssertEqual(a.hand, .left)
        XCTAssertEqual(a.kind, .letter)
        XCTAssertEqual(a.hold!, 0.085, accuracy: 0.002)
        XCTAssertFalse(a.gesture)
        XCTAssertFalse(a.shift)
        XCTAssertEqual(j.hand, .right)
        XCTAssertTrue(j.shift)
        XCTAssertFalse(j.chord)
        XCTAssertEqual(space.hand, .thumb)
        XCTAssertEqual(space.kind, .space)
        XCTAssertTrue(space.isTyping)
    }

    /// The keyboard's declaration reaches the row: enter on a split
    /// board lands in the store under the thumb, with the hand column —
    /// the windows' class — exactly as the tap named it.
    func testADeclaredKeyLandsInTheStoreUnderItsFinger() {
        stage.health.setFingerMap(FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb)]]))
        stage.health.forceKeyboardForTesting("kb")
        stage.pressHeld("return", for: 0.08)
        stage.pressHeld("a", for: 0.085)
        stage.health.drainForTesting()
        stage.health.flush()
        let keys = stage.directory.appendingPathComponent(KeyStore.subdirectory)
        let presses = KeyStore.days(in: keys).flatMap { KeyStore.presses(day: $0, in: keys) }
        XCTAssertEqual(presses.count, 2)
        XCTAssertEqual(presses[0].kind, .enter)
        XCTAssertEqual(presses[0].finger, .thumb, "declared")
        XCTAssertEqual(presses[0].hand, .other, "the hand column is not the map's to move")
        XCTAssertEqual(presses[1].finger, .pinky, "a letter keeps its column")
        // Read back under the same declaration, the row says the same.
        XCTAssertEqual(presses[0].relabeled(by: FingerMap(), keyboard: "kb").finger, .thumb,
                       "the stored finger is what the tap wrote")
    }

    /// Through the real monitor: the presses the tap timed are in the
    /// raw store at the scratch directory, every column filled in.
    func testTheRealMonitorKeepsThePressesInItsRawStore() {
        stage.pressHeld("a", for: 0.085)
        stage.pressHeld("j", for: 0.11, shift: true)
        stage.health.drainForTesting()
        stage.health.flush()
        let keys = stage.directory.appendingPathComponent(KeyStore.subdirectory)
        let presses = KeyStore.days(in: keys).flatMap { KeyStore.presses(day: $0, in: keys) }
        XCTAssertEqual(presses.count, 2)
        XCTAssertEqual(presses.map(\.finger), [.pinky, .index])
        XCTAssertEqual(presses.map(\.hand), [.left, .right])
        XCTAssertTrue(presses[1].modifiers.contains(.shift))
    }

    func testAGestureIsARawPressMarkedAsOne() {
        // A lode chain letter is swallowed by the engine: still a press
        // the hand made, kept, and marked so the typing habit excludes it.
        _ = stage.lode("a")
        XCTAssertTrue(stage.presses.contains { $0.gesture },
                      "a swallowed press should be recorded as a gesture")
        XCTAssertFalse(stage.presses.contains { $0.gesture && $0.isTyping })
    }

    func testAPressIsTimedFromItsOwnKeyDown() throws {
        stage.pressHeld("a", for: 0.085)
        stage.pressHeld("s", for: 0.11)
        XCTAssertEqual(stage.holds.count, 2)
        XCTAssertEqual(stage.holds[0], 0.085, accuracy: 0.002)
        XCTAssertEqual(stage.holds[1], 0.11, accuracy: 0.002)
        let pulse = try XCTUnwrap(stage.pulse.flush(now: stage.clock.now))
        XCTAssertEqual(pulse.holdN, 2)
        XCTAssertEqual(pulse.keys, 2)
        XCTAssertEqual(pulse.holdHist?.total, 2)
    }

    /// A held key releases whole seconds after it went down. The repeat
    /// flag marks the press contaminated where it happens, so the hold
    /// never reaches the pulse to be discarded by a ceiling later.
    func testARepeatedKeyIsNeverTimed() {
        stage.pressRepeatedThenRelease("j", for: 2.5)
        XCTAssertTrue(stage.holds.isEmpty,
                      "the hand made one press; the OS made the rest, and neither has a hold")
    }

    /// Lodestar swallows keys all the time — every letter of a chain.
    /// The pulse measures the hand, not the effect, so a swallowed key
    /// is timed exactly like one that passed through.
    func testASwallowedKeyIsStillAPressAHandMade() throws {
        stage.hold()
        let swallowed = stage.pressHeld("g", for: 0.07)
        stage.release()
        XCTAssertTrue(swallowed, "a chain letter is swallowed, which is the point of the case")
        XCTAssertEqual(stage.holds.count, 1)
        XCTAssertEqual(try XCTUnwrap(stage.holds.first), 0.07, accuracy: 0.002)
    }

    /// The provenance line the coach already holds: an agent driving the
    /// machine is not the user's hands, and a mirror that counted
    /// synthetic input would flatter exactly the hours nobody was there.
    func testPostedInputIsNotAHand() {
        stage.pressHeld("a", for: 0.09, posted: true)
        XCTAssertTrue(stage.holds.isEmpty)
        XCTAssertNil(stage.pulse.flush(now: stage.clock.now),
                     "nothing a process posted ever opened a window")
    }

    /// The bout, end to end: work, ten quiet minutes, work again. The
    /// break closes the window where it fell and the next input starts a
    /// new bout at index zero.
    func testAQuietStretchEndsTheBout() throws {
        stage.pressHeld("a", for: 0.08)
        stage.clock.advance(by: 60)
        stage.pressHeld("s", for: 0.08)
        stage.clock.advance(by: HealthPulse.boutGap + 30)
        stage.pressHeld("d", for: 0.08)
        let first = try XCTUnwrap(stage.pulses.first)
        XCTAssertEqual(first.keys, 2, "the bout that ended, closed whole")
        XCTAssertEqual(first.boutIndex, 0)
        let second = try XCTUnwrap(stage.pulse.flush(now: stage.clock.now))
        XCTAssertEqual(second.keys, 1)
        XCTAssertEqual(second.boutIndex, 0, "and the new bout counts from zero")
        XCTAssertEqual(second.ikN, 0)
        XCTAssertNil(second.ikTailN, "ten minutes of nothing is not a gap of typing")
    }

    /// The correction key is still the only key with a name, and the
    /// hold times beside it still have none.
    func testTheCorrectionKeyIsStillTheOnlyNamedOne() throws {
        stage.pressHeld("a", for: 0.08)
        stage.pressHeld("delete", for: 0.06)
        stage.pressHeld("delete", for: 0.06)
        let pulse = try XCTUnwrap(stage.pulse.flush(now: stage.clock.now))
        XCTAssertEqual(pulse.keys, 3)
        XCTAssertEqual(pulse.backspaces, 2)
        XCTAssertEqual(pulse.holdN, 3, "every press timed, and not one of them named")
    }
}
