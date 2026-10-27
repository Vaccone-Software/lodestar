import CoreGraphics
import XCTest
@testable import LodestarCore

/// Whose a scroll is, and what is done to the ones the person ticked. The
/// decision is a pure function of what the tap's callback can read, so every
/// way it can go wrong is reached here without a tap.
final class MouseScrollTests: XCTestCase {
    private let own: Int64 = 4242
    private let now: UInt64 = 10_000_000_000
    private let ms: UInt64 = 1_000_000
    private let protoarc = "9639:64160:ab12cd34"
    private let logitech = "1133:16466:00ff00ff"

    private func attribution(phase: Int64 = 0, momentum: Int64 = 0, pid: Int64 = 0, at stamp: UInt64? = nil,
                             _ reports: MouseScroll.Reports) -> MouseScroll.Attribution {
        MouseScroll.attribution(scrollPhase: phase, momentumPhase: momentum, postingPID: pid, ownPID: own,
                                stamp: stamp ?? now, reports: reports)
    }

    private func reports(_ heard: [(String, UInt64)]) -> MouseScroll.Reports {
        var reports = MouseScroll.Reports()
        for (device, stamp) in heard { reports.add(device: device, stamp: stamp) }
        return reports
    }

    // MARK: - The decision

    /// The measured case: the wheel's report stamped within a millisecond of
    /// the scroll it became.
    func testOneDeviceInTheWindowIsTheSource() {
        let heard = reports([(protoarc, now - ms)])
        XCTAssertEqual(attribution(heard), .device(protoarc))
        XCTAssertTrue(MouseScroll.turns(.device(protoarc), devices: [protoarc], pids: []))
        XCTAssertFalse(MouseScroll.turns(.device(protoarc), devices: [logitech], pids: []), "ticked is another mouse")
        XCTAssertFalse(MouseScroll.turns(.device(protoarc), devices: [], pids: []), "nothing ticked turns nothing")
    }

    /// Fifty milliseconds before the scroll to five after: a report just
    /// outside either edge vouches for nothing.
    func testTheWindowIsFiftyMillisecondsBeforeToFiveAfter() {
        XCTAssertEqual(attribution(reports([(protoarc, now - 50 * ms)])), .device(protoarc))
        XCTAssertEqual(attribution(reports([(protoarc, now + 5 * ms)])), .device(protoarc))
        XCTAssertEqual(attribution(reports([(protoarc, now - 50 * ms - 1)])), .unknown)
        XCTAssertEqual(attribution(reports([(protoarc, now + 5 * ms + 1)])), .unknown)
        XCTAssertEqual(attribution(MouseScroll.Reports()), .unknown, "no report at all")
    }

    /// Two wheels inside one window cannot be told apart, so neither is
    /// turned, whatever is ticked. One device reporting twice is still one.
    func testTwoDevicesInTheWindowAreNeverTurned() {
        let both = reports([(protoarc, now - 2 * ms), (logitech, now - ms)])
        XCTAssertEqual(attribution(both), .ambiguous)
        XCTAssertFalse(MouseScroll.turns(.ambiguous, devices: [protoarc, logitech], pids: []))
        XCTAssertEqual(attribution(reports([(protoarc, now - 9 * ms), (protoarc, now - ms)])), .device(protoarc))
        XCTAssertEqual(attribution(reports([(protoarc, now - 80 * ms), (logitech, now - ms)])), .device(logitech),
                       "a report out of the window is not a second device")
    }

    /// A touch surface phases its scrolls and a wheel never does: a phase or
    /// a momentum phase rules the scroll out even beside a ticked wheel's report.
    func testAPhasedScrollIsNeverTurned() {
        let heard = reports([(protoarc, now - ms)])
        XCTAssertEqual(attribution(phase: 2, heard), .touch)
        XCTAssertEqual(attribution(momentum: 1, heard), .touch)
        XCTAssertEqual(attribution(phase: 2, pid: 911, heard), .touch)
        XCTAssertFalse(MouseScroll.turns(.touch, devices: [protoarc], pids: [911]))
    }

    /// Scroll mode's own scrolls already have the direction their key names.
    func testLodestarsOwnScrollIsNeverTurned() {
        let heard = reports([(protoarc, now - ms)])
        XCTAssertEqual(attribution(pid: own, heard), .own)
        XCTAssertFalse(MouseScroll.turns(.own, devices: [protoarc], pids: [own]), "not even if the pid were ticked")
    }

    /// A mouse utility swallows the wheel and posts its own scrolls: the
    /// process that posted one is the source, once no wheel reported near it.
    func testAScrollAnotherAppPostedIsThatApps() {
        XCTAssertEqual(attribution(pid: 911, MouseScroll.Reports()), .posted(pid: 911))
        XCTAssertTrue(MouseScroll.turns(.posted(pid: 911), devices: [], pids: [911]))
        XCTAssertFalse(MouseScroll.turns(.posted(pid: 911), devices: [protoarc], pids: [912]), "an app not ticked")
        XCTAssertFalse(MouseScroll.turns(.posted(pid: 911), devices: [protoarc], pids: []))
        XCTAssertEqual(attribution(pid: 911, reports([(protoarc, now - ms)])), .device(protoarc),
                       "a wheel that reported beside it is the closer witness")
    }

    /// Nothing posted it and no wheel reported: a scroll from a surface the
    /// listener cannot hear, or from a mouse that was not listened to. Never guessed.
    func testAScrollNothingVouchesForIsNeverTurned() {
        XCTAssertEqual(attribution(MouseScroll.Reports()), .unknown)
        XCTAssertFalse(MouseScroll.turns(.unknown, devices: [protoarc], pids: [911]))
    }

    /// Only the vertical wheel is a wheel report: a sideways pan is not one,
    /// so it never vouches for a scroll.
    func testOnlyTheVerticalWheelIsAWheelReport() {
        XCTAssertTrue(MouseScroll.isVerticalWheel(page: 0x01, usage: 0x38))
        XCTAssertFalse(MouseScroll.isVerticalWheel(page: 0x0C, usage: 0x238), "AC Pan")
        XCTAssertFalse(MouseScroll.isVerticalWheel(page: 0x01, usage: 0x30), "pointer X")
        XCTAssertFalse(MouseScroll.isVerticalWheel(page: 0x0C, usage: 0x38))
    }

    /// The ring forgets its oldest report when it is full, in place.
    func testTheRingKeepsTheNewestReports() {
        var ring = MouseScroll.Reports()
        ring.add(device: logitech, stamp: now - ms)
        for index in 0..<MouseScroll.Reports.capacity {
            ring.add(device: protoarc, stamp: now - 20 * ms + UInt64(index))
        }
        XCTAssertEqual(attribution(ring), .device(protoarc), "the first report was overwritten")
    }

    // MARK: - The reversal

    private func wheel(line: Int32 = 3, horizontal: Int32 = 5) throws -> CGEvent {
        try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                              wheel1: line, wheel2: horizontal, wheel3: 0))
    }

    /// Vertical only, in every field an app might read: line, fixed point and point.
    func testReverseVerticalTurnsEveryVerticalFieldAndNoHorizontalOne() throws {
        let event = try wheel()
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.5)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 7)
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        XCTAssertEqual(line, 3)
        let sideways = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let sidewaysPoints = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        MouseScroll.reverseVertical(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -line)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -2.5, accuracy: 0.001)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -7)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), sideways, "a sideways scroll is left as it came")
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), sidewaysPoints)
    }

    /// Turned twice, the scroll is as it came.
    func testReversingTwiceIsTheIdentity() throws {
        let event = try wheel(line: -4, horizontal: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -3.25)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -9)
        MouseScroll.reverseVertical(event)
        MouseScroll.reverseVertical(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -4)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -3.25, accuracy: 0.001)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -9)
    }

    // MARK: - Sources and the plan

    func testASourceIsAMouseByItsRosterIdOrAnAppByItsBundleId() {
        XCTAssertTrue(WheelSource.isValid("9639:64160:ab12cd34"))
        XCTAssertTrue(WheelSource.isValid("0:0:00000000"))
        XCTAssertTrue(WheelSource.isValid("app:com.logi.cp-dev-mgr"))
        XCTAssertEqual(WheelSource.bundleID(of: "app:com.logi.cp-dev-mgr"), "com.logi.cp-dev-mgr")
        XCTAssertEqual(WheelSource.app(bundleID: "com.logi.cp-dev-mgr"), "app:com.logi.cp-dev-mgr")
        XCTAssertNil(WheelSource.bundleID(of: "9639:64160:ab12cd34"))
        for bad in ["", "app:", "ProtoArc EM11 NL", "9639:64160", "9639:64160:xyz", "a:1:ab12cd34", "1:2:ab12cd3",
                    "1:2:ab12cd34:ff", ":2:ab12cd34"] {
            XCTAssertFalse(WheelSource.isValid(bad), bad)
        }
    }

    /// Off is off: with nothing ticked and no page open, nothing runs, and
    /// no active tap exists for anything but a ticked source.
    func testNothingRunsUntilSomethingIsTickedOrThePageIsOpen() {
        func plan(_ ticked: Bool, _ page: Bool, im: Bool = true, ax: Bool = true) -> WheelPlan {
            WheelPlan(ticked: ticked, discovering: page, inputMonitoring: im, accessibility: ax)
        }
        XCTAssertEqual(plan(false, false), WheelPlan(listens: false, tap: .off))
        XCTAssertEqual(plan(false, true), WheelPlan(listens: true, tap: .listen), "finding mice turns nothing")
        XCTAssertEqual(plan(true, false), WheelPlan(listens: true, tap: .turn))
        XCTAssertEqual(plan(true, true), WheelPlan(listens: true, tap: .turn))
        XCTAssertEqual(plan(true, false, ax: false), WheelPlan(listens: true, tap: .off), "no tap without Accessibility")
        XCTAssertEqual(plan(true, true, ax: false), WheelPlan(listens: true, tap: .listen))
    }

    /// Without Input Monitoring nothing is heard, so nothing is run or turned.
    func testWithoutInputMonitoringNothingRuns() {
        for ticked in [false, true] {
            for page in [false, true] {
                XCTAssertEqual(WheelPlan(ticked: ticked, discovering: page, inputMonitoring: false, accessibility: true),
                               WheelPlan(listens: false, tap: .off))
            }
        }
    }
}
