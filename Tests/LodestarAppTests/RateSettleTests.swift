import CoreAudio
import XCTest
@testable import lodestar

/// A headset's profile flip, waited for instead of raced.
///
/// The field log: the first start on a radio at rest is refused (-10868),
/// the rebuild that follows at once reads the half-flipped radio again,
/// and an engine that starts across the flip is deaf 8 times in 13. The
/// rate is the thing that says the flip is done, so the build waits for
/// it. Driven here on a virtual clock and a scripted rate: nothing sleeps
/// and no radio is needed.
final class RateSettleTests: XCTestCase {
    /// The rate the radio reports at each moment, and the clock that
    /// moves when the wait pauses.
    private final class Radio {
        var now = 0.0
        var script: (Double) -> Double?
        var pauses = 0
        init(_ script: @escaping (Double) -> Double?) { self.script = script }
    }

    private func wait(_ radio: Radio, from stale: Double? = 48_000,
                      deadline: TimeInterval = RateSettle.deadline,
                      superseded: @escaping () -> Bool = { false }) -> RateSettle.Outcome {
        RateSettle.wait(from: stale, deadline: deadline,
                        rate: { radio.script(radio.now) }, superseded: superseded,
                        clock: { radio.now }, pause: { radio.now += $0; radio.pauses += 1 })
    }

    /// The case from the log: music rate until the flip lands, then the
    /// hands-free rate. The wait ends a quiet period after the landing,
    /// not at the first sight of the new rate.
    func testItWaitsForTheRateToLandAndHold() {
        let radio = Radio { $0 < 2.0 ? 48_000 : 24_000 }
        guard case .settled(let rate, let seconds) = wait(radio) else { return XCTFail("did not settle") }
        XCTAssertEqual(rate, 24_000)
        XCTAssertGreaterThanOrEqual(seconds, 2.0 + RateSettle.quiet - 0.001)
        XCTAssertLessThan(seconds, 2.0 + RateSettle.quiet + 0.2)
    }

    /// An engine that started across the flip already knows the new rate:
    /// only the quiet period is owed, not a search for a change.
    func testARateThatAlreadyMovedOwesOnlyTheQuietPeriod() {
        let radio = Radio { _ in 24_000 }
        guard case .settled(_, let seconds) = wait(radio) else { return XCTFail("did not settle") }
        XCTAssertEqual(seconds, RateSettle.quiet, accuracy: RateSettle.poll + 0.001)
    }

    /// A radio can post one rate and then another a beat later; the
    /// settled rate is the one that held.
    func testARateThatKeepsMovingIsNotBelievedUntilItStops() {
        let radio = Radio { t in
            if t < 1.0 { return 48_000 }
            if t < 1.2 { return 16_000 }
            if t < 1.4 { return 24_000 }
            return 16_000
        }
        guard case .settled(let rate, let seconds) = wait(radio) else { return XCTFail("did not settle") }
        XCTAssertEqual(rate, 16_000)
        XCTAssertGreaterThanOrEqual(seconds, 1.4 + RateSettle.quiet - 0.001,
                                    "the quiet period counts from the last change")
    }

    /// -10868 has causes that are not a flip. A rate that never leaves the
    /// stale one ends the wait at its deadline and the build goes on.
    func testARateThatNeverMovesTimesOutAtTheDeadline() {
        let radio = Radio { _ in 48_000 }
        guard case .timedOut(let rate, let seconds) = wait(radio) else { return XCTFail("settled on the stale rate") }
        XCTAssertEqual(rate, 48_000)
        XCTAssertEqual(seconds, RateSettle.deadline, accuracy: 0.001)
    }

    func testTheWaitIsBoundedByTheWholeStart() {
        XCTAssertLessThan(RateSettle.deadline, SpeechStart.startBudget)
        XCTAssertGreaterThan(RateSettle.deadline, 2.5,
                             "the flip landed 3.5 s from the first start, and the refusal comes 1 to 2 s in")
    }

    /// With nothing to compare against, the rate only has to stand still.
    func testWithNoStaleRateItOnlyHasToHoldStill() {
        let radio = Radio { _ in 24_000 }
        guard case .settled(let rate, _) = wait(radio, from: nil) else { return XCTFail("did not settle") }
        XCTAssertEqual(rate, 24_000)
    }

    func testADeviceWithNoReadableRateIsNotWaitedFor() {
        let radio = Radio { _ in nil }
        XCTAssertEqual(wait(radio), .unreadable)
        XCTAssertEqual(radio.pauses, 0, "no guess, no pause")
    }

    /// A read that fails in the middle of the flip is not a rate.
    func testAMissedReadDoesNotSettleOrReset() {
        let radio = Radio { t in t < 1.0 ? 48_000 : (t < 1.1 ? nil : 24_000) }
        guard case .settled(let rate, _) = wait(radio) else { return XCTFail("did not settle") }
        XCTAssertEqual(rate, 24_000)
    }

    /// A draft closed or reopened during the wait lets the queue go: the
    /// next start is behind it.
    func testASupersededSessionStopsWaiting() {
        let radio = Radio { _ in 48_000 }
        let outcome = wait(radio, superseded: { radio.now >= 0.5 })
        XCTAssertEqual(outcome, .superseded)
        XCTAssertLessThan(radio.now, 0.7)
    }

    // MARK: - The facts the engine decides on

    func testTheRateMovingUnderAnEngineIsFound() {
        let moved = AudioInput.rateMoved(built: (48_000, 1), now: (24_000, 1))
        XCTAssertEqual(moved?.from, 48_000)
        XCTAssertEqual(moved?.to, 24_000)
        XCTAssertNil(AudioInput.rateMoved(built: (24_000, 1), now: (24_000, 1)), "same rate, same engine")
        XCTAssertNil(AudioInput.rateMoved(built: (24_000, 1), now: (24_000, 2)), "a rate is what a flip changes")
    }

    func testAnUnreadableRateIsNotAMove() {
        XCTAssertNil(AudioInput.rateMoved(built: nil, now: (24_000, 1)))
        XCTAssertNil(AudioInput.rateMoved(built: (48_000, 1), now: nil))
        XCTAssertNil(AudioInput.rateMoved(built: (48_000, 1), now: (0, 0)),
                     "a device with no format is gone, not at a new rate")
    }

    func testARefusalIsOwedAWaitOnlyForItsDeviceAndOnlyForAWhile() {
        let at = Date(timeIntervalSince1970: 1_000)
        let refusal: (device: AudioDeviceID, at: Date)? = (7, at)
        XCTAssertTrue(AudioInput.owesSettle(refusal: refusal, device: 7, now: at.addingTimeInterval(2)))
        XCTAssertFalse(AudioInput.owesSettle(refusal: refusal, device: 8, now: at.addingTimeInterval(2)),
                       "another device was not refused")
        XCTAssertFalse(AudioInput.owesSettle(refusal: refusal, device: 7,
                                             now: at.addingTimeInterval(AudioInput.refusalMemory + 1)),
                       "the radio has long since landed")
        XCTAssertFalse(AudioInput.owesSettle(refusal: nil, device: 7, now: at))
        XCTAssertFalse(AudioInput.owesSettle(refusal: refusal, device: nil, now: at))
    }

    func testAStaleStartSaysWhatMoved() {
        let error = AudioInput.StaleRate(from: 48_000, to: 24_000)
        XCTAssertEqual(error.localizedDescription, "the input moved from 48000 Hz to 24000 Hz")
    }
}
