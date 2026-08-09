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

    func testAddAtCapReplaces() {
        for id in 1...11 { model.addWindow(CGWindowID(id * 10)) }
        layout.replace(with: 10, on: 1)
        for id in 2...10 { layout.add(CGWindowID(id * 10), on: 1) }
        XCTAssertEqual(layout.members(on: 1).count, 10)
        layout.add(110, on: 1)
        XCTAssertEqual(layout.members(on: 1), [110], "the eleventh replaces")
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

    func testResolutionChangeIsANoop() {
        model.addWindow(10)
        layout.replace(with: 10, on: 1)
        layout.reconcileDisplays() // same displays, nothing to do
        XCTAssertEqual(layout.members(on: 1), [10])
        XCTAssertFalse(parking.isParked(10))
    }
}
