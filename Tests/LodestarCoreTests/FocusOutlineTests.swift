import XCTest
@testable import LodestarCore

/// The focus outline is drawn only where Lodestar is used as meant: the
/// focused window is one of a layout of two or more, still where the layout
/// left it, and no other app's window lies over it.
final class FocusOutlineTests: XCTestCase {
    private let left = CGRect(x: 0, y: 30, width: 800, height: 870)
    private let right = CGRect(x: 800, y: 30, width: 800, height: 870)

    private func window(_ id: CGWindowID, _ frame: CGRect, pid: pid_t = 1,
                        minimized: Bool = false, alive: Bool = true) -> WindowModel.Window {
        WindowModel.Window(id: id, element: AXUIElementCreateApplication(pid), pid: pid,
                           appName: "App\(id)", bundleID: "app.\(id)", title: "W\(id)",
                           frame: frame, isMinimized: minimized, isAlive: alive,
                           lastFocused: nil, deadAt: nil)
    }

    private func record(_ id: CGWindowID, _ bounds: CGRect, pid: pid_t, layer: Int = 0) -> CGWindowRecord {
        CGWindowRecord(id: id, pid: pid, ownerName: "App\(id)", bounds: bounds, layer: layer)
    }

    /// The two members on screen, the focused one in front.
    private var stack: [CGWindowRecord] { [record(10, left, pid: 1), record(20, right, pid: 2)] }

    func testAPlacedMemberOfALayoutOfTwoIsOutlined() {
        let frame = FocusOutline.frame(focused: window(10, left), members: [10, 20], placed: left, stack: stack)
        XCTAssertEqual(frame, left)
    }

    func testAWindowAloneOnItsDisplayIsNotOutlined() {
        XCTAssertNil(FocusOutline.frame(focused: window(10, left), members: [10], placed: left, stack: stack),
                     "one window has nothing to be told apart from")
    }

    func testAWindowNoLayoutPlacedIsNotOutlined() {
        XCTAssertNil(FocusOutline.frame(focused: window(30, left), members: [10, 20], placed: left, stack: stack),
                     "opened by hand, not summoned beside")
        XCTAssertNil(FocusOutline.frame(focused: window(10, left), members: [10, 20], placed: nil, stack: stack),
                     "mid-retile: not placed yet")
        XCTAssertNil(FocusOutline.frame(focused: nil, members: [10, 20], placed: left, stack: stack))
    }

    func testAMovedOrResizedWindowIsNotOutlined() {
        let dragged = left.offsetBy(dx: 40, dy: 0)
        XCTAssertNil(FocusOutline.frame(focused: window(10, dragged), members: [10, 20], placed: left, stack: stack))
        let resized = CGRect(origin: left.origin, size: CGSize(width: 700, height: 870))
        XCTAssertNil(FocusOutline.frame(focused: window(10, resized), members: [10, 20], placed: left, stack: stack))
    }

    func testAccessibilityRoundingIsStillWhereItWasLeft() {
        let jitter = left.offsetBy(dx: 1, dy: -1)
        XCTAssertEqual(FocusOutline.frame(focused: window(10, jitter), members: [10, 20], placed: left, stack: stack),
                       jitter)
    }

    func testAMinimizedOrDeadWindowIsNotOutlined() {
        XCTAssertNil(FocusOutline.frame(focused: window(10, left, minimized: true),
                                        members: [10, 20], placed: left, stack: stack))
        XCTAssertNil(FocusOutline.frame(focused: window(10, left, alive: false),
                                        members: [10, 20], placed: left, stack: stack))
    }

    func testAWindowOffScreenIsNotOutlined() {
        XCTAssertNil(FocusOutline.frame(focused: window(10, left), members: [10, 20], placed: left,
                                        stack: [record(20, right, pid: 2)]),
                     "another Space, a hidden app, a full-screen app in front")
    }

    func testAnotherAppsWindowOverItHidesTheOutline() {
        let stranger = record(99, CGRect(x: 200, y: 200, width: 400, height: 300), pid: 9)
        XCTAssertNil(FocusOutline.frame(focused: window(10, left), members: [10, 20], placed: left,
                                        stack: [stranger] + stack))
    }

    func testWhatMayStandOverItKeepsTheOutline() {
        let own = record(11, CGRect(x: 100, y: 800, width: 380, height: 22), pid: 1)
        let palette = record(98, CGRect(x: 200, y: 200, width: 400, height: 300), pid: 9, layer: 3)
        let behind = record(97, CGRect(x: 200, y: 200, width: 400, height: 300), pid: 9)
        let touching = record(96, right, pid: 9)
        XCTAssertEqual(FocusOutline.frame(focused: window(10, left), members: [10, 20], placed: left,
                                          stack: [own, palette, touching, record(10, left, pid: 1), behind]),
                       left, "its own bubble, a palette above the normal layer, a neighbour that only touches, and what is behind it")
    }
}
