import XCTest
@testable import LodestarCore

/// The layout world without a window server: a fake model holds windows,
/// a recording mover applies frames back into it, and a scriptable display
/// oracle plugs and unplugs monitors.
private final class FakeWindows: WindowQuerying {
    var windows: [CGWindowID: WindowModel.Window] = [:]
    var focusedWindow: WindowModel.Window?

    func window(_ id: CGWindowID) -> WindowModel.Window? { windows[id] }
    func refreshFrame(_ id: CGWindowID) {}

    func addWindow(_ id: CGWindowID, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) {
        windows[id] = WindowModel.Window(
            id: id, element: AXUIElementCreateApplication(1), pid: 1,
            appName: "App\(id)", bundleID: "app.\(id)", title: "W\(id)",
            frame: frame, isMinimized: false, isAlive: true,
            lastFocused: nil, deadAt: nil
        )
    }

    func kill(_ id: CGWindowID) {
        windows[id]?.isAlive = false
    }
}

private final class FakeMover: WindowMoving {
    let model: FakeWindows
    var frameSets: [(id: CGWindowID, frame: CGRect)] = []
    var raised: [CGWindowID] = []

    init(model: FakeWindows) { self.model = model }

    func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
        frameSets.append((window.id, frame))
        model.windows[window.id]?.frame = frame
        return true
    }

    func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
        model.windows[window.id]?.frame.origin = point
        return true
    }

    func raise(_ window: WindowModel.Window) { raised.append(window.id) }
}

private final class FakeDisplays {
    var infos: [Displays.DisplayInfo]
    var uuids: [CGDirectDisplayID: String]

    init(_ displays: [(CGDirectDisplayID, CGRect, String)]) {
        infos = displays.map { Displays.DisplayInfo(id: $0.0, bounds: $0.1) }
        uuids = Dictionary(uniqueKeysWithValues: displays.map { ($0.0, $0.2) })
    }

    var oracle: DisplayOracle {
        DisplayOracle(
            ordered: { self.infos },
            visibleFrame: { rect in
                self.infos.first { $0.bounds.intersects(rect) }?.bounds
                    ?? self.infos.first?.bounds ?? .zero
            },
            displayContaining: { rect in self.infos.first { $0.bounds.intersects(rect) } },
            uuid: { self.uuids[$0] }
        )
    }
}

final class LayoutControllerTests: XCTestCase {
    private var model: FakeWindows!
    private var mover: FakeMover!
    private var displays: FakeDisplays!
    private var parking: ParkingLot!
    private var layout: LayoutController!

    private let main = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let external = CGRect(x: 1600, y: 0, width: 1920, height: 1080)

    override func setUp() {
        model = FakeWindows()
        mover = FakeMover(model: model)
        displays = FakeDisplays([(1, main, "uuid-main"), (2, external, "uuid-ext")])
        parking = ParkingLot(mover: mover, bounds: { self.displays.infos.map(\.bounds) })
        layout = LayoutController(model: model, parking: parking,
                                  mover: mover, displays: displays.oracle)
        layout.reconcileDisplays() // learn identities, as boot does
    }

    // MARK: - Membership

    func testReplaceParksPreviousMembers() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.replace(with: 20, on: 1)

        XCTAssertEqual(layout.members(on: 1), [20])
        XCTAssertTrue(parking.isParked(10), "the displaced member parks")
        XCTAssertEqual(model.windows[10]!.frame.origin.x, main.maxX - 1, "slivered at the corner")
        XCTAssertEqual(model.windows[20]!.frame, main, "the summon owns the display")
    }

    func testAddTilesEqually() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)

        XCTAssertEqual(layout.members(on: 1), [10, 20])
        XCTAssertEqual(model.windows[10]!.frame, CGRect(x: 0, y: 0, width: 800, height: 900))
        XCTAssertEqual(model.windows[20]!.frame, CGRect(x: 800, y: 0, width: 800, height: 900))
        XCTAssertFalse(parking.isParked(10), "beside means both stay")
    }

    func testAddExistingMemberJustRetiles() {
        model.addWindow(10)
        layout.replace(with: 10, on: 1)
        layout.add(10, on: 1)
        XCTAssertEqual(layout.members(on: 1), [10])
    }

    /// Nine is the cap because the digits are the addresses, and the
    /// tenth beside-summon is refused with the world untouched — not
    /// absorbed by a takeover, which is what "beside" must never mean.
    func testAddAtCapRefuses() {
        for id in 1...10 { model.addWindow(CGWindowID(id * 10)) }
        layout.replace(with: 10, on: 1)
        for id in 2...9 {
            XCTAssertTrue(layout.add(CGWindowID(id * 10), on: 1))
        }
        XCTAssertEqual(layout.members(on: 1).count, 9)
        let before = layout.members(on: 1)
        XCTAssertFalse(layout.add(100, on: 1), "the tenth is prevented")
        XCTAssertEqual(layout.members(on: 1), before,
                       "a refusal leaves the layout exactly as it was")
        // And the ninth digit still reaches the ninth (last) window.
        XCTAssertEqual(layout.windowID(atDigit: 9, on: 1), before.last)
    }

    func testRemoveHealsSurvivors() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        layout.remove(10)
        XCTAssertEqual(layout.members(on: 1), [20])
        XCTAssertEqual(model.windows[20]!.frame, main, "the survivor takes the display")
    }

    func testMemberBelongsToOneDisplay() {
        model.addWindow(10)
        layout.replace(with: 10, on: 1)
        layout.replace(with: 10, on: 2)
        XCTAssertEqual(layout.members(on: 1), [])
        XCTAssertEqual(layout.members(on: 2), [10])
    }

    func testFlipOrientationRetilesVertically() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        layout.flipOrientation(on: 1)
        XCTAssertEqual(layout.orientation(on: 1), .vertical)
        XCTAssertEqual(model.windows[10]!.frame, CGRect(x: 0, y: 0, width: 1600, height: 450))
        XCTAssertEqual(model.windows[20]!.frame, CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    func testDeadMembersDroppedOnRetile() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        model.kill(10)
        layout.retile(on: 1)
        XCTAssertEqual(layout.members(on: 1), [20])
    }

    // MARK: - Undo

    func testUndoRestoresMembershipAndParking() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.replace(with: 20, on: 1)
        XCTAssertTrue(parking.isParked(10))

        XCTAssertEqual(layout.undo(), 1)
        XCTAssertEqual(layout.members(on: 1), [10])
        XCTAssertFalse(parking.isParked(10), "undo reclaims the parked member")
        XCTAssertTrue(parking.isParked(20), "and parks the displacer")

        XCTAssertEqual(layout.redo(), 1)
        XCTAssertEqual(layout.members(on: 1), [20])
    }

    func testUndoOnEmptyTimelineIsNil() {
        XCTAssertNil(layout.undo())
        XCTAssertNil(layout.redo())
    }

    /// The bug this shape exists to end: a cross-display move undone used
    /// to restore only the destination, so the moved window — a member of
    /// neither snapshot — slid into the sliver instead of going home.
    func testUndoOfACrossDisplayMoveReturnsTheWindowHome() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.replace(with: 20, on: 2)
        layout.replace(with: 10, on: 2) // the move: 10 leaves display 1 for 2

        XCTAssertEqual(layout.undo(), 1, "focus follows the window home")
        XCTAssertEqual(layout.members(on: 1), [10], "back on its source display")
        XCTAssertEqual(layout.members(on: 2), [20], "the displacer returns too")
        XCTAssertFalse(parking.isParked(10), "home, never the sliver")

        XCTAssertEqual(layout.redo(), 1)
        XCTAssertEqual(layout.members(on: 2), [10], "redo re-makes the move whole")
        XCTAssertEqual(layout.members(on: 1), [], "one step, both displays")
        XCTAssertTrue(parking.isParked(20))
    }

    // MARK: - Order and digits

    func testOrderedByPositionAndDigits() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        XCTAssertEqual(layout.orderedByPosition(on: 1), [10, 20])
        XCTAssertEqual(layout.windowID(atDigit: 1, on: 1), 10)
        XCTAssertEqual(layout.windowID(atDigit: 9, on: 1), 20)
        XCTAssertNil(layout.windowID(atDigit: 3, on: 1))
    }

    func testMoveToDigitReorders() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        XCTAssertTrue(layout.move(20, toDigit: 1, on: 1))
        XCTAssertEqual(model.windows[20]!.frame.minX, 0, "moved to the left slot")
        XCTAssertEqual(model.windows[10]!.frame.minX, 800)
    }

    func testAdoptGroupsSpansDisplays() {
        model.addWindow(10)
        model.addWindow(20)
        model.addWindow(30)
        layout.adoptGroups([1: [10, 20], 2: [30]], orientation: .vertical)
        XCTAssertEqual(layout.members(on: 1), [10, 20])
        XCTAssertEqual(layout.members(on: 2), [30])
        XCTAssertEqual(layout.orientation(on: 1), .vertical)
        XCTAssertEqual(model.windows[30]!.frame, external)
    }

    // MARK: - Docking

    func testDepartureParksAndRememberss() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 2)
        layout.add(20, on: 2)

        displays.infos.removeAll { $0.id == 2 }
        layout.reconcileDisplays()

        XCTAssertEqual(layout.members(on: 2), [])
        XCTAssertTrue(parking.isParked(10))
        XCTAssertTrue(parking.isParked(20))
    }

    /// Undo must not reach back onto a display that has gone.
    ///
    /// The snapshot outlived the layout, so undo restored it, claimed each
    /// window's parking spot — deleting the only record of where they were
    /// — and then moved nothing, because retile returns early for a
    /// display that is not connected. The windows stayed in the 1px
    /// parking sliver, unreachable, and focus followed them there.
    func testUndoCannotReachADepartedDisplay() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 2)
        layout.add(20, on: 2)

        displays.infos.removeAll { $0.id == 2 }
        layout.reconcileDisplays()
        XCTAssertTrue(parking.isParked(10))
        XCTAssertTrue(parking.isParked(20))

        XCTAssertNil(layout.undo(), "the departed display's history went with it")
        XCTAssertTrue(parking.isParked(10), "the parking record must survive")
        XCTAssertTrue(parking.isParked(20))
        XCTAssertEqual(layout.members(on: 2), [])
    }

    func testReturnRestoresTheArrangement() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 2)
        layout.add(20, on: 2)
        layout.flipOrientation(on: 2)

        displays.infos.removeAll { $0.id == 2 }
        layout.reconcileDisplays()

        // The same monitor returns under a NEW CGDirectDisplayID — the
        // hardware UUID is the identity that matters.
        displays.infos.append(Displays.DisplayInfo(id: 7, bounds: external))
        displays.uuids[7] = "uuid-ext"
        layout.reconcileDisplays()

        XCTAssertEqual(layout.members(on: 7), [10, 20])
        XCTAssertEqual(layout.orientation(on: 7), .vertical, "orientation returns too")
        XCTAssertFalse(parking.isParked(10))
        XCTAssertFalse(parking.isParked(20))
    }

    func testReturnSkipsMembersTheUserReplaced() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 2)
        layout.add(20, on: 2)

        displays.infos.removeAll { $0.id == 2 }
        layout.reconcileDisplays()

        // While undocked, the user summoned 10 onto the laptop.
        layout.replace(with: 10, on: 1)

        displays.infos.append(Displays.DisplayInfo(id: 2, bounds: external))
        layout.reconcileDisplays()

        XCTAssertEqual(layout.members(on: 1), [10], "the user's placement wins")
        XCTAssertEqual(layout.members(on: 2), [20], "only the untouched member returns")
    }

    func testReturnWithNothingAliveRestoresNothing() {
        model.addWindow(10)
        layout.replace(with: 10, on: 2)

        displays.infos.removeAll { $0.id == 2 }
        layout.reconcileDisplays()
        model.kill(10)

        displays.infos.append(Displays.DisplayInfo(id: 2, bounds: external))
        layout.reconcileDisplays()
        XCTAssertEqual(layout.members(on: 2), [])
    }

    func testUnknownDisplayArrivalIsQuiet() {
        displays.infos.append(Displays.DisplayInfo(id: 9, bounds: CGRect(x: -1000, y: 0, width: 1000, height: 800)))
        displays.uuids[9] = "uuid-new"
        layout.reconcileDisplays()
        XCTAssertEqual(layout.members(on: 9), [])
    }

    /// Reconciling an unchanged world must not disturb anything.
    func testUnchangedDisplaysAreLeftAlone() {
        model.addWindow(10)
        layout.replace(with: 10, on: 1)
        mover.frameSets.removeAll()
        layout.reconcileDisplays()
        XCTAssertEqual(layout.members(on: 1), [10])
        XCTAssertFalse(parking.isParked(10))
        XCTAssertTrue(mover.frameSets.isEmpty, "nothing changed, so nothing should move")
    }

    /// A display that stays but changes shape has to be re-cut. The old
    /// reconciliation branched on display identity alone, so a resolution
    /// switch, an arrangement drag, or the Dock appearing left the windows
    /// tiled to a rectangle that no longer existed — and this test used to
    /// pass while asserting nothing about it.
    func testReshapedDisplayIsRetiled() {
        model.addWindow(10)
        model.addWindow(20)
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
        mover.frameSets.removeAll()

        displays.infos = [Displays.DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
                          Displays.DisplayInfo(id: 2, bounds: external)]
        layout.reconcileDisplays()

        XCTAssertEqual(layout.members(on: 1), [10, 20], "membership survives a reshape")
        XCTAssertFalse(parking.isParked(10))
        XCTAssertFalse(mover.frameSets.isEmpty, "the smaller display must be re-cut")
        for set in mover.frameSets {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 800, height: 600).contains(set.frame),
                          "window \(set.id) landed outside the new bounds: \(set.frame)")
        }
    }

    func testACoalescedStepUndoesTheWholePhrase() {
        model.addWindow(10)
        model.addWindow(20)
        model.addWindow(30)
        layout.replace(with: 30, on: 1)
        layout.replace(with: 10, on: 1)
        layout.coalesceNextStep = true
        layout.add(20, on: 1)
        XCTAssertEqual(layout.members(on: 1), [10, 20])
        XCTAssertFalse(layout.coalesceNextStep, "consumed by the record it joined")
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [30], "one undo restores the stage before the phrase")
        XCTAssertFalse(parking.isParked(30))
    }

    func testAStrayCoalesceFlagCannotFoldTwoGestures() {
        model.addWindow(10)
        model.addWindow(20)
        layout.coalesceNextStep = true
        layout.replace(with: 10, on: 1)
        XCTAssertFalse(layout.coalesceNextStep, "with nothing to join, the flag is spent and the step stands alone")
        layout.replace(with: 20, on: 1)
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10])
    }
}
