import XCTest
@testable import LodestarCore

final class PresenceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testAClosedDeviceHoldsNothing() {
        XCTAssertFalse(Presence.microphoneHolds(openSince: nil, now: now))
    }

    func testAnOpenDeviceHolds() {
        XCTAssertTrue(Presence.microphoneHolds(openSince: now, now: now))
        XCTAssertTrue(Presence.microphoneHolds(openSince: now.addingTimeInterval(-3600),
                                               now: now))
    }

    /// The whole point: a device that never closes must not silence the
    /// coach for the rest of the week.
    func testPastTheCeilingItStopsCounting() {
        let stuck = now.addingTimeInterval(-Presence.microphoneCeiling - 1)
        XCTAssertFalse(Presence.microphoneHolds(openSince: stuck, now: now))
    }

    func testTheCeilingIsInclusive() {
        let exactly = now.addingTimeInterval(-Presence.microphoneCeiling)
        XCTAssertTrue(Presence.microphoneHolds(openSince: exactly, now: now))
    }

    /// Long enough that a real call is never cut off by it.
    func testTheCeilingOutlastsAnyPlausibleCall() {
        XCTAssertGreaterThanOrEqual(Presence.microphoneCeiling, 3 * 3600)
    }
}
