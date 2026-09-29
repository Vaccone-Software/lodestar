import ApplicationServices
import XCTest
@testable import LodestarCore

/// The window model never waits on another app on the main thread: what
/// it hears by notification is read on that app's queue and recorded when
/// the reading lands. A scripted reader plays the apps — slow, hung, or
/// quick — and each element stands for one window.
final class WindowModelOffMainTests: XCTestCase {
    final class ScriptedReader: WindowAXReader, @unchecked Sendable {
        let lock = NSLock()
        var ids: [pid_t: CGWindowID] = [:]            // element pid → window id
        var delay: [pid_t: TimeInterval] = [:]        // element pid → seconds to answer
        var titles: [pid_t: String] = [:]
        var reads = 0
        var focused: [pid_t: AXUIElement] = [:]       // app pid → focused element
        var frames: [pid_t: CGRect] = [:]              // element pid → frame
        var frameDelay: TimeInterval = 0

        private func pid(_ element: AXUIElement) -> pid_t {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return pid
        }
        private func wait(_ element: AXUIElement) {
            let seconds = lock.withLock { delay[pid(element)] ?? 0 }
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
        func windowID(of element: AXUIElement) -> CGWindowID? {
            wait(element)
            return lock.withLock { ids[pid(element)] }
        }
        func reading(of element: AXUIElement) -> WindowModel.Reading? {
            lock.withLock { reads += 1 }
            let title = lock.withLock { titles[pid(element)] ?? "" }
            return .init(title: title, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false,
                         subrole: "AXStandardWindow")
        }
        func title(of element: AXUIElement) -> String? {
            wait(element)
            return lock.withLock { titles[pid(element)] }
        }
        /// The frame as it stood when the question was asked, answered late.
        func frame(of element: AXUIElement) -> CGRect? {
            let (seen, seconds) = lock.withLock {
                (frames[pid(element)] ?? CGRect(x: 10, y: 10, width: 500, height: 400), frameDelay)
            }
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            return seen
        }
        func windows(of pid: pid_t) -> [AXUIElement]? { [] }
        func focusedWindow(of pid: pid_t) -> AXUIElement? { lock.withLock { focused[pid] } }
    }

    private let appPid: pid_t = 424_242
    private func app(_ pid: pid_t) -> WindowModel.AppInfo { .init(pid: pid, name: "App \(pid)", bundleID: "test.\(pid)") }

    /// One element per window: an application element for a pid nobody has.
    private func window(_ n: Int32) -> AXUIElement { AXUIElementCreateApplication(900_000 + n) }

    private func model(_ reader: ScriptedReader, frontmost: pid_t? = nil) -> WindowModel {
        let model = WindowModel(reader: reader, appLookup: { [unowned self] pid in self.app(pid) })
        model.frontmostApp = { nil }
        return model
    }

    private func pump(until condition: () -> Bool, within seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testANewWindowFromAHungAppNeverHoldsTheMainThread() {
        let reader = ScriptedReader()
        reader.ids[900_001] = 11
        reader.delay[900_001] = 1.0
        let model = model(reader)
        var created: [CGWindowID] = []
        model.onCreated = { created.append($0) }
        let started = Date()
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(1), pid: appPid)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "the notification came straight back")
        XCTAssertNil(model.window(11), "not known until the reading lands")
        pump { model.window(11) != nil }
        XCTAssertEqual(model.window(11)?.appName, "App \(appPid)")
        XCTAssertEqual(created, [11], "announced once, when it is known")
    }

    func testAWindowDestroyedWhileBeingReadNeverArrives() {
        let reader = ScriptedReader()
        reader.ids[900_002] = 12
        reader.delay[900_002] = 0.3
        let model = model(reader)
        var created: [CGWindowID] = []
        model.onCreated = { created.append($0) }
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(2), pid: appPid)
        model.receiveForTesting(kAXUIElementDestroyedNotification, element: window(2), pid: appPid)
        pump(until: { false }, within: 0.6)
        XCTAssertNil(model.window(12))
        XCTAssertTrue(created.isEmpty, "a popup that closed before it was read is never announced")
    }

    func testAHungAppDoesNotDelayAnotherAppsWindows() {
        let reader = ScriptedReader()
        reader.ids[900_003] = 13
        reader.delay[900_003] = 2.0
        reader.ids[900_004] = 14
        let model = model(reader)
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(3), pid: 1_001)
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(4), pid: 1_002)
        pump(until: { model.window(14) != nil }, within: 1)
        XCTAssertNotNil(model.window(14), "the quick app's window is known")
        XCTAssertNil(model.window(13), "while the hung app's is still being read")
    }

    func testAFocusChangeTakesEffectWhenTheReadingLands() {
        let reader = ScriptedReader()
        reader.ids[900_005] = 15
        reader.delay[900_005] = 0.2
        let model = model(reader)
        model.frontmostApp = { nil }
        var focused: [CGWindowID] = []
        model.onFocus = { focused.append($0) }
        // Not the app in front: tracked, focus untouched.
        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(5), pid: appPid)
        pump { model.window(15) != nil }
        XCTAssertTrue(focused.isEmpty)
        XCTAssertNil(model.focusedID)
    }

    func testATitleChangeIsReadOffMainAndAnnounced() {
        let reader = ScriptedReader()
        reader.ids[900_006] = 16
        reader.titles[900_006] = "Draft"
        let model = model(reader)
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(6), pid: appPid)
        pump { model.window(16) != nil }
        XCTAssertEqual(model.window(16)?.title, "Draft")
        reader.lock.withLock {
            reader.titles[900_006] = "Final"
            reader.delay[900_006] = 0.5
        }
        var changed: [CGWindowID] = []
        model.onTitleChanged = { changed.append($0) }
        let started = Date()
        model.receiveForTesting(kAXTitleChangedNotification, element: window(6), pid: appPid)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "the title is not read on main")
        pump { !changed.isEmpty }
        XCTAssertEqual(model.window(16)?.title, "Final")
        XCTAssertEqual(changed, [16])
    }

    /// A, then a new window N, then A again: the known window's focus
    /// applies at once and N's when its reading lands, which used to leave
    /// the model on N. The last notice is the one that stands.
    func testFocusEndsWhereTheHandEnded() {
        let reader = ScriptedReader()
        let me = appPid
        reader.ids[900_010] = 20
        reader.ids[900_011] = 21
        let model = model(reader)
        model.frontmostPid = { me }
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(10), pid: me)
        pump { model.window(20) != nil }
        reader.lock.withLock { reader.delay[900_011] = 0.3 }
        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(11), pid: me)
        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(10), pid: me)
        pump(until: { model.window(21) != nil })
        pump(until: { false }, within: 0.2)
        XCTAssertEqual(model.focusedID, 20, "the window focused last, not the one read last")
    }

    /// A drag that ends while its frame is being read is read again.
    func testAMoveDuringAFrameReadIsReadAgain() {
        let reader = ScriptedReader()
        reader.ids[900_012] = 22
        let model = model(reader)
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(12), pid: appPid)
        pump { model.window(22) != nil }
        let first = CGRect(x: 100, y: 100, width: 600, height: 400)
        let last = CGRect(x: 300, y: 200, width: 600, height: 400)
        reader.lock.withLock {
            reader.frames[900_012] = first
            reader.frameDelay = 0.25
        }
        model.receiveForTesting(kAXMovedNotification, element: window(12), pid: appPid)
        Thread.sleep(forTimeInterval: 0.05)                 // the read is out, and has seen `first`
        reader.lock.withLock { reader.frames[900_012] = last }
        model.receiveForTesting(kAXMovedNotification, element: window(12), pid: appPid)
        pump(until: { model.window(22)?.frame == last }, within: 2)
        XCTAssertEqual(model.window(22)?.frame, last, "where the window ended, not where the first read found it")
    }

    func testTwoNoticesForOneWindowReadItOnce() {
        let reader = ScriptedReader()
        reader.ids[900_007] = 17
        reader.delay[900_007] = 0.2
        let model = model(reader)
        var created = 0
        model.onCreated = { _ in created += 1 }
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(7), pid: appPid)
        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(7), pid: appPid)
        pump { model.window(17) != nil }
        pump(until: { false }, within: 0.3)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(reader.lock.withLock { reader.reads }, 1, "one reading for both notices")
    }
}

/// Against the apps really running, on by environment: the launch scan
/// no longer holds main, and the windows still arrive.
final class WindowModelLiveTests: XCTestCase {
    func testTheLaunchScanRunsOffMainAndFindsTheWindows() throws {
        guard ProcessInfo.processInfo.environment["LODESTAR_LIVE_MODEL"] != nil else {
            throw XCTSkip("set LODESTAR_LIVE_MODEL to scan the apps running now")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("not trusted for accessibility") }
        let model = WindowModel()
        var traces: [String] = []
        model.onTrace = { traces.append($0) }
        let started = Date()
        model.start()
        let startCost = Date().timeIntervalSince(started)
        let deadline = Date().addingTimeInterval(20)
        while !traces.contains(where: { $0.hasPrefix("seeded") }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let alive = model.windows.values.filter(\.isAlive).count
        print("LIVE start()=\(Int(startCost * 1000))ms \(traces.first { $0.hasPrefix("seeded") } ?? "no seed line") alive=\(alive)")
        model.stop()
        XCTAssertLessThan(startCost, 0.5, "start returns without reading every window")
        XCTAssertGreaterThan(alive, 0, "and the windows still arrive")
    }
}
