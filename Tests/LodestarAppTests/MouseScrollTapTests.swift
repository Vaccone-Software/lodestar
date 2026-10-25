import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The tap's callback, handed events the way the window server would. No
/// real tap is ever made under test: it would turn the scrolling of the
/// person at the desk.
final class MouseScrollTapTests: XCTestCase {
    private func wheel(dy: Int32, pid: Int64 = 0, phase: Int64 = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                          wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return event
    }

    private func tap(natural: Bool) -> MouseScrollTap {
        let tap = MouseScrollTap(readNatural: { natural })
        tap.drainForTesting()
        return tap
    }

    private func dy(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.scrollWheelEventDeltaAxis1) }

    func testATestRunNeverMakesARealTap() {
        let tap = tap(natural: true)
        tap.configure(.standard)
        XCTAssertFalse(tap.isRunning)
        tap.configure(.system)
        XCTAssertFalse(tap.isRunning)
    }

    /// Standard on a natural Mac: the wheel is turned over, the trackpad
    /// and scroll mode's own scrolls pass as they came.
    func testStandardTurnsOnlyTheWheel() throws {
        let tap = tap(natural: true)
        tap.configure(.standard)
        XCTAssertEqual(tap.naturalScrolling, true)

        let mouse = try wheel(dy: 2)
        _ = tap.handle(.scrollWheel, mouse)
        XCTAssertEqual(dy(mouse), -2, "the wheel")

        let trackpad = try wheel(dy: 2, phase: 2)
        _ = tap.handle(.scrollWheel, trackpad)
        XCTAssertEqual(dy(trackpad), 2, "the trackpad keeps the Mac's setting")

        let own = try wheel(dy: 2, pid: Int64(getpid()))
        _ = tap.handle(.scrollWheel, own)
        XCTAssertEqual(dy(own), 2, "scroll mode")

        let utility = try wheel(dy: 2, pid: 911)
        _ = tap.handle(.scrollWheel, utility)
        XCTAssertEqual(dy(utility), -2, "a mouse utility's smooth scroll")
    }

    /// Natural on a standard Mac turns the wheel; the setting that matches
    /// the Mac and System turn nothing.
    func testTheResultIsWhatTheSettingNames() throws {
        let standardMac = tap(natural: false)
        standardMac.configure(.natural)
        let turned = try wheel(dy: 3)
        _ = standardMac.handle(.scrollWheel, turned)
        XCTAssertEqual(dy(turned), -3)

        standardMac.configure(.standard)
        let left = try wheel(dy: 3)
        _ = standardMac.handle(.scrollWheel, left)
        XCTAssertEqual(dy(left), 3, "already standard")

        standardMac.configure(.system)
        let alone = try wheel(dy: 3)
        _ = standardMac.handle(.scrollWheel, alone)
        XCTAssertEqual(dy(alone), 3)
    }

    /// Before the Mac's direction is known nothing is turned: a guess would
    /// be the wrong way round on every Mac set the other way.
    func testNothingIsTurnedUntilTheMacsDirectionIsKnown() throws {
        let hung = DispatchSemaphore(value: 0)
        let tap = MouseScrollTap(readNatural: { _ = hung.wait(timeout: .now() + 5); return true })
        tap.configure(.standard)
        XCTAssertNil(tap.naturalScrolling)
        let mouse = try wheel(dy: 2)
        _ = tap.handle(.scrollWheel, mouse)
        XCTAssertEqual(dy(mouse), 2)
        hung.signal()
        tap.drainForTesting()
        let later = try wheel(dy: 2)
        _ = tap.handle(.scrollWheel, later)
        XCTAssertEqual(dy(later), -2, "turned once the direction is read")
    }

    /// The Mac's direction is read off the callback's path: a read that
    /// hangs leaves the callback answering from what it had.
    func testAHungReadNeverHoldsAScroll() throws {
        let tap = tap(natural: true)
        tap.configure(.standard)
        let hung = DispatchSemaphore(value: 0)
        tap.readNatural = { _ = hung.wait(timeout: .now() + 5); return false }
        tap.refresh()

        let started = Date()
        let mouse = try wheel(dy: 1)
        _ = tap.handle(.scrollWheel, mouse)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(dy(mouse), -1, "the last direction read still answers")
        hung.signal()
        tap.drainForTesting()
        XCTAssertEqual(tap.naturalScrolling, false, "and the late read lands")
    }
}
