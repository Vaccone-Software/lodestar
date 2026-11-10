import AppKit
import CoreGraphics
import Foundation
import LodestarCore
import StoicSealed
import Stoic
import StoicTime
import Synchronization

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
        Log.attempt("self-test: could not make the scratch folder") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer {
            Log.attemptUnlessAbsent("self-test: could not remove the scratch folder") {
                try FileManager.default.removeItem(at: directory)
            }
        }
        // A scratch directory gets a scratch key: never the person's keychain.
        let monitor = HealthMonitor(directory: directory,
                                    vault: Vault(custody: InMemoryKeyCustody(), directory: directory))
        monitor.listensToTheMouse = false
        monitor.setEnabled(true)

        let deadline = ContinuousClock.now + .seconds(seconds)
        let group = DispatchGroup()
        var mouseCalls = 0
        var keyCalls = 0
        let counts = NSLock()

        group.enter()
        Thread {
            let probe: CGFloat = 100
            let point = CGPoint(x: probe, y: probe)
            var i = 0
            while ContinuousClock.now < deadline {
                let now = Moment.now.date
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
            while ContinuousClock.now < deadline {
                let now = Moment.now.date
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
        let watchdog = MainThreadWatchdog(interval: 0.1, ceiling: 1, launchCeiling: 1)
        watchdog.onStall = { _ in stalled = true }
        watchdog.start()
        while ContinuousClock.now < deadline {
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
        let reader = clipboardReader()
        return modelsService() && reader && ok
    }

    /// The models service the bundle carries, launched by launchd by its
    /// name and asked to evaluate four squares on the GPU: proof that it
    /// starts and that MLX finds its device and the kernels in the
    /// service's own Resources. No model loads (`editor check` does that).
    /// The tests host the service's object with a fake engine; only the
    /// signed bundle can prove the rest. Outside an app bundle there is no
    /// service to find, and it says so.
    static func modelsService(timeout: TimeInterval = 30) -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            print("self-test: the models service is skipped outside an app bundle")
            return true
        }
        let service = bundle.appendingPathComponent("Contents/XPCServices/LodestarModels.xpc")
        guard FileManager.default.fileExists(atPath: service.path) else {
            print("self-test FAILED: the bundle carries no models service at \(service.path)")
            return false
        }
        // The process's one peer of the service (design/25, rule 2).
        let client = ModelsClient.shared
        let started = ContinuousClock.now
        let answer = Box<Result<ModelsCheck, Error>>()
        // An ordinary Task, so the service's events go where the process's
        // ambient context sends them; the loop below spins the main run loop,
        // and this is not isolated to the main actor, so it is not waiting
        // behind it.
        let task = Task(priority: .medium) {
            do { answer.set(.success(try await client.check())) } catch { answer.set(.failure(error)) }
        }
        while answer.value == nil, started.secondsElapsed < timeout {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        task.cancel()
        let ms = Int(started.secondsElapsed * 1000)
        switch answer.value {
        case .success(let check) where check.pid != getpid():
            print("self-test ok: the models service (pid \(check.pid)) answered in \(ms) ms: \(check.answer)")
            return true
        case .success(let check):
            print("self-test FAILED: the models check ran in this process (\(check.answer))")
        case .failure(let error):
            print("self-test FAILED: the models service did not evaluate: \(error) in \(ms) ms")
        case nil:
            print("self-test FAILED: the models service did not answer in \(Int(timeout)) s")
        }
        return false
    }

    private final class Box<Value: Sendable>: Sendable {
        private let stored = Mutex<Value?>(nil)
        func set(_ value: Value) { stored.withLock { $0 = value } }
        var value: Value? { stored.withLock { $0 } }
    }

    /// The clipboard reader the bundle carries, launched by launchd by its
    /// name and asked to read a board of the self-test's own. The tests
    /// host the service's object behind an anonymous listener; only the
    /// signed bundle can prove the service is found, starts and reads.
    /// Outside an app bundle there is no service to find, and it says so.
    static func clipboardReader(timeout: TimeInterval = 10) -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            print("self-test: the clipboard reader is skipped outside an app bundle")
            return true
        }
        let service = bundle.appendingPathComponent("Contents/XPCServices/LodestarClipboardReader.xpc")
        guard FileManager.default.fileExists(atPath: service.path) else {
            print("self-test FAILED: the bundle carries no clipboard reader at \(service.path)")
            return false
        }
        let board = NSPasteboard(name: NSPasteboard.Name("lodestar.self-test.\(getpid())"))
        defer { board.releaseGlobally() }
        let text = "self-test \(UUID().uuidString)"
        board.clearContents()
        board.setString(text, forType: .string)
        let reader = XPCPasteboardReader(boardName: board.name.rawValue)
        var answer: PasteboardSnapshot??
        let started = ContinuousClock.now
        reader.read(sourceBundleID: nil, excludedApps: []) { answer = .some($0) }
        while answer == nil, started.secondsElapsed < timeout + 1 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        reader.stop()
        let read = answer.flatMap { $0 }?.items.first?.plain
        let ok = read == text
        let ms = Int(started.secondsElapsed * 1000)
        print(ok ? "self-test ok: the clipboard reader service answered in \(ms) ms"
                 : "self-test FAILED: the clipboard reader service read \(read.map { "\"\($0)\"" } ?? "nothing") in \(ms) ms")
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
