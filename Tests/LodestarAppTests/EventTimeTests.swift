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
