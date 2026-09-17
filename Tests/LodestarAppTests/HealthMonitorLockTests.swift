import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The mouse tap's callback must always return. It once did not: the
/// first click after boot took the monitor's lock, then asked the lid
/// under the same lock, and the tap thread deadlocked on itself — the
/// main thread queued behind it on the next keystroke, the system
/// disabled the key tap, and lode fell through as plain command. This
/// proves a click and a scroll both come back, on a thread of their
/// own, against a monitor whose stores live in a scratch directory.
final class HealthMonitorLockTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-health-lock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Hardware provenance, the way the tap would see a hand's event.
    private func human(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceStateID, value: Coach.hidSystemStateID)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func click() -> CGEvent {
        human(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseDown,
                      mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)!)
    }

    private func scroll() -> CGEvent {
        human(CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                      wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!)
    }

    /// The callback runs on a thread of its own; if it ever blocks, the
    /// expectation times out instead of the suite hanging.
    private func assertReturns(_ label: String, _ work: @escaping () -> Void) {
        let returned = expectation(description: label)
        Thread { work(); returned.fulfill() }.start()
        wait(for: [returned], timeout: 3)
    }

    func testAClickNeverBlocksTheTapThread() {
        let monitor = HealthMonitor(directory: directory)
        let event = click()
        assertReturns("click") { monitor.sawMouse(type: .leftMouseDown, event: event) }
        // And a second one, now that the lid and the rosters are cached.
        let again = click()
        assertReturns("second click") { monitor.sawMouse(type: .leftMouseDown, event: again) }
    }

    func testAScrollNeverBlocksTheTapThread() {
        let monitor = HealthMonitor(directory: directory)
        let event = scroll()
        assertReturns("scroll") { monitor.sawMouse(type: .scrollWheel, event: event) }
    }

    func testAClickThenAKeyOnAnotherThreadBothReturn() {
        let monitor = HealthMonitor(directory: directory)
        let event = click()
        assertReturns("click") { monitor.sawMouse(type: .leftMouseDown, event: event) }
        // The main-thread half: the key that once queued forever behind
        // the deadlocked tap.
        let key = expectation(description: "key")
        DispatchQueue.main.async {
            monitor.noteKey(backspace: false)
            key.fulfill()
        }
        wait(for: [key], timeout: 3)
    }

    /// The stores went where they were told, and nowhere near the real
    /// data directory.
    func testTheStoresLiveBesideTheDirectoryGiven() {
        _ = HealthMonitor(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("install-id").path))
    }
}
