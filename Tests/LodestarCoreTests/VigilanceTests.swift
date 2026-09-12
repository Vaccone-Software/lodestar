import XCTest
@testable import LodestarCore

/// What running on does to the hands inside a bout.
///
/// The load-bearing test here is the one that plants a confound and
/// demands nothing come out: bouts differ from each other for every
/// reason under the sun, and an estimator that pools across them would
/// mostly report which bouts happen to run long. Recovering a planted
/// slope is the easy half.
final class VigilanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// One window of a bout: its position, and the counts a drift is
    /// read off. Keys and backspaces are chosen so the correction rate
    /// comes out exactly as asked for.
    private func pulse(bout: Int, index: Int, elapsed: Double,
                       correction: Double = 0.05, pauseShare: Double = 0.1,
                       hold: Double = 0.09) -> ObservationEvent {
        var event = ObservationEvent(
            t: start.addingTimeInterval(Double(bout) * 86_400 + elapsed), kind: .pulse)
        event.boutIndex = index
        event.boutSeconds = elapsed
        event.activeMinutes = 15
        let keys = 10_000
        event.keys = keys
        event.backspaces = Int((Double(keys) * correction).rounded())
        let gaps = 1_000
        event.ikTailN = Int((Double(gaps) * pauseShare).rounded())
        event.ikN = gaps - (event.ikTailN ?? 0)
        event.holdN = 500
        event.holdSum = hold * 500
        return event
    }

    func testRecoversAPlantedWithinBoutSlope() throws {
        // Ten bouts, four windows each, corrections rising two points an
        // hour inside every one of them.
        var events: [ObservationEvent] = []
        for bout in 0..<10 {
            for index in 0..<4 {
                let elapsed = Double(index) * 900
                events.append(pulse(bout: bout, index: index, elapsed: elapsed,
                                    correction: 0.05 + 0.02 * (elapsed / 3600)))
            }
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(report.bouts, 10)
        let slope = try XCTUnwrap(report.correctionRate.perHour)
        XCTAssertEqual(slope, 0.02, accuracy: 0.002, "two points an hour, as planted")
        XCTAssertTrue(report.correctionRate.isDistinguishable)
    }

    /// The confound. Every bout is perfectly flat inside itself, but the
    /// long bouts are the high-correction ones. A pooled fit would call
    /// that a decrement; centring each bout on its own mean must find
    /// nothing, because nothing happened inside any bout.
    func testABetweenBoutConfoundProducesNoSlope() throws {
        var events: [ObservationEvent] = []
        for bout in 0..<12 {
            // Long bouts run eight windows, short ones two — and the
            // long ones sit at twice the correction rate throughout.
            let long = bout % 2 == 0
            let windows = long ? 8 : 2
            let rate = long ? 0.10 : 0.05
            for index in 0..<windows {
                events.append(pulse(bout: bout, index: index,
                                    elapsed: Double(index) * 900, correction: rate))
            }
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(report.bouts, 12)
        let slope = try XCTUnwrap(report.correctionRate.perHour)
        XCTAssertEqual(slope, 0, accuracy: 1e-6,
                       "the difference is between bouts, and between bouts is not a decrement")
        XCTAssertFalse(report.correctionRate.isDistinguishable)
        // The bins still show the raw picture, which is the honest thing
        // for them to show — they are descriptive and the slope is the
        // claim.
        XCTAssertGreaterThan(report.correctionRate.binCounts[0], 0)
    }

    func testASingleWindowBoutCannotVote() throws {
        var events: [ObservationEvent] = []
        for bout in 0..<20 {
            events.append(pulse(bout: bout, index: 0, elapsed: 0,
                                correction: Double(bout) * 0.01))
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(report.bouts, 20)
        XCTAssertEqual(report.correctionRate.fitted, 0)
        XCTAssertNil(report.correctionRate.perHour,
                     "a bout with one window has no inside to measure")
        XCTAssertFalse(report.correctionRate.isDistinguishable)
    }

    func testNoiseWithoutASlopeIsNotDistinguishable() throws {
        var events: [ObservationEvent] = []
        var seed = 1.0
        for bout in 0..<10 {
            for index in 0..<4 {
                // A fixed wobble, no trend.
                seed = (seed * 7.0).truncatingRemainder(dividingBy: 11.0)
                events.append(pulse(bout: bout, index: index, elapsed: Double(index) * 900,
                                    correction: 0.05 + (seed - 5) * 0.002))
            }
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertFalse(report.correctionRate.isDistinguishable,
                       "wobble is not a finding, and the error has to say so")
    }

    func testPausesAndHoldRideTheSameFit() throws {
        var events: [ObservationEvent] = []
        for bout in 0..<10 {
            for index in 0..<4 {
                let elapsed = Double(index) * 900
                events.append(pulse(bout: bout, index: index, elapsed: elapsed,
                                    pauseShare: 0.10 + 0.04 * (elapsed / 3600),
                                    hold: 0.09 + 0.01 * (elapsed / 3600)))
            }
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(try XCTUnwrap(report.pauseShare.perHour), 0.04, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(report.holdTime.perHour), 0.01, accuracy: 0.002)
    }

    /// Pulses written before bouts existed carry no position. They are
    /// skipped rather than guessed at: a bout inferred from timestamps
    /// would be a different measurement wearing the same name.
    func testPulsesWithoutABoutPositionAreSkipped() {
        var event = ObservationEvent(t: start, kind: .pulse)
        event.keys = 100
        event.activeMinutes = 15
        XCTAssertNil(Vigilance.report(events: [event], days: 365,
                                      now: start.addingTimeInterval(86_400)))
    }

    func testBoutLengthsAreReported() throws {
        var events: [ObservationEvent] = []
        for index in 0..<4 {
            events.append(pulse(bout: 0, index: index, elapsed: Double(index) * 900))
        }
        let report = try XCTUnwrap(Vigilance.report(events: events, days: 365,
                                                    now: start.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(report.bouts, 1)
        // Three windows in, plus that window's own fifteen minutes.
        XCTAssertEqual(try XCTUnwrap(report.longestBoutMinutes), 60, accuracy: 0.1)
    }
}
