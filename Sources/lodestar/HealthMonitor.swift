import AppKit
import CoreGraphics
import LodestarCore

/// The hands' pulse, gathered: keystroke counts arrive from the main event
/// tap (which already sees every key), clicks and scroll bursts from a
/// listen-only tap of its own. All accumulation happens in `HealthPulse`
/// (core, tested); this class is the plumbing and the gate.
///
/// The mouse tap is `.listenOnly` on its own thread's run loop on purpose:
/// a listening tap cannot delay event delivery, so a busy main thread can
/// never turn health accounting into scroll jank — the batch this ships in
/// is partly *about* never standing in the input path.
///
/// Provenance discipline matches the coach's: only hardware-origin events
/// count. An agent driving the machine is not the user's hands, and a
/// health mirror that counted synthetic input would flatter exactly the
/// hours nobody was there.
final class HealthMonitor {
    /// Where pulses land. Set once at boot.
    var observations: ObservationStore?

    private var pulse = HealthPulse()
    private var enabled = false
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var flushTimer: Timer?

    /// Mouse-side counts cross from the tap thread through this lock; the
    /// main thread drains them into the pulse on its flush cadence.
    private let lock = NSLock()
    private var pendingClicks: [Date] = []
    private var pendingScrolls: [Date] = []

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
            drainPending()
            if let final = pulse.flush() { observations?.healthPulse(final) }
        }
    }

    /// A hardware keystroke, from the main tap. Main thread.
    func noteKey(backspace: Bool, at now: Date = Date()) {
        guard enabled else { return }
        if let flushed = pulse.key(at: now, backspace: backspace) {
            observations?.healthPulse(flushed)
        }
    }

    /// Shutdown: the open window's counts must not die with the process.
    func flush() {
        drainPending()
        if let final = pulse.flush() { observations?.healthPulse(final) }
    }

    // MARK: - The mouse side

    private func drainPending() {
        lock.lock()
        let clicks = pendingClicks
        let scrolls = pendingScrolls
        pendingClicks = []
        pendingScrolls = []
        lock.unlock()
        guard enabled || !(clicks.isEmpty && scrolls.isEmpty) else { return }
        for at in clicks {
            if let flushed = pulse.click(at: at) { observations?.healthPulse(flushed) }
        }
        for at in scrolls {
            if let flushed = pulse.scroll(at: at) { observations?.healthPulse(flushed) }
        }
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

    /// Tap thread. Counts only; the event passes untouched either way.
    private func sawMouse(type: CGEventType, event: CGEvent) {
        // The same two fields the coach trusts, for the same reason.
        guard Coach.isHumanOrigin(
            sourceStateID: event.getIntegerValueField(.eventSourceStateID),
            postingPID: event.getIntegerValueField(.eventSourceUnixProcessID)
        ) else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .scrollWheel:
            // Coalesced at the source: hundreds of wheel events per flick
            // would otherwise cross threads for nothing. One stamp per
            // burst is all the pulse counts anyway.
            if pendingScrolls.last.map({ now.timeIntervalSince($0)
                > HealthPulse.scrollBurstGap }) ?? true {
                pendingScrolls.append(now)
            } else {
                pendingScrolls[pendingScrolls.count - 1] = now
            }
        default:
            pendingClicks.append(now)
        }
    }
}
