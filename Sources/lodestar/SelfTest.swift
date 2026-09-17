import CoreGraphics
import Foundation
import LodestarCore

/// `lodestar --self-test`: the built binary proves, on real threads, that
/// the part which once froze cannot. A release script runs it on the
/// signed universal app before anything is notarized; it is the same
/// stress the harness runs, without the harness.
///
/// Two threads hammer the health monitor — one as the mouse tap, one as
/// the key tap — while the main thread is pinged. Every call must return
/// inside the deadline and the main thread must keep answering. Exit
/// zero means it did; anything else is a build that must not ship.
enum SelfTest {
    static func run(seconds: TimeInterval = 2) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-self-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = HealthMonitor(directory: directory)
        monitor.listensToTheMouse = false
        monitor.setEnabled(true)

        let deadline = Date().addingTimeInterval(seconds)
        let group = DispatchGroup()
        var mouseCalls = 0
        var keyCalls = 0
        let counts = NSLock()

        group.enter()
        Thread {
            let point = CGPoint(x: 100, y: 100)
            var i = 0
            while Date() < deadline {
                let now = Date()
                let kind: CGEventType = [.mouseMoved, .leftMouseDown, .leftMouseUp, .scrollWheel][i % 4]
                if let event = Self.event(kind, at: point) {
                    monitor.sawMouse(type: kind, event: event)
                } else {
                    monitor.saw(Self.report(kind, at: point, now: now))
                }
                i += 1
            }
            counts.lock(); mouseCalls = i; counts.unlock()
            group.leave()
        }.start()

        group.enter()
        Thread {
            var i = 0
            while Date() < deadline {
                let now = Date()
                monitor.noteKey(backspace: i % 7 == 0, at: now)
                monitor.notePress(KeyPress(down: now, hold: 0.09, hand: i % 2 == 0 ? .left : .right,
                                           kind: .letter, finger: .index))
                monitor.noteHold(0.09, at: now)
                i += 1
            }
            counts.lock(); keyCalls = i; counts.unlock()
            group.leave()
        }.start()

        // The main thread must keep answering while both taps run.
        var pings = 0
        var stalled = false
        let watchdog = MainThreadWatchdog(interval: 0.1, ceiling: 1)
        watchdog.onStall = { _ in stalled = true }
        watchdog.start()
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            pings += 1
        }
        watchdog.stop()
        let finished = group.wait(timeout: .now() + 5) == .success
        monitor.drainForTesting()
        monitor.setEnabled(false)
        let ok = finished && !stalled && mouseCalls > 100 && keyCalls > 100
        print(ok
              ? "self-test ok: \(mouseCalls) mouse reports, \(keyCalls) key reports, main answered \(pings) times"
              : "self-test FAILED: finished=\(finished) stalled=\(stalled) mouse=\(mouseCalls) keys=\(keyCalls)")
        return ok
    }

    /// A hardware-looking event of the kind, or nil when the type has no
    /// such constructor here (the report path covers it).
    private static func event(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        let event: CGEvent?
        switch type {
        case .scrollWheel:
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: -3, wheel2: 0, wheel3: 0)
        case .mouseMoved, .leftMouseDown, .leftMouseUp:
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                            mouseButton: .left)
        default:
            event = nil
        }
        event?.setIntegerValueField(.eventSourceStateID, value: Coach.hidSystemStateID)
        event?.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private static func report(_ type: CGEventType, at point: CGPoint, now: Date) -> HealthMonitor.MouseReport {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                            mouseButton: .left)!
        var report = HealthMonitor.MouseReport(type: type, event: event, now: now)
        report.human = true
        return report
    }
}
