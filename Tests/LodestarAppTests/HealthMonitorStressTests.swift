import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Two taps at once, thousands of times, with a deadline: the mouse side
/// on one thread, the key side on another, the main thread pinged
/// throughout. Any call that blocks fails the run instead of hanging it.
/// This is the general form of the test that would have caught the
/// first-click freeze; it runs against the real monitor at a scratch
/// directory, and the raw stores are read back to prove the work landed.
final class HealthMonitorStressTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-health-stress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func mouse(_ type: CGEventType, at point: CGPoint) -> CGEvent {
        let source = CGEventSource(stateID: .hidSystemState)
        let event: CGEvent
        if type == .scrollWheel {
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: -3, wheel2: 0, wheel3: 0)!
        } else {
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                            mouseButton: .left)!
        }
        event.setIntegerValueField(.eventSourceStateID, value: Coach.hidSystemStateID)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    func testBothTapsAtOnceNeverBlockAndTheStoresFill() throws {
        let monitor = HealthMonitor(directory: directory)
        monitor.listensToTheMouse = false
        monitor.setEnabled(true)
        let iterations = 2000
        let mouseDone = expectation(description: "mouse side")
        let keyDone = expectation(description: "key side")
        let base = Date()

        Thread {
            let point = CGPoint(x: 40, y: 40)
            for i in 0..<iterations {
                let type: CGEventType = [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseUp, .scrollWheel][i % 5]
                monitor.sawMouse(type: type, event: self.mouse(type, at: point))
            }
            mouseDone.fulfill()
        }.start()

        Thread {
            for i in 0..<iterations {
                let now = base.addingTimeInterval(Double(i) * 0.15)
                monitor.noteKey(backspace: i % 9 == 0, at: now)
                monitor.notePress(KeyPress(down: now, hold: 0.09, hand: i % 2 == 0 ? .left : .right,
                                           kind: .letter, finger: .index))
                monitor.noteHold(0.09, at: now)
            }
            keyDone.fulfill()
        }.start()

        // Main keeps turning while both run; a stall here would surface
        // as the wait timing out.
        wait(for: [mouseDone, keyDone], timeout: 10)
        monitor.drainForTesting()
        monitor.tick(now: base.addingTimeInterval(600))
        monitor.drainForTesting()
        monitor.setEnabled(false)

        // The work landed: presses in the key store, clicks in the pointer store.
        let keyDir = directory.appendingPathComponent(KeyStore.subdirectory)
        let keyDays = KeyStore.days(in: keyDir)
        XCTAssertFalse(keyDays.isEmpty)
        let presses = keyDays.flatMap { KeyStore.presses(day: $0, in: keyDir) }
        XCTAssertEqual(presses.count, iterations)
        let pointerDir = directory.appendingPathComponent(PointerStore.subdirectory)
        let records = PointerStore.days(in: pointerDir).flatMap { PointerStore.records(day: $0, in: pointerDir) }
        let clicks = records.filter { if case .click = $0 { return true } else { return false } }
        XCTAssertEqual(clicks.count, iterations / 5)
    }
}
