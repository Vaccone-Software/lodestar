import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The tripwire (OffScreenGuard) finds a window where it is told a person's
/// display is, and the seam keeps the suite's windows from being there.
///
/// The "real display" in these is the stand-in, passed in, so that proving
/// the guard fires does not put a window on a real screen: the guard's own
/// reading of `NSScreen` is the one thing not under test here, and the
/// whole suite runs under it.
final class OffScreenGuardTests: XCTestCase {
    private func show(at origin: NSPoint, title: String = "") -> NSWindow {
        let window = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 200, height: 100)),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        return window
    }

    func testAWindowOnADisplayIsNamedWithItsClassTitleAndFrame() {
        let window = show(at: NSPoint(x: Stage.screen.minX + 100, y: Stage.screen.minY + 100), title: "Sentinel")
        let found = OffScreenGuard.findings(windows: [window], displays: [Stage.screen],
                                            primaryHeight: Stage.screen.maxY)
        XCTAssertEqual(found.count, 1)
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.hasPrefix("NSPanel \"Sentinel\" is at (\(Int(window.frame.minX)), \(Int(window.frame.minY)), 200 by 100), on a real display"),
                      message)
    }

    func testAWindowOffTheDisplaysIsNotFound() {
        let window = show(at: NSPoint(x: Stage.screen.maxX + 5_000, y: Stage.screen.minY))
        XCTAssertEqual(OffScreenGuard.findings(windows: [window], displays: [Stage.screen],
                                               primaryHeight: Stage.screen.maxY), [])
    }

    func testAHiddenWindowOnADisplayIsNotFound() {
        let window = show(at: NSPoint(x: Stage.screen.minX + 100, y: Stage.screen.minY + 100))
        window.orderOut(nil)
        XCTAssertEqual(OffScreenGuard.findings(windows: [window], displays: [Stage.screen],
                                               primaryHeight: Stage.screen.maxY), [])
    }

    /// A layer the window server has on screen for this process that is not
    /// in `NSApp.windows` is found too, by its Quartz bounds; another process's
    /// is not, and neither is one an `NSWindow` already accounts for.
    func testALayerTheServerListsIsFoundWithoutAnNSWindow() {
        let primaryHeight: CGFloat = 1000
        func entry(_ pid: Int32, number: Int, at quartz: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number, kCGWindowLayer as String: 25,
             kCGWindowName as String: "Item", kCGWindowBounds as String: quartz.dictionaryRepresentation]
        }
        let display = NSRect(x: 0, y: 0, width: 1500, height: 1000)
        let mine = entry(getpid(), number: 901, at: CGRect(x: 100, y: 50, width: 200, height: 20))
        let found = OffScreenGuard.findings(windows: [], displays: [display], primaryHeight: primaryHeight,
                                            server: [mine, entry(getpid() &+ 1, number: 902, at: CGRect(x: 100, y: 50, width: 200, height: 20)),
                                                     entry(getpid(), number: 903, at: CGRect(x: 9_000, y: 50, width: 200, height: 20))])
        XCTAssertEqual(found.map(\.window), ["window 901 \"Item\" on layer 25 (not an NSWindow)"])
        XCTAssertEqual(found.first?.frame, NSRect(x: 100, y: 930, width: 200, height: 20), "flipped against the primary's height")
    }

    func testTheSuiteIsLaidOutOnTheStandInDisplay() {
        XCTAssertEqual(Screens.all.map(\.frame), [Stage.screen], "under a test run there is one display, and it is off every real one")
        XCTAssertEqual(ActivePolicy.presentationFrame, Stage.screen, "a surface with no override is laid out there too")
        XCTAssertEqual(Screens.primaryHeight, Stage.screen.maxY)
        let real = OffScreenGuard.realDisplays.frames
        XCTAssertFalse(real.contains { $0.intersects(Stage.screen) }, "the stand-in is on none of this Mac's displays")
    }
}
