import CoreGraphics
import Darwin
import XCTest
@testable import lodestar

/// The event's own stamp, not the callback's clock: a hold measured from
/// stamps is immune to whatever held the main thread in between.
final class EventTimeTests: XCTestCase {
    private func nowNanos() -> Double {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom)
    }

    private func event(agoSeconds: Double) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        e.timestamp = CGEventTimestamp(nowNanos() - agoSeconds * 1e9)
        return e
    }

    func testStampedEventIsPlacedAtItsOwnMoment() {
        let date = EventTime.date(of: event(agoSeconds: 0.25))!
        XCTAssertEqual(Date().timeIntervalSince(date), 0.25, accuracy: 0.02)
    }

    func testTwoStampsDifferByExactlyTheirGap() {
        let down = EventTime.date(of: event(agoSeconds: 0.180))!
        let up = EventTime.date(of: event(agoSeconds: 0.080))!
        XCTAssertEqual(up.timeIntervalSince(down), 0.100, accuracy: 0.001)
    }

    func testUnstampedEventHasNoTime() {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        XCTAssertEqual(e.timestamp, 0)
        XCTAssertNil(EventTime.date(of: e))
    }

    func testStampFromAnotherEpochIsNotTrusted() {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        e.timestamp = 12345
        XCTAssertNil(EventTime.date(of: e))
    }
}

/// A hold is the difference of the two events' stamps, taken on the clock
/// they were made on, so a wall-clock adjustment between press and
/// release (NTP, a time zone, a person setting the clock) never lands in
/// it. Dates stay for the record.
final class EventTimeIntervalTests: XCTestCase {
    private func nowNanos() -> Double {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom)
    }

    func testTheIntervalBetweenStampsIgnoresTheWallClock() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // The clock was set back an hour between the press and the release.
        let end = start.addingTimeInterval(-3600)
        let hold = EventTime.interval(from: (start, 5_000_000_000), to: (end, 5_094_000_000))
        XCTAssertEqual(hold, 0.094, accuracy: 1e-12)
    }

    func testWithoutBothStampsTheDatesAreUsed() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let end = start.addingTimeInterval(0.120)
        // A date this far from its epoch resolves to about 0.1 µs.
        XCTAssertEqual(EventTime.interval(from: (start, nil), to: (end, nil)), 0.120, accuracy: 1e-6)
        XCTAssertEqual(EventTime.interval(from: (start, 5e9), to: (end, nil)), 0.120, accuracy: 1e-6,
                       "one stamp alone is no interval")
    }

    func testAStampIsReadAsNanosecondsOnThisMachine() {
        let now = nowNanos()
        let stamp = CGEventTimestamp(now - 0.5e9)
        XCTAssertEqual(EventTime.monotonic(stamp: stamp)!, Double(stamp), accuracy: 1)
    }

    /// A stamp in raw mach ticks (a 1/1 timebase reads the same; a scaled
    /// one does not) is converted to nanoseconds on the way in.
    func testAStampInTicksIsConvertedToNanoseconds() throws {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        guard info.numer != info.denom else { throw XCTSkip("a 1/1 timebase reads ticks as nanoseconds") }
        let ticks = mach_absolute_time() - 1_000
        let nanos = try XCTUnwrap(EventTime.monotonic(stamp: CGEventTimestamp(ticks)))
        XCTAssertEqual(nanos, Double(ticks) * Double(info.numer) / Double(info.denom), accuracy: 1)
    }

    func testNoStampOrAStampFromNowhereIsNotTrusted() {
        XCTAssertNil(EventTime.monotonic(stamp: 0))
        XCTAssertNil(EventTime.monotonic(stamp: 12345))
    }

    /// Through the real tap: the hold recorded is the stamps' difference
    /// exactly. Two dates each placed against a fresh read of the clock
    /// differ from it by the microseconds between the reads; the stamps do
    /// not.
    func testTheTapTimesAHoldFromTheEventsStamps() {
        let stage = Stage()
        var holds: [Double] = []
        stage.engine.onHumanPress = { if let hold = $0.hold { holds.append(hold) } }
        let down = CGEventTimestamp(nowNanos() - 0.300e9)
        stage.pressStamped("j", down: down, up: down + 87_654_321)
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(holds.first ?? 0, 0.087654321, accuracy: 1e-9)
    }

    /// The harness's events carry no stamp; their holds stay on its clock.
    func testUnstampedPressesKeepTheVirtualClock() {
        let stage = Stage()
        var holds: [Double] = []
        stage.engine.onHumanPress = { if let hold = $0.hold { holds.append(hold) } }
        stage.pressHeld("j", for: 0.250)
        XCTAssertEqual(holds.first ?? 0, 0.250, accuracy: 1e-9)
    }
}
