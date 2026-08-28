import XCTest
@testable import LodestarCore

/// The sweep's jurisdiction: only what this session was once asked to
/// move may be moved unasked. Everything else in these tests is the
/// boundary holding.
final class SweepTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func candidate(_ id: CGWindowID, frame: CGRect? = nil,
                           alive: Bool = true, minimized: Bool = false)
        -> Sweep.Candidate {
        Sweep.Candidate(id: id,
                        frame: frame ?? CGRect(x: 100, y: 100, width: 800, height: 600),
                        isAlive: alive, isMinimized: minimized)
    }

    func testOnlyClaimedStraysAreSwept() {
        let swept = Sweep.windows(
            claimed: [10, 20], summoned: 99, members: [], parked: [],
            display: display,
            among: [candidate(10), candidate(20), candidate(30)])
        XCTAssertEqual(swept, [10, 20],
                       "a window macOS placed stays exactly where its app put it")
    }

    func testTheSummonedWindowIsNeverItsOwnStray() {
        let swept = Sweep.windows(
            claimed: [10], summoned: 10, members: [], parked: [],
            display: display, among: [candidate(10)])
        XCTAssertEqual(swept, [])
    }

    func testMembersParkedMinimizedDeadAndElsewhereAreLeftAlone() {
        let offDisplay = CGRect(x: 5000, y: 0, width: 800, height: 600)
        let swept = Sweep.windows(
            claimed: [1, 2, 3, 4, 5, 6], summoned: 99,
            members: [1], parked: [2], display: display,
            among: [candidate(1),                       // an arrangement
                    candidate(2),                       // already away
                    candidate(3, minimized: true),      // already hidden
                    candidate(4, alive: false),         // gone
                    candidate(5, frame: offDisplay),    // someone else's stage
                    candidate(6)])                      // the one honest stray
        XCTAssertEqual(swept, [6])
    }

    // MARK: - Through the layout, with its undo

    private var model: SweepFakeWindows!
    private var parking: ParkingLot!
    private var layout: LayoutController!

    private func makeWorld() {
        model = SweepFakeWindows()
        let mover = SweepFakeMover(model: model)
        let oracle = DisplayOracle(
            ordered: { [Displays.DisplayInfo(id: 1, bounds: self.display)] },
            visibleFrame: { _ in self.display },
            displayContaining: { _ in Displays.DisplayInfo(id: 1, bounds: self.display) },
            uuid: { _ in "uuid" })
        parking = ParkingLot(mover: mover, bounds: { [self.display] })
        layout = LayoutController(model: model, parking: parking,
                                  mover: mover, displays: oracle)
    }

    func testSweepRidesTheSummonsOwnUndoStep() {
        makeWorld()
        model.addWindow(10)
        model.addWindow(20)
        let home = model.windows[20]!.frame

        layout.replace(with: 10, on: 1, sweeping: [20])
        XCTAssertTrue(parking.isParked(20), "the stray parks with the summon")

        layout.undo()
        XCTAssertFalse(parking.isParked(20), "one undo restores the whole stage")
        XCTAssertEqual(model.windows[20]?.frame, home,
                       "a swept window comes back exactly where it stood")

        layout.redo()
        XCTAssertTrue(parking.isParked(20), "redo parks it again")
        XCTAssertEqual(layout.members(on: 1), [10])
    }

    func testSweepNeverParksTheSummonedWindow() {
        makeWorld()
        model.addWindow(10)
        layout.replace(with: 10, on: 1, sweeping: [10])
        XCTAssertFalse(parking.isParked(10))
        XCTAssertEqual(layout.members(on: 1), [10])
    }
}

// Minimal fakes local to this suite; the layout tests' own live in their
// file as private types.
private final class SweepFakeWindows: WindowQuerying {
    var windows: [CGWindowID: WindowModel.Window] = [:]
    var focusedWindow: WindowModel.Window?
    func window(_ id: CGWindowID) -> WindowModel.Window? { windows[id] }
    func refreshFrame(_ id: CGWindowID) {}
    func addWindow(_ id: CGWindowID,
                   frame: CGRect = CGRect(x: 50, y: 50, width: 800, height: 600)) {
        windows[id] = WindowModel.Window(
            id: id, element: AXUIElementCreateApplication(1), pid: 1,
            appName: "App\(id)", bundleID: "app.\(id)", title: "W\(id)",
            frame: frame, isMinimized: false, isAlive: true,
            lastFocused: nil, deadAt: nil)
    }
}

private final class SweepFakeMover: WindowMoving {
    let model: SweepFakeWindows
    init(model: SweepFakeWindows) { self.model = model }
    func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
        model.windows[window.id]?.frame = frame
        return true
    }
    func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
        model.windows[window.id]?.frame.origin = point
        return true
    }
    func raise(_ window: WindowModel.Window) {}
}
