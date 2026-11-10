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

    /// The log's case: a headset already at 16 kHz refused a start, and the
    /// wait for its rate to leave 16 kHz ran its whole 3.5 s every time (4
    /// of 4 cycles, `input rate did not settle hz=16000`), because no flip
    /// was coming. A rate that is a hands-free one and has not moved owes no
    /// wait at all.
    func testARefusalAtAPhoneRateThatHasNotMovedOwesNoWait() {
        for rate in [16_000.0, 24_000.0] {
            let radio = Radio { _ in rate }
            XCTAssertEqual(wait(radio, from: rate), .alreadyThere(rate: rate), "\(rate)")
            XCTAssertEqual(radio.pauses, 0, "no pause: nothing is waited for at \(rate)")
            XCTAssertEqual(radio.now, 0, accuracy: 0.0001)
        }
    }

    /// The same wait is still owed where a flip can come: a radio on its
    /// music rate, and one that moved since the engine was built.
    func testAFlipThatCanStillComeIsStillWaitedFor() {
        XCTAssertTrue(RateSettle.flipComing(from: 48_000, rate: 48_000), "music rate, hands-free still to come")
        XCTAssertTrue(RateSettle.flipComing(from: 48_000, rate: 24_000), "it moved, and its quiet period is owed")
        XCTAssertTrue(RateSettle.flipComing(from: 16_000, rate: 48_000), "it went back to music")
        XCTAssertTrue(RateSettle.flipComing(from: nil, rate: 16_000), "nothing is known of the engine's rate")
        XCTAssertTrue(RateSettle.flipComing(from: 16_000, rate: nil), "nor of the device's")
        XCTAssertFalse(RateSettle.flipComing(from: 16_000, rate: 16_000))
        XCTAssertFalse(RateSettle.flipComing(from: 24_000, rate: 24_000))
        XCTAssertFalse(RateSettle.flipComing(from: 8_000, rate: 8_000))
        let radio = Radio { _ in 48_000 }
        guard case .timedOut = wait(radio, from: 48_000) else { return XCTFail("a music rate that never moves is waited out") }
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

    // MARK: - One owner for the retry budget

    private let refusedAt = Date(timeIntervalSince1970: 1_000)

    /// What a remembered refusal makes the next start owe: the whole wait
    /// where a flip can come, nothing where the rate is a phone one that
    /// has not moved, and nothing for another device or a refusal long past.
    func testWhatARefusalOwes() {
        let soon = refusedAt.addingTimeInterval(2)
        func owed(_ built: Double?, now rate: Double?, device: AudioDeviceID = 7, at: Date? = nil) -> TimeInterval {
            AudioInput.settleOwed(refusal: (7, built, refusedAt), device: device, rate: rate, now: at ?? soon)
        }
        XCTAssertEqual(owed(48_000, now: 48_000), RateSettle.deadline)
        XCTAssertEqual(owed(48_000, now: 24_000), RateSettle.deadline, "moved: its quiet period, inside the same bound")
        XCTAssertEqual(owed(16_000, now: 16_000), 0, "the log's case: built 16 kHz, now 16 kHz")
        XCTAssertEqual(owed(16_000, now: 16_000, at: refusedAt.addingTimeInterval(AudioInput.refusalMemory - 1)), 0)
        XCTAssertEqual(owed(48_000, now: 48_000, device: 8), 0, "another device was not refused")
        XCTAssertEqual(owed(48_000, now: 48_000, at: refusedAt.addingTimeInterval(AudioInput.refusalMemory + 1)), 0)
        XCTAssertEqual(AudioInput.settleOwed(refusal: nil, device: 7, rate: 48_000, now: soon), 0)
    }

    /// The second attempt of a start began with 0.9 s of a 5.65 s budget
    /// owing a settle of up to 3.5 s, and was abandoned at the deadline
    /// every time. It is not begun now: nothing starts on the queue that
    /// cannot finish, and the draft asks again with a whole budget.
    func testAnAttemptIsNotBegunWithLessBudgetThanItsSettleNeeds() {
        let began = Date(timeIntervalSince1970: 5_000)
        // The log's arithmetic: attempt 1 ends at 4.1 s, the outer settle is 0.65 s.
        let secondAttempt = began.addingTimeInterval(4.1 + SpeechStart.settleSeconds)
        let until = began.addingTimeInterval(SpeechStart.startBudget)
        let remaining = until.timeIntervalSince(secondAttempt)
        XCTAssertEqual(remaining, 0.9, accuracy: 0.01, "what attempt 2 had in the log")
        XCTAssertFalse(AudioInput.mayBegin(owing: RateSettle.deadline, until: until, now: secondAttempt),
                       "a settle of up to 3.5 s does not fit in 0.9 s")
        XCTAssertTrue(AudioInput.mayBegin(owing: 0, until: until, now: secondAttempt),
                      "an attempt that owes nothing is begun with what is left")
        XCTAssertFalse(AudioInput.mayBegin(owing: 0, until: until, now: until.addingTimeInterval(-SpeechStart.minimumStart)),
                       "and not with less than a start needs")
        XCTAssertTrue(AudioInput.mayBegin(owing: RateSettle.deadline, until: nil, now: secondAttempt),
                      "a restart with no budget is not limited")
    }

    /// The decision as the engine makes it, for the two ways the log's
    /// second attempt can stand: owed a flip's wait with no time, or owed
    /// nothing because no flip is coming.
    func testASecondAttemptAtAPhoneRateIsBegunAndOneOwingAFlipIsNot() {
        let began = Date(timeIntervalSince1970: 5_000)
        let now = began.addingTimeInterval(4.1 + SpeechStart.settleSeconds)
        let until = began.addingTimeInterval(SpeechStart.startBudget)
        let refusalNow = now.addingTimeInterval(-1)
        func begins(built: Double, rate: Double) -> Bool {
            let owed = AudioInput.settleOwed(refusal: (7, built, refusalNow), device: 7, rate: rate, now: now)
            return AudioInput.mayBegin(owing: owed, until: until, now: now)
        }
        XCTAssertTrue(begins(built: 16_000, rate: 16_000), "built 16 kHz, now 16 kHz: no wait owed, so it has the room")
        XCTAssertFalse(begins(built: 48_000, rate: 48_000), "a flip still to wait for does not fit")
    }

    /// A session's first start has the room for one settle and a start
    /// after it; only a later attempt can be short.
    func testAWholeBudgetFitsOneSettleAndAStart() {
        XCTAssertTrue(SpeechStart.canBegin(remaining: SpeechStart.startBudget, owing: RateSettle.deadline))
        XCTAssertFalse(SpeechStart.canBegin(remaining: SpeechStart.startBudget - SpeechStart.deadline, owing: RateSettle.deadline))
    }

    func testAStaleStartSaysWhatMoved() {
        let error = AudioInput.StaleRate(from: 48_000, to: 24_000)
        XCTAssertEqual(error.localizedDescription, "the input moved from 48000 Hz to 24000 Hz")
    }

    /// The start loop logs an attempt's failure by its localized words, so
    /// an attempt that was not begun must say why there, not as a bare code.
    func testAnAttemptNotBegunSaysWhatDidNotFit() {
        let error: Error = AudioInput.NotBegun(owed: 3.5, remaining: 0.9)
        XCTAssertEqual(error.localizedDescription,
                       "the wait the radio is owed, up to 3.5 s, does not fit in the 0.9 s left")
    }
}
