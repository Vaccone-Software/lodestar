import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.ps
import LodestarCore

/// The hands' pulse, gathered: keystroke counts arrive from the main event
/// tap (which already sees every key), clicks, motion and scroll bursts
/// from a listen-only tap of its own. All accumulation happens in
/// `HealthPulse`, `ClickPulse` and `PointerTracker` (core, tested); this
/// class is the plumbing and the gate.
///
/// The mouse tap is `.listenOnly` on its own thread's run loop on purpose:
/// a listening tap cannot delay event delivery, so a busy main thread can
/// never turn health accounting into scroll jank — the batch this ships in
/// is partly *about* never standing in the input path. Motion events are
/// the busiest thing a tap can hear; the tracker spends a lock and a few
/// subtractions on each, and nothing crosses a thread until a press.
///
/// Provenance discipline matches the coach's: only hardware-origin events
/// count. An agent driving the machine is not the user's hands, and a
/// health mirror that counted synthetic input would flatter exactly the
/// hours nobody was there. The click door's own pointer walk is posted by
/// this process and so never prices itself.
final class HealthMonitor {
    /// Where pulses land. Set once at boot.
    var observations: ObservationStore?

    private var pulse = HealthPulse()
    private var clickPulse = ClickPulse()
    /// What the shell knows at a window's close that the presses do not.
    struct WindowContext {
        var app: String?
        var dictation: Bool
    }
    var context: (() -> WindowContext)?
    /// The raw record beneath every summary, and the window that
    /// describes ninety seconds of it at a time.
    private let keys: KeyStore
    private var window = HoldWindow()
    private let roster = KeyboardRoster()
    /// The focused element's role, sampled off the main thread when a
    /// window opens and read at its close: best effort, never waited on.
    private var sampledRole: String?

    init() {
        keys = KeyStore(directory: Paths.data.appendingPathComponent(KeyStore.subdirectory, isDirectory: true),
                        installID: Install.id())
    }
    private var enabled = false
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var flushTimer: Timer?

    /// Mouse-side counts cross from the tap thread through this lock; the
    /// main thread drains them into the pulse on its flush cadence.
    private let lock = NSLock()
    private var pendingClicks: [PendingClick] = []
    private var pendingReleases: [PendingRelease] = []
    private var pendingReturns: [PendingReturn] = []
    private var pendingScrolls: [PendingScroll] = []
    /// The last keystroke and the last mouse act, for the hand-trip
    /// verdict: a click is a trip when the key came after the mouse.
    /// Both under the lock — keys land from the main thread, the mouse
    /// from the tap's. Motion does not move `lastMouseAt`: the verdict
    /// is about the hand having been on the keys since the last press or
    /// scroll, and the reach that follows the key is what homing times.
    private var lastKeyAt: Date?
    private var lastMouseAt: Date?
    /// The pointer's acts, on the tap thread under the lock. Positions
    /// stay inside it.
    private var tracker = PointerTracker()
    private var lastDownAt: Date?
    /// A click is a road a focus change can take; the tracker hears
    /// about it here, from the same tap that prices it.
    var roads: RoadTracker?

    /// A click with its target's class resolved: the pid the element
    /// belongs to and its accessibility role. Nothing else about the
    /// target is ever read. The act is the reach that ended in it.
    private struct PendingClick {
        let at: Date
        let trip: Bool
        let pid: pid_t?
        let role: String?
        let act: PointerTracker.Click
    }

    /// A press came up: joined to its click by the press's stamp when
    /// the main thread drains, because the click's own lookup may still
    /// be in flight when the button lifts.
    private struct PendingRelease {
        let downAt: Date
        let release: PointerTracker.Release
    }

    /// The first key after a press, likewise joined by stamp.
    private struct PendingReturn {
        let downAt: Date
        let seconds: Double
    }

    /// One wheel burst: opened by its first event, extended by each one
    /// inside the gap, closed by the drain once the gap has passed. The
    /// pid is looked up once, at the burst's start.
    private struct PendingScroll {
        let start: Date
        var last: Date
        var pid: pid_t?
    }

    /// Where a click's target is asked for. Off the tap thread: the
    /// accessibility call blocks on the clicked app's event loop, and a
    /// listen-only tap must never carry that wait. Serial, so a wedged
    /// app delays later lookups rather than crowding the machine, and
    /// bounded by its own short messaging timeout.
    private let lookup = DispatchQueue(label: "lodestar.health.lookup", qos: .utility)
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    /// Config's word: `observations.health`, joined with the master
    /// switch by the caller.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            startMouseTap()
            startFlushTimer()
        } else {
            stopMouseTap()
            flushTimer?.invalidate()
            flushTimer = nil
            drainPending(all: true)
            if let final = pulse.flush() { recordPulse(final) }
            for event in clickPulse.flush() { observations?.clickPulse(event) }
            if let closed = window.close() { emit(closed) }
            keys.flushSync()
        }
    }

    /// A hardware keystroke, from the main tap. Main thread. An
    /// autorepeat keydown counts as the hand being present and nothing
    /// more — it is not a reach's return, and it is not typing rhythm.
    func noteKey(backspace: Bool, autorepeat: Bool = false, at now: Date = Date()) {
        guard enabled else { return }
        if !autorepeat {
            lock.lock()
            lastKeyAt = now
            if let seconds = tracker.keyed(at: now), let down = lastDownAt {
                pendingReturns.append(PendingReturn(downAt: down, seconds: seconds))
            }
            lock.unlock()
        }
        if let flushed = pulse.key(at: now, backspace: backspace, autorepeat: autorepeat) {
            recordPulse(flushed)
        }
    }

    /// A pulse closed: it leaves wearing the keyboards that were attached.
    private func recordPulse(_ event: ObservationEvent?) {
        guard var event else { return }
        event.keyboards = roster.ids
        observations?.healthPulse(event)
    }

    /// A hardware press, complete: the raw store keeps it, the window
    /// describes it. Main thread.
    func notePress(_ press: KeyPress) {
        guard enabled else { return }
        keys.append(press)
        if let closed = window.add(press) { emit(closed) }
        if window.count == 1 { sampleRole() }
    }

    /// How late the tap ran after the event's stamp. Main thread.
    func noteJitter(_ seconds: Double, at now: Date = Date()) {
        guard enabled else { return }
        recordPulse(pulse.jitter(seconds, at: now))
    }

    func noteTapReset(at now: Date = Date()) {
        guard enabled else { return }
        recordPulse(pulse.tapReset(at: now))
    }

    /// A window closed: the shell adds what it knows and the store keeps
    /// it. The presses are already in the raw store; only their
    /// description travels.
    private func emit(_ stats: WindowStats) {
        var stats = stats
        let context = context?()
        stats.app = context?.app
        stats.dictation = context?.dictation
        stats.keyboards = roster.ids
        stats.power = Self.powerSource()
        stats.screens = NSScreen.screens.count
        stats.tz = TimeZone.current.secondsFromGMT(for: stats.start)
        lock.lock()
        stats.role = sampledRole
        sampledRole = nil
        lock.unlock()
        var event = ObservationEvent(t: stats.start, kind: .window)
        event.window = stats
        observations?.healthWindow(event)
    }

    /// The focused element's role class, asked with a short leash on the
    /// lookup queue. A role, never a title or a value.
    private func sampleRole() {
        lookup.async { [weak self] in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let element = focused else { return }
            let axElement = element as! AXUIElement
            AXUIElementSetMessagingTimeout(axElement, 0.1)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role) == .success,
                  let name = role as? String else { return }
            guard let self else { return }
            self.lock.lock()
            self.sampledRole = name
            self.lock.unlock()
        }
    }

    /// Mains, battery or a UPS: a laptop on the couch is a different
    /// posture, and often a different keyboard, from the desk.
    private static func powerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return nil }
        switch type {
        case kIOPMACPowerKey: return "ac"
        case kIOPMBatteryPowerKey: return "battery"
        case kIOPMUPSPowerKey: return "ups"
        default: return type.lowercased()
        }
    }

    /// A press released, and how long it was held. Main thread, from the
    /// same tap the keystrokes come from — so the release is already
    /// known to be a hand's, and already known not to be a repeat.
    func noteHold(_ seconds: Double, at now: Date = Date()) {
        guard enabled else { return }
        if let flushed = pulse.hold(seconds, at: now) {
            recordPulse(flushed)
        }
    }

    /// Shutdown: the open window's counts must not die with the process.
    func flush() {
        drainPending(all: true)
        if let final = pulse.flush() { recordPulse(final) }
        for event in clickPulse.flush() { observations?.clickPulse(event) }
        if let closed = window.close() { emit(closed) }
        keys.flushSync()
    }

    // MARK: - The mouse side

    /// Ferry the tap's counts into the pulses. A click younger than the
    /// return ceiling stays pending so the key that follows it can still
    /// join; a wheel burst stays open until its gap has passed. `all`
    /// closes everything — shutdown and the switch going off.
    private func drainPending(all: Bool = false) {
        let now = Date()
        lock.lock()
        // Everything is aged by its press's stamp, so a release or a
        // return never drains ahead of a click whose lookup is still in
        // flight: the three meet on the same side of the line.
        let holdClicks = all ? Date.distantFuture : now.addingTimeInterval(-PointerTracker.returnCeiling)
        let clicks = pendingClicks.filter { $0.at < holdClicks }
        pendingClicks.removeAll { $0.at < holdClicks }
        let releases = pendingReleases.filter { $0.downAt < holdClicks }
        pendingReleases.removeAll { $0.downAt < holdClicks }
        let returns = pendingReturns.filter { $0.downAt < holdClicks }
        pendingReturns.removeAll { $0.downAt < holdClicks }
        let scrollClose = all ? Date.distantFuture : now.addingTimeInterval(-HealthPulse.scrollBurstGap)
        let scrolls = pendingScrolls.filter { $0.last < scrollClose }
        pendingScrolls.removeAll { $0.last < scrollClose }
        lock.unlock()
        guard enabled || !(clicks.isEmpty && scrolls.isEmpty) else { return }
        let releaseByStamp = Dictionary(releases.map { ($0.downAt, $0.release) }, uniquingKeysWith: { a, _ in a })
        let returnByStamp = Dictionary(returns.map { ($0.downAt, $0.seconds) }, uniquingKeysWith: { a, _ in a })
        for click in clicks {
            if let flushed = pulse.click(at: click.at) { recordPulse(flushed) }
            // The pid becomes a name here, on the main thread, and only
            // the name travels: the same word the focus events use.
            let app = Self.appName(click.pid)
            for event in clickPulse.click(app: app, role: click.role, trip: click.trip,
                                          act: click.act, at: click.at) {
                observations?.clickPulse(event)
            }
            if let release = releaseByStamp[click.at] {
                for event in clickPulse.released(app: app, release, at: click.at) {
                    observations?.clickPulse(event)
                }
            }
            if let seconds = returnByStamp[click.at] {
                for event in clickPulse.returned(app: app, seconds: seconds, at: click.at) {
                    observations?.clickPulse(event)
                }
            }
        }
        for burst in scrolls {
            if let flushed = pulse.scroll(from: burst.start, to: burst.last) {
                recordPulse(flushed)
            }
            for event in clickPulse.scroll(app: Self.appName(burst.pid),
                                           seconds: burst.last.timeIntervalSince(burst.start),
                                           at: burst.start) {
                observations?.clickPulse(event)
            }
        }
    }

    private static func appName(_ pid: pid_t?) -> String {
        pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "unknown"
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        // A minute's cadence: pulses close on their own quarter-hour; this
        // just ferries the mouse side over and closes idle windows. It is
        // also the self-heal: a mouse tap that could not be created — the
        // first boot races the Accessibility grant — gets another try,
        // the same way the main tap's watchdog keeps trying.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.drainPending()
            // A window whose ninety seconds ran out with nobody typing
            // closes here, and the raw store writes what it has.
            if let closed = self.window.closeIfStale(now: Date()) { self.emit(closed) }
            self.keys.flush()
            if self.enabled, self.tap == nil, Permissions.isTrusted {
                self.tapThread = nil
                self.startMouseTap()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func startMouseTap() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
                | (1 << CGEventType.rightMouseUp.rawValue)
                | (1 << CGEventType.otherMouseUp.rawValue)
                | (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
                | (1 << CGEventType.rightMouseDragged.rawValue)
                | (1 << CGEventType.otherMouseDragged.rawValue)
                | (1 << CGEventType.scrollWheel.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HealthMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                monitor.sawMouse(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Log.error("health: could not create the mouse tap")
                return
            }
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "lodestar.health"
        thread.qualityOfService = .utility
        thread.start()
        tapThread = thread
    }

    private func stopMouseTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapThread = nil
    }

    /// Tap thread. Counts and times; the event passes untouched either way.
    private func sawMouse(type: CGEventType, event: CGEvent) {
        // The same two fields the coach trusts, for the same reason.
        guard Coach.isHumanOrigin(
            sourceStateID: event.getIntegerValueField(.eventSourceStateID),
            postingPID: event.getIntegerValueField(.eventSourceUnixProcessID)
        ) else { return }
        // The event's own stamp: the tap thread is quiet, but the stamp
        // is the hand's moment and the clock is the callback's.
        let now = EventTime.date(of: event) ?? Date()
        let location = event.location
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // The device's own counts, before the acceleration curve: the
            // profile is read from these, the path from the positions.
            tracker.moved(to: location,
                          dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                          dy: Double(event.getIntegerValueField(.mouseEventDeltaY)),
                          at: now)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let release = tracker.up(at: location, at: now), let down = lastDownAt {
                pendingReleases.append(PendingRelease(downAt: down, release: release))
            }
        case .scrollWheel:
            lastMouseAt = now
            // Coalesced at the source: hundreds of wheel events per flick
            // would otherwise cross threads for nothing. One burst is all
            // the pulse counts anyway; its length is what it times.
            if let open = pendingScrolls.last,
               now.timeIntervalSince(open.last) <= HealthPulse.scrollBurstGap {
                pendingScrolls[pendingScrolls.count - 1].last = now
            } else {
                pendingScrolls.append(PendingScroll(start: now, last: now, pid: nil))
                lookup.async { [weak self] in
                    guard let self else { return }
                    let pid = self.pid(at: location)
                    self.lock.lock()
                    if let index = self.pendingScrolls.firstIndex(where: { $0.start == now }) {
                        self.pendingScrolls[index].pid = pid
                    }
                    self.lock.unlock()
                }
            }
        default:
            let trip: Bool
            if let key = lastKeyAt { trip = key > (lastMouseAt ?? .distantPast) } else { trip = false }
            lastMouseAt = now
            lastDownAt = now
            let act = tracker.down(at: location, at: now)
            roads?.clicked(at: now)
            lookup.async { [weak self] in
                guard let self else { return }
                var element: AXUIElement?
                var pid: pid_t = 0
                var role: String?
                if AXUIElementCopyElementAtPosition(self.systemWide, Float(location.x),
                                                    Float(location.y), &element) == .success,
                   let element {
                    if AXUIElementGetPid(element, &pid) != .success { pid = 0 }
                    role = AX.string(element, kAXRoleAttribute)
                }
                self.lock.lock()
                self.pendingClicks.append(PendingClick(at: now, trip: trip,
                                                       pid: pid > 0 ? pid : nil, role: role,
                                                       act: act))
                self.lock.unlock()
            }
        }
    }

    /// Lookup queue. The app under a point, and nothing else about it.
    private func pid(at location: CGPoint) -> pid_t? {
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x),
                                               Float(location.y), &element) == .success,
              let element, AXUIElementGetPid(element, &pid) == .success, pid > 0
        else { return nil }
        return pid
    }
}
