import XCTest
@testable import LodestarCore

/// A quarter hour of real typing, written out: the new shape columns
/// ride on every pulse forever, so what one costs on disk is a fact the
/// suite should state rather than a thing anybody guesses at.
final class PulseSizeProbe: XCTestCase {
    func testAFullPulseStaysSmall() throws {
        var pulse = HealthPulse()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var t = start
        // Fifteen minutes at a working pace, with the pauses a real
        // quarter hour has in it.
        for i in 0..<2_400 {
            t = t.addingTimeInterval(i % 97 == 0 ? 6.0 : 0.16 + Double(i % 7) * 0.01)
            _ = pulse.key(at: t, backspace: i % 13 == 0)
            _ = pulse.hold(0.07 + Double(i % 9) * 0.004, at: t.addingTimeInterval(0.05))
        }
        let event = try XCTUnwrap(pulse.flush(now: t.addingTimeInterval(1)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(event).count
        XCTAssertGreaterThan(event.holdN ?? 0, 2_000)
        XCTAssertGreaterThan(event.ikTailN ?? 0, 20, "the pauses a real quarter hour has in it")
        // Measured at 499 bytes when this was written. The bound is
        // loose enough not to be a tripwire on a formatting change and
        // tight enough to catch a column that forgot to trim itself.
        XCTAssertLessThan(bytes, 1_200,
                          "one pulse, shape and all, stays about half a kilobyte")
    }
}
