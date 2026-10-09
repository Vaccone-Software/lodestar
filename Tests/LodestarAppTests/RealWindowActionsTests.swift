import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Lodestar's own window actions against real windows: the stage's world
/// records what it was asked and never moves one, so these are the tests
/// that say a summon really fills the display, a beside really halves it,
/// undo really puts the windows back and a park really reaches the corner.
///
/// The windows belong to `WindowFixture`, a stand-in app built beside the
/// tests, and are read back through accessibility, the way the actions
/// write them. They live on a display that exists only here, far off every
/// real one, and are transparent besides: a run moves nothing a person can
/// see and takes no focus, so it runs at the desk while someone works. It
/// needs the launching terminal to be trusted for Accessibility, which a
/// hosted runner is not, and skips there.
final class RealWindowActionsTests: XCTestCase {
    /// The display the fixture's windows stand on: the stage's own
    /// stand-in screen, off every real display.
    static let display = Displays.DisplayInfo(id: 4_040_404, bounds: Stage.screen)

    private var world: RealWindowWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard AXIsProcessTrusted() else { throw XCTSkip("the launching terminal needs Accessibility") }
        world = try RealWindowWorld(display: Self.display, count: 3)
    }

    override func tearDown() {
        // The promise this suite runs on: whatever the actions did, no
        // window of the fixture's ever stood on a real display.
        if let world {
            let real = Displays.allBounds()
            for id in world.ids {
                guard let frame = world.frame(id) else { continue }
                XCTAssertFalse(real.contains { $0.intersects(frame) }, "window \(id) at \(frame) reached a real display")
            }
        }
        world?.close()
        world = nil
        super.tearDown()
    }

    private var bounds: CGRect { Self.display.bounds }

    /// A summon fills the display it lands on.
    func testASummonFillsTheDisplay() throws {
        let a = world.ids[0]
        world.actions.summonWindow(a, beside: false)
        world.settle()
        try world.assertFrame(a, bounds, "the summoned window fills the display")
    }

    /// Beside halves the display, the earlier window on the left.
    func testBesideHalvesTheDisplay() throws {
        let (a, b) = (world.ids[0], world.ids[1])
        world.actions.summonWindow(a, beside: false)
        world.actions.summonWindow(b, beside: true)
        world.settle()
        let halves = Tiling.frames(count: 2, in: bounds, orientation: .horizontal)
        try world.assertFrame(a, halves[0], "the first takes the left half")
        try world.assertFrame(b, halves[1], "the one beside it, the right")
    }

    /// Three beside one another take thirds, and the flip stacks them.
    func testFlippingStacksTheLayout() throws {
        for (index, id) in world.ids.enumerated() { world.actions.summonWindow(id, beside: index > 0) }
        world.settle()
        let thirds = Tiling.frames(count: 3, in: bounds, orientation: .horizontal)
        for (id, frame) in zip(world.ids, thirds) { try world.assertFrame(id, frame, "side by side") }
        world.actions.flipOrientation()
        world.settle()
        let rows = Tiling.frames(count: 3, in: bounds, orientation: .vertical)
        for (id, frame) in zip(world.ids, rows) { try world.assertFrame(id, frame, "stacked") }
    }

    /// A plain summon replaces the layout: the windows it held go to the
    /// corner sliver, still alive, and undo brings them back where they
    /// stood.
    func testAReplaceParksTheOthersAndUndoBringsThemBack() throws {
        let (a, b, c) = (world.ids[0], world.ids[1], world.ids[2])
        world.actions.summonWindow(a, beside: false)
        world.actions.summonWindow(b, beside: true)
        world.settle()
        let halves = Tiling.frames(count: 2, in: bounds, orientation: .horizontal)
        world.actions.summonWindow(c, beside: false)
        world.settle()
        try world.assertFrame(c, bounds, "the summoned window takes the display")
        let corner = ParkingLot.parkPosition(on: bounds)
        for id in [a, b] {
            let origin = try XCTUnwrap(world.frame(id)?.origin)
            XCTAssertEqual(origin.x, corner.x, accuracy: 1, "window \(id) is parked in the corner")
            XCTAssertEqual(origin.y, corner.y, accuracy: 1)
        }
        world.actions.undoLayout()
        world.settle()
        try world.assertFrame(a, halves[0], "undo restores the pair")
        try world.assertFrame(b, halves[1])
        world.actions.redoLayout()
        world.settle()
        try world.assertFrame(c, bounds, "and redo takes the display again")
    }

    /// ⇧ and a digit slides the window in front to that place; the
    /// others shift to make room.
    func testReorderingSlidesTheWindowInFrontToItsPlace() throws {
        for (index, id) in world.ids.enumerated() { world.actions.summonWindow(id, beside: index > 0) }
        world.settle()
        world.focus(world.ids[2])
        world.actions.reorderFocused(toDigit: 1)
        world.settle()
        let thirds = Tiling.frames(count: 3, in: bounds, orientation: .horizontal)
        try world.assertFrame(world.ids[2], thirds[0], "the window in front is first now")
        try world.assertFrame(world.ids[0], thirds[1])
        try world.assertFrame(world.ids[1], thirds[2])
    }

    /// Maximize adopts the window in front, which Lodestar did not summon,
    /// and fills the display with it.
    func testMaximizeAdoptsTheWindowInFront() throws {
        let b = world.ids[1]
        world.focus(b)
        world.actions.maximizeFocused(beside: false)
        world.settle()
        try world.assertFrame(b, bounds, "the window in front fills the display")
    }

    /// A window that closed is refused, not placed.
    func testAClosedWindowIsRefused() throws {
        let (a, b) = (world.ids[0], world.ids[1])
        world.actions.summonWindow(a, beside: false)
        world.settle()
        world.closeWindow(b)
        world.actions.summonWindow(b, beside: true)
        world.settle()
        XCTAssertFalse(world.layout.allMembers.contains(b), "a closed window never joins the layout")
        try world.assertFrame(a, bounds, "nothing moved for a window that is gone")
    }
}

/// Moves that leave a trace a person can see, kept for a run at the desk
/// on purpose: a minimized window takes a tile in the Dock, and a move
/// between displays needs two real ones. Set LODESTAR_DESK_WINDOWS=1.
final class RealWindowDeskTests: XCTestCase {
    private var world: RealWindowWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["LODESTAR_DESK_WINDOWS"] != nil else {
            throw XCTSkip("set LODESTAR_DESK_WINDOWS=1: these show in the Dock and on real displays")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("the launching terminal needs Accessibility") }
    }

    override func tearDown() {
        world?.close()
        world = nil
        super.tearDown()
    }

    /// A minimized window summoned comes out of the Dock and fills the
    /// display.
    func testAMinimizedWindowIsBroughtBackAndPlaced() throws {
        world = try RealWindowWorld(display: RealWindowActionsTests.display, count: 1)
        let a = world.ids[0]
        XCTAssertTrue(world.minimize(a))
        world.settle(until: { self.world.isMinimized(a) })
        world.actions.summonWindow(a, beside: false)
        world.settle(until: { !self.world.isMinimized(a) })
        XCTAssertFalse(world.isMinimized(a), "out of the Dock")
        try world.assertFrame(a, RealWindowActionsTests.display.bounds, "and filling the display")
    }

    /// lode ] throws the window in front to the next display, where it
    /// fills the screen; undo brings it home. Real displays: the move asks
    /// the system which display a window is on and which is next.
    func testThrowingAWindowToTheNextDisplay() throws {
        let screens = Displays.ordered()
        guard screens.count > 1 else { throw XCTSkip("one display attached") }
        let home = screens[0], next = screens[1]
        let start = CGRect(x: home.bounds.minX + 100, y: home.bounds.minY + 100, width: 500, height: 400)
        world = try RealWindowWorld(displays: .live, frames: [start], visible: true)
        let a = world.ids[0]
        world.focus(a)
        world.actions.moveFocusedDisplay(direction: 1, beside: false)
        world.settle()
        let landed = try XCTUnwrap(world.frame(a))
        XCTAssertTrue(Displays.visibleFrame(containing: next.bounds).insetBy(dx: -2, dy: -2).contains(landed),
                      "on the next display, filling it")
    }
}

/// The fixture's windows, a real window model holding them, and Lodestar's
/// real actions over a layout whose displays the test names.
final class RealWindowWorld {
    let process = Process()
    private let input = Pipe()
    let model = WindowModel()
    let layout: LayoutController
    let parking: ParkingLot
    let actions: Actions
    let hud: HUD
    private(set) var ids: [CGWindowID] = []
    private let directory: URL
    private let savedFrame = ActivePolicy.frameOverride

    convenience init(display: Displays.DisplayInfo, count: Int) throws {
        let oracle = DisplayOracle(
            ordered: { [display] },
            visibleFrame: { _ in display.bounds },
            displayContaining: { $0.intersects(display.bounds) ? display : nil },
            uuid: { _ in "fixture-display" })
        // Staggered inside the display, each a different size, so a window
        // that was never moved cannot pass for one that was.
        let frames = (0..<count).map { index in
            CGRect(x: display.bounds.minX + 40 + CGFloat(index) * 60, y: display.bounds.minY + 40 + CGFloat(index) * 30,
                   width: 520 + CGFloat(index) * 40, height: 380 + CGFloat(index) * 20)
        }
        try self.init(displays: oracle, frames: frames, parkOn: [display.bounds], visible: false)
    }

    init(displays: DisplayOracle, frames: [CGRect], parkOn bounds: [CGRect]? = nil, visible: Bool) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActivePolicy.frameOverride = Stage.screen
        parking = ParkingLot(mover: AXMover(), bounds: { bounds ?? displays.ordered().map(\.bounds) })
        layout = LayoutController(model: model, parking: parking, mover: AXMover(), displays: displays)
        hud = HUD()
        actions = Actions(model: model, parking: parking, layout: layout, appIndex: AppIndex(),
                          store: StateStore(file: directory.appendingPathComponent("state.json")), hud: hud)
        actions.attach()
        try launch(frames: frames, visible: visible)
    }

    /// The fixture, built beside this bundle by `swift build --build-tests`.
    static var fixture: URL {
        Bundle(for: RealWindowWorld.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("WindowFixture")
    }

    private func launch(frames: [CGRect], visible: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.fixture.path) else {
            throw XCTSkip("WindowFixture is not built beside the tests: swift build --build-tests")
        }
        let output = Pipe()
        process.executableURL = Self.fixture
        process.arguments = ["--frames", frames.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
            .joined(separator: ";")] + (visible ? ["--visible"] : [])
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        // One line, "ready" and the ids, or the fixture failed to start.
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.first == "ready" else { throw XCTSkip("the fixture did not start: \(line)") }
        let wanted = words.dropFirst().compactMap { CGWindowID($0) }
        let pid = process.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        // Its windows answer accessibility a beat after they are drawn.
        var elements: [CGWindowID: AXUIElement] = [:]
        let deadline = Date().addingTimeInterval(5)
        while elements.count < wanted.count, Date() < deadline {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            for element in (value as? [AXUIElement]) ?? [] {
                if let id = windowID(of: element), wanted.contains(id) { elements[id] = element }
            }
            if elements.count < wanted.count { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        guard elements.count == wanted.count else {
            close()
            throw XCTSkip("the fixture's windows never answered accessibility")
        }
        ids = wanted
        for (id, frame) in zip(wanted, frames) {
            model.stand(WindowModel.Window(
                id: id, element: elements[id]!, pid: pid, appName: "WindowFixture", bundleID: nil,
                title: "Fixture", frame: frame, isMinimized: false, isAlive: true, lastFocused: Date()))
        }
    }

    /// Put a window in front, as a person clicking it would for the model.
    func focus(_ id: CGWindowID) {
        guard let window = model.window(id) else { return }
        model.stand(window)
    }

    /// Let the moves, their read-back and the corrective pass land.
    func settle(until condition: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(condition == nil ? 0.4 : 5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let condition, condition() { return }
        }
    }

    func element(_ id: CGWindowID) -> AXUIElement? { model.window(id)?.element }

    /// Where the window really is, asked of the window itself.
    func frame(_ id: CGWindowID) -> CGRect? { element(id).flatMap { AXWindow(element: $0)?.frame } }

    func isMinimized(_ id: CGWindowID) -> Bool { element(id).flatMap { AXWindow(element: $0)?.isMinimized } ?? false }

    @discardableResult
    func minimize(_ id: CGWindowID) -> Bool { element(id).flatMap { AXWindow(element: $0)?.setMinimized(true) } ?? false }

    func closeWindow(_ id: CGWindowID) {
        guard let element = element(id) else { return }
        var button: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button)
        if let button { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
        settle()
    }

    func assertFrame(_ id: CGWindowID, _ expected: CGRect, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(frame(id), "window \(id) has no frame", file: file, line: line)
        for (a, e, edge) in [(actual.minX, expected.minX, "x"), (actual.minY, expected.minY, "y"),
                             (actual.width, expected.width, "width"), (actual.height, expected.height, "height")] {
            XCTAssertEqual(a, e, accuracy: 1, "\(message): \(edge) of \(actual) against \(expected)",
                           file: file, line: line)
        }
    }

    func close() {
        if process.isRunning {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        hud.hide()
        ActivePolicy.frameOverride = savedFrame
        try? FileManager.default.removeItem(at: directory)
    }
}
