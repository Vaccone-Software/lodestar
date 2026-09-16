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
/// count as the hand's. An agent driving the machine is not the user's
/// hands, and a health mirror that counted synthetic input would flatter
/// exactly the hours nobody was there. Posted clicks — the click door's
/// own pointer walk first among them — are counted apart, as what the
/// tool did, never folded into what the hand did.
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
    /// The raw records beneath every summary — presses and reaches — and
    /// the window that describes ninety seconds of presses at a time.
    private let keys: KeyStore
    private let pointerStore: PointerStore
    private var window = HoldWindow()
    private let roster = KeyboardRoster()
    private let pointers = PointerRoster()
    private let eras = EraTracker()
    /// The focused element's role, sampled off the main thread when a
    /// window opens and read at its close: best effort, never waited on.
    private var sampledRole: String?
    /// The lid, read at most every half minute — an IORegistry call is
    /// cheap but not free, and a press must never wait on one.
    private var lidCached: Bool?
    private var lidAt = Date.distantPast
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)

    init() {
        let install = Install.id()
        keys = KeyStore(directory: Paths.data.appendingPathComponent(KeyStore.subdirectory, isDirectory: true),
                        installID: install)
        pointerStore = PointerStore(directory: Paths.data.appendingPathComponent(PointerStore.subdirectory, isDirectory: true),
                                    installID: install)
    }
    private var enabled = false
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var flushTimer: Timer?
    /// Force Touch: the trackpad's pressure stages, from a global
    /// monitor. Whether one arrives at all is the measurement — a mouse
    /// never sends one, so a press with a stage behind it was the
    /// trackpad's, and the first sample is logged so the field can say
    /// whether the monitor hears them.
    private var pressureMonitor: Any?
    private var pressureSamples = 0

    /// Mouse-side counts cross from the tap thread through this lock; the
    /// main thread drains them into the pulse on its flush cadence.
    private let lock = NSLock()
    private var pendingClicks: [PendingClick] = []
    private var pendingPosted: [Date] = []
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
    private var lastDownButton = 0
    /// The last pressure stage seen, for the click that follows it.
    private var lastPressure: (stage: Int, pressure: Double, at: Date)?
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
    /// pid is looked up once, at the burst's start. Precise deltas and
    /// momentum are facts about the whole burst: one event with either
    /// marks it.
    private struct PendingScroll {
        let start: Date
        var last: Date
        var pid: pid_t?
        var precise: Bool
        var momentum: Bool
        let device: PointerStore.DeviceKind
        let index: Int
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
            startPressureMonitor()
            startFlushTimer()
            checkEra()
        } else {
            stopMouseTap()
            stopPressureMonitor()
            flushTimer?.invalidate()
            flushTimer = nil
            drainPending(all: true)
            if let final = pulse.flush() { recordPulse(final) }
            for event in clickPulse.flush() { observations?.clickPulse(event) }
            if let closed = window.close() { emit(closed) }
            keys.flushSync()
            pointerStore.flushSync()
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

    /// A pulse closed: it leaves wearing the devices that were attached
    /// and whether the lid was down.
    private func recordPulse(_ event: ObservationEvent?) {
        guard var event else { return }
        event.keyboards = roster.ids
        event.pointers = pointers.ids
        event.lid = lidClosed()
        observations?.healthPulse(event)
    }

    /// A hardware press, complete: the raw store keeps it, the window
    /// describes it. Main thread. The shell adds what the tap could not
    /// know — which keyboard, by the roster and the lid — before either
    /// sees it.
    func notePress(_ press: KeyPress) {
        guard enabled else { return }
        var press = press
        let lid = lidClosed()
        press.lid = lid ?? false
        press.keyboard = roster.attribute(lidClosed: lid)
        keys.append(press, roster: roster.ids)
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
        stats.pointers = pointers.ids
        stats.power = Self.powerSource()
        stats.screens = NSScreen.screens.count
        stats.displays = Environment.displays()
        stats.lid = lidClosed()
        stats.layout = Environment.layoutID()
        stats.tz = TimeZone.current.secondsFromGMT(for: stats.start)
        lock.lock()
        stats.role = sampledRole
        sampledRole = nil
        lock.unlock()
        var event = ObservationEvent(t: stats.start, kind: .window)
        event.window = stats
        observations?.healthWindow(event)
    }

    /// The instrument's own state, written down when it differs from
    /// the last time it was. Main thread; at enable and once a minute.
    private func checkEra() {
        let info = EraInfo(appVersion: Lodestar.version, keySchema: Int(KeyStore.version),
                           pointerSchema: Int(PointerStore.version), layout: Environment.layoutID(),
                           keyboards: roster.ids, pointers: pointers.ids,
                           displays: Environment.displays(), settings: Environment.inputSettings(),
                           lid: lidClosed())
        if let event = eras.check(info) {
            Log.info("health: era", ["reason": event.era?.reason ?? "?", "version": info.appVersion])
            observations?.era(event)
        }
    }

    /// The lid, cached for half a minute. Any thread.
    private func lidClosed(now: Date = Date()) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(lidAt) < DeviceRoster.cacheSeconds { return lidCached }
        lidCached = Lid.isClosed()
        lidAt = now
        return lidCached
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
        pointerStore.flushSync()
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
        let posted = pendingPosted
        pendingPosted.removeAll()
        let scrollClose = all ? Date.distantFuture : now.addingTimeInterval(-HealthPulse.scrollBurstGap)
        let scrolls = pendingScrolls.filter { $0.last < scrollClose }
        pendingScrolls.removeAll { $0.last < scrollClose }
        lock.unlock()
        guard enabled || !(clicks.isEmpty && scrolls.isEmpty && posted.isEmpty) else { return }
        let releaseByStamp = Dictionary(releases.map { ($0.downAt, $0.release) }, uniquingKeysWith: { a, _ in a })
        let returnByStamp = Dictionary(returns.map { ($0.downAt, $0.seconds) }, uniquingKeysWith: { a, _ in a })
        for at in posted {
            if let flushed = pulse.postedClick(at: at) { recordPulse(flushed) }
        }
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
            if let flushed = pulse.scroll(from: burst.start, to: burst.last,
                                          precise: burst.precise, momentum: burst.momentum) {
                recordPulse(flushed)
            }
            for event in clickPulse.scroll(app: Self.appName(burst.pid),
                                           seconds: burst.last.timeIntervalSince(burst.start),
                                           at: burst.start) {
                observations?.clickPulse(event)
            }
            pointerStore.append(.scroll(start: burst.start,
                                        seconds: burst.last.timeIntervalSince(burst.start),
                                        precise: burst.precise, momentum: burst.momentum,
                                        device: burst.device, index: burst.index),
                                roster: pointers.ids)
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
            // closes here, and the raw stores write what they have.
            if let closed = self.window.closeIfStale(now: Date()) { self.emit(closed) }
            self.keys.flush()
            self.pointerStore.flush()
            self.checkEra()
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

    /// Main thread. Whether a global monitor hears pressure events at all
    /// is not documented; the first one that arrives says so in the log.
    private func startPressureMonitor() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = NSEvent.addGlobalMonitorForEvents(matching: .pressure) { [weak self] event in
            guard let self else { return }
            let at = event.cgEvent.flatMap(EventTime.date(of:)) ?? Date()
            self.lock.lock()
            self.lastPressure = (Int(event.stage), Double(event.pressure), at)
            self.pressureSamples += 1
            let first = self.pressureSamples == 1
            self.lock.unlock()
            if first { Log.info("health: force touch samples arriving") }
        }
    }

    private func stopPressureMonitor() {
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        pressureMonitor = nil
    }

    /// The pointing device a press was on, and which roster entry: the
    /// trackpad when a pressure stage preceded it or nothing external
    /// is attached; the one external device when there is exactly one;
    /// otherwise unknown, said plainly.
    private func device(pressureAt: Date?, now: Date) -> (kind: PointerStore.DeviceKind, index: Int) {
        let lid = lidClosed(now: now)
        if let pressureAt, now.timeIntervalSince(pressureAt) <= 0.5 {
            return (.trackpad, pointers.attribute(lidClosed: lid, builtIn: true))
        }
        let devices = pointers.current(now: now)
        let external = devices.filter { !$0.builtIn }
        if external.isEmpty, !devices.isEmpty {
            return (.trackpad, pointers.attribute(lidClosed: lid, builtIn: true))
        }
        if external.count == 1 {
            return (.mouse, pointers.attribute(lidClosed: lid, builtIn: false))
        }
        return (.unknown, 0)
    }

    private static let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// Tap thread. Counts and times; the event passes untouched either way.
    private func sawMouse(type: CGEventType, event: CGEvent) {
        // The event's own stamp: the tap thread is quiet, but the stamp
        // is the hand's moment and the clock is the callback's.
        let now = EventTime.date(of: event) ?? Date()
        let postingPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        // The same two fields the coach trusts, for the same reason.
        guard Coach.isHumanOrigin(sourceStateID: event.getIntegerValueField(.eventSourceStateID),
                                  postingPID: postingPID) else {
            // Not the hand's. A posted press is still counted — as the
            // tool's, apart from the hand's — and written down with who
            // posted it, so the pointer load can be read either way.
            guard Self.downTypes.contains(type) else { return }
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            lock.lock()
            pendingPosted.append(now)
            lock.unlock()
            pointerStore.append(.click(at: now, button: button,
                                       source: postingPID == ownPID ? .lodestar : .posted,
                                       device: .unknown, index: 0, stage: 0, pressure: 0),
                                roster: pointers.ids)
            return
        }
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
                pointerStore.append(.release(at: now, button: lastDownButton, press: release.press),
                                    roster: pointers.ids)
            }
        case .scrollWheel:
            lastMouseAt = now
            let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            // Coalesced at the source: hundreds of wheel events per flick
            // would otherwise cross threads for nothing. One burst is all
            // the pulse counts anyway; its length is what it times.
            if let open = pendingScrolls.last,
               now.timeIntervalSince(open.last) <= HealthPulse.scrollBurstGap {
                let index = pendingScrolls.count - 1
                pendingScrolls[index].last = now
                pendingScrolls[index].precise = pendingScrolls[index].precise || precise
                pendingScrolls[index].momentum = pendingScrolls[index].momentum || momentum
            } else {
                // A wheel's notches are not precise; a trackpad's or a
                // Magic Mouse's deltas are, and both are the built-in
                // kind of act when nothing else could have made it.
                let on = device(pressureAt: precise ? now : nil, now: now)
                pendingScrolls.append(PendingScroll(start: now, last: now, pid: nil,
                                                    precise: precise, momentum: momentum,
                                                    device: on.kind, index: on.index))
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
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            lastDownButton = button
            let act = tracker.down(at: location, at: now)
            roads?.clicked(at: now)
            // The raw record: the reach that ended here, then the press.
            if let motion = act.motion, let start = motion.origin, motion.count > 0 {
                pointerStore.append(.reach(start: start, screen: Environment.screenIndex(of: location),
                                           samples: motion.samples, end: now),
                                    roster: pointers.ids)
            }
            let pressure = lastPressure
            let on = device(pressureAt: pressure?.at, now: now)
            let staged = pressure.map { now.timeIntervalSince($0.at) <= 0.5 } ?? false
            pointerStore.append(.click(at: now, button: button, source: .human,
                                       device: on.kind, index: on.index,
                                       stage: staged ? (pressure?.stage ?? 0) : 0,
                                       pressure: staged ? (pressure?.pressure ?? 0) : 0),
                                roster: pointers.ids)
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
