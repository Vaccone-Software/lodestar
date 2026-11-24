import XCTest
@testable import LodestarCore

/// The walk: due at thirty minutes of unbroken work, given at the next
/// stopping point, twice at most in a stretch, and a two minute break
/// starts it over.
final class StandCueTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Input every half minute from `from` to `to`, as working looks.
    func work(_ cue: inout StandCue, from: Double, to: Double) {
        var m = from
        while m <= to { cue.input(at: at(m)); m += 0.5 }
    }

    func testNothingIsDueBeforeThirtyMinutes() {
        var cue = StandCue()
        work(&cue, from: 0, to: 29)
        XCTAssertNil(cue.boundary(.appSwitch, at: at(29)))
    }

    func testTheFirstStoppingPointAfterThirtyMinutesEarnsTheCue() {
        var cue = StandCue()
        work(&cue, from: 0, to: 32)
        let given = cue.boundary(.appSwitch, at: at(32))
        XCTAssertEqual(given, StandCue.Cue(minutes: 30, share: 0.5, via: .appSwitch, index: 1))
        XCTAssertNil(cue.boundary(.draft, at: at(33)), "one cue for the half hour")
    }

    func testOnceMoreAtSixtyThenSilence() {
        var cue = StandCue()
        work(&cue, from: 0, to: 31)
        XCTAssertNotNil(cue.boundary(.appSwitch, at: at(31)))
        work(&cue, from: 31.5, to: 61)
        let second = cue.boundary(.draft, at: at(61))
        XCTAssertEqual(second?.minutes, 60)
        XCTAssertEqual(second?.share, 1, "the mark is whole at the hour")
        work(&cue, from: 61.5, to: 120)
        XCTAssertNil(cue.boundary(.appSwitch, at: at(120)), "no third cue in a stretch")
        XCTAssertNil(cue.check(at: at(130)))
    }

    func testATwoMinuteBreakStartsTheStretchOver() {
        var cue = StandCue()
        work(&cue, from: 0, to: 31)
        XCTAssertNotNil(cue.boundary(.appSwitch, at: at(31)))
        // A walk: two and a half minutes with no input.
        XCTAssertTrue(cue.input(at: at(33.5)))
        work(&cue, from: 34, to: 50)
        XCTAssertNil(cue.boundary(.appSwitch, at: at(50)), "the new stretch is sixteen minutes old")
        work(&cue, from: 50.5, to: 64)
        XCTAssertEqual(cue.boundary(.appSwitch, at: at(64))?.minutes, 30, "the count starts again at thirty")
    }

    func testAShortPauseIsNotABreak() {
        var cue = StandCue()
        work(&cue, from: 0, to: 20)
        XCTAssertFalse(cue.input(at: at(21.5)), "ninety seconds is a pause, not a walk")
        work(&cue, from: 22, to: 31)
        XCTAssertNotNil(cue.boundary(.appSwitch, at: at(31)))
    }

    func testWithNoStoppingPointATypingPauseWillDoAfterFifteenMinutes() {
        var cue = StandCue()
        work(&cue, from: 0, to: 44)
        XCTAssertNil(cue.check(at: at(44.1)), "still within the wait for a stopping point")
        // Typing pauses for twenty seconds at forty five minutes.
        cue.input(at: at(45))
        XCTAssertNil(cue.check(at: at(45.1)), "the hand has not paused yet")
        let given = cue.check(at: at(45.4))
        XCTAssertEqual(given?.via, .pause)
        XCTAssertEqual(given?.minutes, 30)
    }

    func testAStretchThatHasEndedIsNotCued() {
        var cue = StandCue()
        work(&cue, from: 0, to: 35)
        XCTAssertNil(cue.boundary(.appSwitch, at: at(40)), "five minutes away is already a break")
    }

    func testTheWords() {
        XCTAssertEqual(StandCue.sentence(minutes: 30), "Thirty minutes without a break")
        XCTAssertEqual(StandCue.sentence(minutes: 60), "Sixty minutes without a break")
        XCTAssertEqual(StandCue.instruction, "Walk for two minutes")
        XCTAssertFalse(StandCue.sentence(minutes: 30).hasSuffix("."))
    }
}
