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
        /// Reads of these elements stay out until the test lets them go,
        /// so "main never waited" is an order the test sees, not a time
        /// it measures: the call returned while its read was still held.
        var held = Set<pid_t>()
        var holdFrames = false
        let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private(set) var finished = Set<pid_t>()

        func release(_ count: Int = 8) { for _ in 0..<count { released.signal() } }
        func done(_ n: Int32) -> Bool { lock.withLock { finished.contains(900_000 + n) } }
        private func holdIfAsked(_ pid: pid_t, frames: Bool = false) {
            let asked = lock.withLock { held.contains(pid) || (frames && holdFrames) }
            guard asked else { return }
            entered.signal()
            _ = released.wait(timeout: .now() + 5)
        }

        private func pid(_ element: AXUIElement) -> pid_t {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return pid
        }
        private func wait(_ element: AXUIElement) {
            let seconds = lock.withLock { delay[pid(element)] ?? 0 }
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            holdIfAsked(pid(element))
            lock.withLock { _ = finished.insert(pid(element)) }
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
            holdIfAsked(pid(element), frames: true)
            return seen
        }
        var appWindows: [pid_t: [AXUIElement]] = [:]   // app pid → its windows' elements
        func windows(of pid: pid_t) -> [AXUIElement]? { lock.withLock { appWindows[pid] ?? [] } }
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

    /// A window whose title changed without a notification the model heard
    /// (its element replaced, say) keeps the old title until the app's
    /// windows are read again: a profile matched by title looked absent.
    func testRefreshingAnAppsWindowsTakesTheirTitlesAsTheyStand() {
        let reader = ScriptedReader()
        reader.ids[900_021] = 21
        reader.titles[900_021] = "New Tab - Brave"
        reader.appWindows[appPid] = [window(21)]
        let model = model(reader)
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(21), pid: appPid)
        pump { model.window(21) != nil }
        XCTAssertEqual(model.window(21)?.title, "New Tab - Brave")

        reader.titles[900_021] = "Inbox - Brave - Xonar"
        var done = false
        model.refreshWindows(pids: [appPid]) { done = true }
        pump { done }
        XCTAssertEqual(model.window(21)?.title, "Inbox - Brave - Xonar", "the title as it stands now")
    }

    func testRefreshingFindsAWindowNeverTracked() {
        let reader = ScriptedReader()
        reader.ids[900_022] = 22
        reader.titles[900_022] = "Docs - Brave - Default"
        reader.appWindows[appPid] = [window(22)]
        let model = model(reader)
        var done = false
        model.refreshWindows(pids: [appPid]) { done = true }
        pump { done }
        XCTAssertEqual(model.window(22)?.title, "Docs - Brave - Default")
    }

    func testANewWindowFromAHungAppNeverHoldsTheMainThread() {
        let reader = ScriptedReader()
        reader.ids[900_001] = 11
        reader.held = [900_001]
        let model = model(reader)
        var created: [CGWindowID] = []
        model.onCreated = { created.append($0) }
        model.receiveForTesting(kAXWindowCreatedNotification, element: window(1), pid: appPid)
        XCTAssertFalse(reader.done(1), "the notification came back while the hung read was still out")
        XCTAssertNil(model.window(11), "not known until the reading lands")
        reader.release()
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
        // The read finishes and its answer has had its turn on main: a
        // refresh of the same app queues behind it on that app's serial
        // queue, and its completion comes home after the read's answer.
        var barrier = false
        model.refreshWindows(pids: [appPid]) { barrier = true }
        pump(until: { barrier })
        XCTAssertTrue(barrier)
        XCTAssertTrue(reader.done(2), "the read finished")
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
            reader.held = [900_006]
        }
        var changed: [CGWindowID] = []
        model.onTitleChanged = { changed.append($0) }
        model.receiveForTesting(kAXTitleChangedNotification, element: window(6), pid: appPid)
        XCTAssertTrue(changed.isEmpty, "the title is not read on main: the read is still held")
        reader.release()
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
            reader.holdFrames = true
        }
        model.receiveForTesting(kAXMovedNotification, element: window(12), pid: appPid)
        // The read is out, and has seen `first`: it says so, rather than a
        // sleep that hoped so.
        XCTAssertEqual(reader.entered.wait(timeout: .now() + 2), .success, "the frame read started")
        reader.lock.withLock { reader.frames[900_012] = last }
        model.receiveForTesting(kAXMovedNotification, element: window(12), pid: appPid)
        reader.lock.withLock { reader.holdFrames = false }
        reader.release()
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

    /// Zoom rebuilds its accessibility tree mid-meeting: the meeting window
    /// keeps its id while the element the model holds dies and is buried.
    /// A fresh element for that id takes the record over, alive, keeping
    /// when it was last focused; it was once ignored until pruneDead,
    /// seven minutes later.
    func testAFreshElementForABuriedWindowRevivesIt() {
        let reader = ScriptedReader()
        let me = appPid
        reader.ids[900_030] = 50
        reader.ids[900_031] = 50                       // the same window, a new element
        reader.titles[900_031] = "Zoom Meeting"
        let model = model(reader)
        model.frontmostPid = { me }
        var destroyed: [CGWindowID] = []
        model.onDestroyed = { destroyed.append($0) }
        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(30), pid: me)
        pump { model.focusedID == 50 }
        let focusedAt = model.window(50)?.lastFocused
        XCTAssertNotNil(focusedAt)

        model.receiveForTesting(kAXUIElementDestroyedNotification, element: window(30), pid: me)
        XCTAssertEqual(model.window(50)?.isAlive, false, "the dead handle buries the record")
        XCTAssertEqual(destroyed, [50])

        model.receiveForTesting(kAXFocusedWindowChangedNotification, element: window(31), pid: me)
        pump { model.window(50)?.isAlive == true }
        XCTAssertEqual(model.window(50)?.isAlive, true, "revived, not ignored")
        XCTAssertEqual(model.window(50)?.title, "Zoom Meeting")
        var pid: pid_t = 0
        if let element = model.window(50)?.element { AXUIElementGetPid(element, &pid) }
        XCTAssertEqual(pid, 900_031, "the fresh element is the one held")
        XCTAssertNotNil(model.window(50)?.lastFocused, "its history kept")
        XCTAssertEqual(model.focusedID, 50, "and focused again")
        // The old element's death, heard late, does not bury the revived window.
        model.receiveForTesting(kAXUIElementDestroyedNotification, element: window(30), pid: me)
        XCTAssertEqual(model.window(50)?.isAlive, true)
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
