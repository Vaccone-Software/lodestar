import XCTest
@testable import LodestarCore

/// Sliver parking, and the three ways it used to strand a window
/// somewhere the user could not get it back from.
final class ParkingTests: XCTestCase {
    private final class Mover: WindowMoving {
        var positions: [(id: CGWindowID, point: CGPoint)] = []
        var frames: [(id: CGWindowID, frame: CGRect)] = []

        func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
            frames.append((window.id, frame))
            return true
        }

        func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
            positions.append((window.id, point))
            return true
        }

        func raise(_ window: WindowModel.Window) {}
    }

    private let main = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let external = CGRect(x: 1600, y: 0, width: 1920, height: 1080)

    private func window(_ id: CGWindowID, frame: CGRect) -> WindowModel.Window {
        WindowModel.Window(id: id, element: AXUIElementCreateApplication(1), pid: 1,
                           appName: "Test", bundleID: "com.test", title: "",
                           frame: frame, isMinimized: false, isAlive: true,
                           lastFocused: nil, deadAt: nil)
    }

    // MARK: - No display to park onto

    /// Around sleep and display changes there is briefly no display at
    /// all. The union of an empty list is `CGRect.null`, whose corner is
    /// infinite — AX accepts the move, and the lot then recorded a park
    /// that had not happened, so the window could never be restored.
    func testParkWithNoDisplaysRefusesInsteadOfMovingToInfinity() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [] })
        let w = window(10, frame: CGRect(x: 100, y: 100, width: 400, height: 300))

        XCTAssertFalse(lot.park(w))
        XCTAssertFalse(lot.isParked(10), "a park that did not happen must not be recorded")
        XCTAssertTrue(mover.positions.isEmpty, "nothing should have been moved")
    }

    /// A window whose frame matches no display still parks — onto a real
    /// display, never onto the union corner, which in an L-shaped
    /// arrangement can lie on no screen at all (FINDINGS §2).
    func testParkFallsBackToARealDisplayNotTheUnion() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [self.main, self.external] })
        let stray = window(10, frame: CGRect(x: 9000, y: 9000, width: 400, height: 300))

        XCTAssertTrue(lot.park(stray))
        let point = try? XCTUnwrap(mover.positions.first?.point)
        XCTAssertTrue(main.contains(CGPoint(x: point?.x ?? -1, y: main.midY))
                        || external.contains(CGPoint(x: point?.x ?? -1, y: external.midY)),
                      "parked at \(String(describing: point)), which is on no display")
    }

    // MARK: - Restoring into a world that changed

    func testUnparkRestoresTheRememberedFrameWhenItStillFits() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [self.main] })
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let w = window(10, frame: frame)

        XCTAssertTrue(lot.park(w))
        XCTAssertTrue(lot.unpark(w))
        XCTAssertEqual(mover.frames.first?.frame, frame)
        XCTAssertFalse(lot.isParked(10))
    }

    /// The remembered frame can name a monitor that has since been
    /// unplugged. Replaying it verbatim let AppKit clamp the window to a
    /// screen edge — which is where the user then had to find it with the
    /// mouse, since nothing else reaches an unparked window.
    func testUnparkPullsAFrameFromADepartedDisplayBackOnScreen() {
        let mover = Mover()
        var screens = [main, external]
        let lot = ParkingLot(mover: mover, bounds: { screens })
        let onExternal = window(10, frame: CGRect(x: 2000, y: 200, width: 600, height: 400))

        XCTAssertTrue(lot.park(onExternal))
        screens = [main] // the second monitor goes away
        XCTAssertTrue(lot.unpark(onExternal))

        let restored = try? XCTUnwrap(mover.frames.first?.frame)
        XCTAssertNotNil(restored)
        XCTAssertTrue(main.contains(restored!), "restored to \(restored!), off every live display")
    }

    /// A window the user deliberately straddled across two monitors must
    /// come back straddling them. Clamping it into the first display that
    /// happened to intersect — which is the main one, since that is the
    /// order the display list arrives in — teleported it hundreds of
    /// points from where they left it, with nothing unplugged.
    func testUnparkLeavesAWindowStraddlingTwoDisplaysWhereItWas() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [self.main, self.external] })
        let straddling = CGRect(x: 1400, y: 200, width: 800, height: 500)
        let w = window(10, frame: straddling)

        XCTAssertTrue(lot.park(w))
        XCTAssertTrue(lot.unpark(w))
        XCTAssertEqual(mover.frames.first?.frame, straddling,
                       "a frame that still reaches a live display is the user's own arrangement")
    }

    /// A small window is not a degenerate one.
    func testUnparkDoesNotEnlargeASmallButRealWindow() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [self.main] })
        let small = CGRect(x: 40, y: 40, width: 200, height: 120)
        let w = window(10, frame: small)

        XCTAssertTrue(lot.park(w))
        XCTAssertTrue(lot.unpark(w))
        XCTAssertEqual(mover.frames.first?.frame, small, "200x120 is a palette, not a sliver")
    }

    /// A frame saved while the window was already a sliver is not worth
    /// restoring literally.
    func testUnparkGivesADegenerateFrameAUsableSize() {
        let mover = Mover()
        let lot = ParkingLot(mover: mover, bounds: { [self.main] })
        let sliver = window(10, frame: CGRect(x: 1599, y: 870, width: 1, height: 30))

        XCTAssertTrue(lot.park(sliver))
        XCTAssertTrue(lot.unpark(sliver))

        let restored = try? XCTUnwrap(mover.frames.first?.frame)
        XCTAssertNotNil(restored)
        XCTAssertGreaterThanOrEqual(restored!.width, 320)
        XCTAssertGreaterThanOrEqual(restored!.height, 240)
        XCTAssertTrue(main.contains(restored!))
    }
}
