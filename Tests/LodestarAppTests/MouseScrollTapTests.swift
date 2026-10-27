import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The tap's callback, handed events the way the window server would, and
/// the wheel reports the listener would file. No real tap is ever made under
/// test: it would turn the scrolling of the person at the desk.
final class MouseScrollTapTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let now: UInt64 = 50_000_000_000
    private let protoarc = "9639:64160:ab12cd34"
    private let lift = "1133:16466:00ff00ff"

    private func wheel(dy: Int32 = 2, pid: Int64 = 0, phase: Int64 = 0, momentum: Int64 = 0,
                       at stamp: UInt64? = nil) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                          wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.timestamp = stamp ?? now
        return event
    }

    private func dy(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.scrollWheelEventDeltaAxis1) }

    private func tap(devices: Set<String> = [], pids: Set<Int64> = [], noticed: @escaping () -> Void = {}) -> MouseScrollTap {
        let tap = MouseScrollTap(noticed: noticed)
        tap.set(devices: devices, pids: pids)
        return tap
    }

    private func turned(_ tap: MouseScrollTap, _ event: CGEvent) -> Bool {
        let before = dy(event)
        _ = tap.handle(.scrollWheel, event)
        return dy(event) == -before
    }

    func testATestRunNeverMakesARealTap() {
        let tap = tap(devices: [protoarc])
        tap.run(.turn)
        XCTAssertFalse(tap.isRunning)
        tap.run(.listen)
        XCTAssertFalse(tap.isRunning)
        tap.run(.off)
        XCTAssertFalse(tap.isRunning)
    }

    /// A ticked mouse's wheel, vouched for by its own report a millisecond
    /// before: turned. The same wheel unticked, and another mouse's, pass.
    func testATickedMiceWheelIsTurnedAndNothingElseIs() throws {
        let tap = tap(devices: [protoarc])
        tap.hear(device: protoarc, stamp: now - ms)
        XCTAssertTrue(turned(tap, try wheel()))

        let unticked = self.tap(devices: [lift])
        unticked.hear(device: protoarc, stamp: now - ms)
        XCTAssertFalse(turned(unticked, try wheel()), "a mouse not ticked")

        let none = self.tap()
        none.hear(device: protoarc, stamp: now - ms)
        XCTAssertFalse(turned(none, try wheel()), "nothing ticked turns nothing")
    }

    /// The trackpad's scrolls carry phases, and are never turned whatever
    /// else the window holds.
    func testAPhasedScrollIsLeftAlone() throws {
        let tap = tap(devices: [protoarc], pids: [911])
        tap.hear(device: protoarc, stamp: now - ms)
        XCTAssertFalse(turned(tap, try wheel(phase: 2)))
        XCTAssertFalse(turned(tap, try wheel(momentum: 1)))
        XCTAssertFalse(turned(tap, try wheel(pid: 911, phase: 4)))
    }

    func testLodestarsOwnScrollIsLeftAlone() throws {
        let own = Int64(getpid())
        let tap = tap(devices: [protoarc], pids: [own])
        tap.hear(device: protoarc, stamp: now - ms)
        XCTAssertFalse(turned(tap, try wheel(pid: own)))
    }

    /// Two wheels reported inside the window: no telling which, so none.
    func testTwoMiceInTheWindowAreNeverTurned() throws {
        let tap = tap(devices: [protoarc, lift])
        tap.hear(device: protoarc, stamp: now - 2 * ms)
        tap.hear(device: lift, stamp: now - ms)
        XCTAssertFalse(turned(tap, try wheel()))
    }

    func testAReportOutsideTheWindowVouchesForNothing() throws {
        let tap = tap(devices: [protoarc])
        tap.hear(device: protoarc, stamp: now - 80 * ms)
        XCTAssertFalse(turned(tap, try wheel()), "too old")
        let late = self.tap(devices: [protoarc])
        late.hear(device: protoarc, stamp: now + 20 * ms)
        XCTAssertFalse(turned(late, try wheel()), "too new")
    }

    /// A scroll with no wheel beside it and no one who posted it: not a
    /// guess, nothing.
    func testAnUnattributedScrollIsLeftAlone() throws {
        let tap = tap(devices: [protoarc], pids: [911])
        XCTAssertFalse(turned(tap, try wheel()))
    }

    /// A mouse utility's own scroll: turned when its app is ticked, by the
    /// pid it posts from, and never when another is.
    func testAScrollAPostedByATickedAppIsTurned() throws {
        let tap = tap(pids: [911])
        XCTAssertTrue(turned(tap, try wheel(pid: 911)))
        XCTAssertFalse(turned(tap, try wheel(pid: 912)), "an app not ticked")
    }

    /// An event the system has stamped nothing on, as a synthetic one has,
    /// is read as it is: no report is near zero, so nothing vouches.
    func testAnEventWithNoStampIsNotGuessedAt() throws {
        let tap = tap(devices: [protoarc])
        tap.hear(device: protoarc, stamp: now)
        let event = try wheel(at: 0)
        XCTAssertFalse(turned(tap, event))
    }

    /// An app that posted a scroll is told once, by pid, and not again for
    /// the scrolls after it, however many; the callback never grows past its
    /// limit.
    func testAPostingAppIsNoticedOnceAndBounded() throws {
        var told = 0
        let tap = tap(noticed: { told += 1 })
        for _ in 0..<5 { _ = tap.handle(.scrollWheel, try wheel(pid: 911)) }
        XCTAssertEqual(told, 1, "once, not once a scroll")
        XCTAssertEqual(tap.takeNoticed().pids, [911])
        XCTAssertEqual(tap.takeNoticed().pids, [], "taken")
        _ = tap.handle(.scrollWheel, try wheel(pid: 911))
        XCTAssertEqual(told, 1, "and not again after it was taken: the burst is one piece of news")
        for pid in 1000..<1100 { _ = tap.handle(.scrollWheel, try wheel(pid: Int64(pid))) }
        XCTAssertEqual(tap.takeNoticed().pids.count, 16 - 1, "bounded, the first still held")
        XCTAssertEqual(told, 16)
    }

    /// A mouse is noticed when a scroll is attributed to it, not when its
    /// wheel is merely heard: a wheel an app swallows reports and never
    /// scrolls on its own.
    func testAMouseIsNoticedOnlyOnceAScrollIsAttributedToIt() throws {
        var told = 0
        let tap = tap(noticed: { told += 1 })
        tap.hear(device: protoarc, stamp: now - ms)
        XCTAssertEqual(told, 0, "a report alone says nothing")
        XCTAssertEqual(tap.takeNoticed().devices, [])
        for _ in 0..<3 { _ = tap.handle(.scrollWheel, try wheel()) }
        XCTAssertEqual(told, 1, "once, not once a scroll")
        XCTAssertEqual(tap.takeNoticed().devices, [protoarc])
        XCTAssertEqual(tap.takeNoticed().devices, [], "taken")
    }

    /// Every scroll stamps its source, so a page can tell when a burst has
    /// ended; rearming forgets the source, and its next scroll is news.
    func testAnActivityStampFollowsEachScrollAndRearmMakesTheNextNews() throws {
        var told = 0
        let tap = tap(noticed: { told += 1 })
        tap.hear(device: protoarc, stamp: now - ms)
        _ = tap.handle(.scrollWheel, try wheel())
        tap.hear(device: protoarc, stamp: now + 99 * ms)
        _ = tap.handle(.scrollWheel, try wheel(at: now + 100 * ms))
        XCTAssertEqual(tap.activity().devices, [protoarc: now + 100 * ms])
        tap.rearm(devices: [protoarc])
        XCTAssertEqual(tap.activity().devices, [:])
        tap.hear(device: protoarc, stamp: now + 899 * ms)
        _ = tap.handle(.scrollWheel, try wheel(at: now + 900 * ms))
        XCTAssertEqual(told, 2)
        tap.rearm()
        XCTAssertEqual(tap.activity().devices, [:], "none named is every one")
    }

    /// The callback never grows its lists: they stand at their full size.
    func testTheListsAreMadeAtTheirFullSize() throws {
        let file = DesignDriftTests.appSources.appendingPathComponent("MouseScrollTap.swift")
        let code = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(code.contains("posted.reserveCapacity(Self.noticedLimit)"))
        XCTAssertTrue(code.contains("attributed.reserveCapacity(Self.noticedLimit)"))
    }

    /// A posted scroll, a phased one and one nothing vouches for notice no mouse.
    func testOnlyAnAttributedDeviceScrollNoticesAMouse() throws {
        let tap = tap()
        tap.hear(device: protoarc, stamp: now - ms)
        _ = tap.handle(.scrollWheel, try wheel(pid: 911))
        _ = tap.handle(.scrollWheel, try wheel(phase: 2))
        _ = tap.handle(.scrollWheel, try wheel(at: now + 500 * ms))
        XCTAssertEqual(tap.takeNoticed().devices, [])
    }

    /// The system turning a slow tap off is answered, and the event passes.
    func testADisabledTapIsAnsweredWithoutHoldingTheEvent() throws {
        let tap = tap()
        let event = try wheel()
        XCTAssertNotNil(tap.handle(.tapDisabledByTimeout, event))
        XCTAssertNotNil(tap.handle(.tapDisabledByUserInput, event))
        XCTAssertNotNil(tap.handle(.keyDown, event), "other events pass")
        XCTAssertEqual(dy(event), 2)
    }

    /// The callback's file is the one thing every scroll on the Mac waits
    /// on: it never asks who an app is, never logs, never touches the main
    /// thread and never waits on a queue. The apps' pids are kept current
    /// elsewhere.
    func testTheCallbacksFileNeverAsksLaunchServicesOrLogsOrWaits() throws {
        let file = DesignDriftTests.appSources.appendingPathComponent("MouseScrollTap.swift")
        let code = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
        for forbidden in ["NSRunningApplication", "NSWorkspace", "Log.", "DispatchQueue", ".sync", "runningApplications",
                          "bundleIdentifier", "localizedName", "Thread.sleep", "usleep", "semaphore.wait"] {
            XCTAssertFalse(code.contains(forbidden), "MouseScrollTap.swift uses \(forbidden); the callback must not")
        }
    }
}
