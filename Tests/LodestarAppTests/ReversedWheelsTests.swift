import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What runs for the Reversed wheels setting, and when. Nothing here makes a
/// real tap or opens a real HID manager: the pieces refuse under a test run,
/// and what is asked of them is read off `applied`.
final class ReversedWheelsTests: XCTestCase {
    private let protoarc = "9639:64160:ab12cd34"
    private let logi = "app:com.example.mousetool"

    private func wheels(granted: Bool? = true, trusted: Bool = true) -> ReversedWheels {
        let wheels = ReversedWheels()
        wheels.trusted = { trusted }
        wheels.attached = { [] }
        // What a read off the main thread will say too, so that a late answer
        // agrees with the one the test gave.
        wheels.canListen = { granted ?? false }
        if let granted { wheels.applyPermission(granted) }
        return wheels
    }

    func testNothingTickedAndNoPageIsNothingRunning() {
        let wheels = wheels()
        wheels.configure([:])
        wheels.applyPermission(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: false, tap: .off))
    }

    /// The page open with nothing ticked listens and turns nothing; the tap
    /// that turns exists only for a ticked source.
    func testThePageFindsMiceWithoutAnActiveTap() {
        let wheels = wheels()
        wheels.setDiscovering(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .listen))
        wheels.setDiscovering(false)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: false, tap: .off))
    }

    func testATickedSourceStartsTheTapAndUntickingStopsIt() {
        let wheels = wheels()
        wheels.configure([protoarc: "ProtoArc EM11 NL"])
        wheels.applyPermission(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .turn))
        wheels.configure([:])
        wheels.applyPermission(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: false, tap: .off), "off is off")
    }

    func testWithoutInputMonitoringNothingRunsAndItIsAskedForOnce() {
        let wheels = wheels(granted: nil)
        var asked = 0
        wheels.requestListening = { asked += 1 }
        wheels.configure([protoarc: "ProtoArc EM11 NL"])
        wheels.applyPermission(false)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: false, tap: .off))
        XCTAssertEqual(asked, 0, "not before the page is open: a setting nobody opened is not asked about")
        wheels.setDiscovering(true)
        wheels.applyPermission(false)
        wheels.applyPermission(false)
        wheels.drainForTesting()
        XCTAssertEqual(asked, 1, "once a launch")
        wheels.applyPermission(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .turn))
    }

    func testWithoutAccessibilityNothingIsTurned() {
        let wheels = wheels(trusted: false)
        wheels.configure([protoarc: "ProtoArc EM11 NL"])
        wheels.applyPermission(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .off))
        wheels.setDiscovering(true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .listen))
    }

    /// The permission is read off the main thread and the answer comes back.
    func testThePermissionIsReadOffMainAndApplied() {
        let wheels = wheels(granted: nil)
        var onMain: [Bool] = []
        wheels.canListen = { onMain.append(Thread.isMainThread); return true }
        let changed = expectation(description: "the window is told")
        wheels.changed = { changed.fulfill() }
        wheels.configure([protoarc: "ProtoArc EM11 NL"])
        wait(for: [changed], timeout: 5)
        XCTAssertEqual(onMain.first, false)
        XCTAssertEqual(wheels.listenGranted, true)
        XCTAssertEqual(wheels.applied, WheelPlan(listens: true, tap: .turn))
    }

    // MARK: - What the page lists

    /// A mouse's scroll, attributed by the tap and told to the page.
    private func attribute(_ wheels: ReversedWheels, _ id: String, name: String, at stamp: UInt64 = 9_000_000_000) throws {
        wheels.described(device: id, name: name)
        wheels.tap.hear(device: id, stamp: stamp - 1_000_000)
        _ = wheels.tap.handle(.scrollWheel, try scroll(stamp: stamp))
        wheels.resolveNoticed()
    }

    func testTheListHasWhatIsTickedAndWhatWasAttributedWithWhetherItIsHere() throws {
        let wheels = wheels()
        wheels.attached = { [self.protoarc] }
        wheels.configure([protoarc: "ProtoArc EM11 NL", logi: "Logi Options+"])
        try attribute(wheels, "1133:16466:00ff00ff", name: "Lift")
        let listed = Dictionary(uniqueKeysWithValues: wheels.sources().map { ($0.id, $0) })
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed[protoarc]?.present, true, "ticked, and attached")
        XCTAssertEqual(listed["1133:16466:00ff00ff"]?.name, "Lift")
        XCTAssertEqual(listed["1133:16466:00ff00ff"]?.present, false, "heard, and gone")
        XCTAssertEqual(listed[logi]?.present, false, "not running")
        wheels.heard(app: 911, bundleID: "com.example.mousetool", name: "Logi Options+")
        XCTAssertEqual(wheels.sources().first { $0.id == logi }?.present, true)
    }

    /// A mouse whose wheel is heard but never scrolls on its own, because an
    /// app swallows it, is not listed: it would be a switch that does nothing.
    func testAMouseThatIsOnlyHeardIsNotListed() {
        let wheels = wheels()
        wheels.described(device: protoarc, name: "ProtoArc EM11 NL")
        wheels.tap.hear(device: protoarc, stamp: 9_000_000_000)
        wheels.resolveNoticed()
        XCTAssertEqual(wheels.sources(), [])
    }

    func testAHeardNameWinsOverTheOneTheConfigKept() throws {
        let wheels = wheels()
        wheels.configure([protoarc: "Old name"])
        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL")
        XCTAssertEqual(wheels.sources().map(\.name), ["ProtoArc EM11 NL"])
    }

    func testTheWindowIsToldOnlyWhenAMouseIsFirstListed() throws {
        let wheels = wheels()
        var told = 0
        wheels.changed = { told += 1 }
        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL")
        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL", at: 9_500_000_000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(told, 1)
    }

    // MARK: - A row lights while its wheel turns

    private func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Lit on the first attributed scroll, unlit once the wheel has been
    /// quiet, and never while the Input place is not on screen.
    func testAWheelTurningLightsItsSourceOnlyWhileInputIsOnScreen() throws {
        let wheels = wheels()
        let base = uptime()
        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL", at: base)
        XCTAssertEqual(wheels.lit, [], "Input is not on screen")

        wheels.setDiscovering(true)
        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL", at: base + 1_000_000_000)
        XCTAssertEqual(wheels.lit, [protoarc])
        wheels.settle(now: base + 1_300_000_000)
        XCTAssertEqual(wheels.lit, [protoarc], "quiet for 0.3 s is not quiet enough")
        wheels.settle(now: base + 1_000_000_000 + WheelBurst.quiet + 1)
        XCTAssertEqual(wheels.lit, [])

        try attribute(wheels, protoarc, name: "ProtoArc EM11 NL", at: base + 3_000_000_000)
        XCTAssertEqual(wheels.lit, [protoarc], "the next burst lights it again")
        wheels.setDiscovering(false)
        XCTAssertEqual(wheels.lit, [], "leaving Input puts the light out")
    }

    /// A burst is two draws of the window, one lit and one unlit, however
    /// many scrolls it holds.
    func testABurstDrawsTheWindowTwice() throws {
        let wheels = wheels()
        wheels.setDiscovering(true)
        var drawn = 0
        wheels.changed = { drawn += 1 }
        let base = uptime()
        wheels.described(device: protoarc, name: "ProtoArc EM11 NL")
        for index in 0..<40 {
            let stamp = base + UInt64(index) * 20_000_000
            wheels.tap.hear(device: protoarc, stamp: stamp - 1_000_000)
            _ = wheels.tap.handle(.scrollWheel, try scroll(stamp: stamp))
            wheels.resolveNoticed()
        }
        wheels.settle(now: base + 40 * 20_000_000 + WheelBurst.quiet + 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(drawn, 2)
        XCTAssertEqual(wheels.lit, [])
    }

    /// An app's posted scrolls light its row under its own id.
    func testAnAppsPostedScrollsLightItsRow() throws {
        let wheels = wheels()
        wheels.setDiscovering(true)
        wheels.pidSourceForTesting(911, logi)
        let base = uptime()
        _ = wheels.tap.handle(.scrollWheel, try scroll(pid: 911, stamp: base))
        wheels.resolveNoticed()
        XCTAssertEqual(wheels.lit, [logi])
        wheels.settle(now: base + WheelBurst.quiet + 1)
        XCTAssertEqual(wheels.lit, [])
    }

    // MARK: - The tap hears it

    private func scroll(pid: Int64 = 0, stamp: UInt64) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: 2, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.timestamp = stamp
        return event
    }

    /// The listener's report reaches the tap and the ticked mouse's scroll
    /// is turned, end to end but for the real tap and the real manager.
    func testATickedMiceReportsReachTheTap() throws {
        let wheels = wheels()
        wheels.configure([protoarc: "ProtoArc EM11 NL"])
        wheels.tap.hear(device: protoarc, stamp: 9_000_000_000)
        let event = try scroll(stamp: 9_000_500_000)
        _ = wheels.tap.handle(.scrollWheel, event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -2)
    }

    /// A ticked app's pid is the one it is running as when it posts: the
    /// pids are told to the tap off the callback.
    func testATickedAppsPostedScrollsAreTurned() throws {
        let wheels = wheels()
        wheels.configure([logi: "Logi Options+"])
        let before = try scroll(pid: 911, stamp: 9_000_000_000)
        _ = wheels.tap.handle(.scrollWheel, before)
        XCTAssertEqual(before.getIntegerValueField(.scrollWheelEventDeltaAxis1), 2, "its pid is not known yet")
        wheels.heard(app: 911, bundleID: "com.example.mousetool", name: "Logi Options+")
        let event = try scroll(pid: 911, stamp: 9_100_000_000)
        _ = wheels.tap.handle(.scrollWheel, event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -2)
        let other = try scroll(pid: 912, stamp: 9_200_000_000)
        _ = wheels.tap.handle(.scrollWheel, other)
        XCTAssertEqual(other.getIntegerValueField(.scrollWheelEventDeltaAxis1), 2)
    }

    // MARK: - LaunchServices stays off main

    /// An app's bundle id and the running list are LaunchServices reads, the
    /// class of round trip that held main for seconds under memory pressure
    /// (0.54.6). A launch is looked into only when an app is ticked or the
    /// page is open, and the running list is read on the resolver's queue.
    func testLaunchServicesIsNotAskedOnMainWhenTheFeatureIsNotInUse() throws {
        let file = DesignDriftTests.appSources.appendingPathComponent("ReversedWheels.swift")
        let code = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(code.contains("guard hasAppSource || discovering, let app, let bundle = app.bundleIdentifier"),
                      "the cheap condition comes before the bundle id")
        let scan = try XCTUnwrap(code.range(of: "NSWorkspace.shared.runningApplications"))
        let queued = try XCTUnwrap(code.range(of: "queue.async { [weak self] in\n            var found"))
        XCTAssertTrue(queued.lowerBound < scan.lowerBound, "the running list is read inside the queue's block")
        XCTAssertEqual(code.components(separatedBy: "runningApplications").count, 2, "and only there")
    }
}
