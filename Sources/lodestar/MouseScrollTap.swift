import CoreGraphics
import Foundation
import LodestarCore

/// The Reversed wheels page's hands: a tap on scroll events alone, on a
/// thread of its own, that turns the vertical scroll of each source the
/// person ticked and lets every other scroll pass untouched. Active
/// (`defaultTap`) only while something is ticked; while the page is open
/// with nothing ticked it is listen-only and turns nothing, so that it can
/// hear which apps post a mouse's scrolls; otherwise there is none.
///
/// Every scroll on the machine waits on this callback, so it does what a
/// callback that cannot be allowed to stall does. It reads the recent wheel
/// reports and the ticked sources under a lock that is held for microseconds
/// by whoever takes it, turns three fields over, and returns. It never logs,
/// never asks LaunchServices who a pid is (the ticked apps' pids are kept
/// current off the callback and handed in with `set`), never touches the main
/// thread and never waits on anything. A stall here would be a stall in
/// every scroll, which is why it is not the key tap's job and shares no
/// thread with it. The one thing it says to the outside is that a source has
/// been seen, once each: an app posted a scroll, or a scroll was attributed
/// to a mouse by its wheel report. A page lists a mouse only then, so that a
/// mouse whose wheel an app swallows is never offered as a switch that
/// would do nothing.
///
/// It sits at the tail of the session taps. Health's listening tap is at
/// the head, so the record keeps what the fingers did, never what this
/// made of it.
final class MouseScrollTap {
    private let lock = NSLock()
    private var reports = MouseScroll.Reports()
    private var devices: Set<String> = []
    private var pids: Set<Int64> = []
    /// The apps that have posted a scroll, by pid, and the mice a scroll was
    /// attributed to, by roster id, each once since a page last took them.
    /// Bounded and made at their full size: past the limit the rest are
    /// forgotten, since a callback never grows a collection.
    private var posted: [Int64] = []
    private var attributed: [String] = []
    private static let noticedLimit = 16
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    /// What is running, as asked for with `run`.
    private var mode = WheelPlan.Tap.off
    /// Each start's token, moved on by every stop: a tap made after its
    /// start was stopped is dropped rather than kept, so two taps never
    /// run at once (two would turn the wheel back again).
    private var generation = 0
    private let ownPID = Int64(getpid())
    /// A source is new to `posted` or `attributed`. Called on the tap's
    /// thread outside the lock and only for one not seen since the last
    /// take, so it must do no more than hand the news on.
    private let noticed: () -> Void

    /// Whether a real tap may be made. A test run never makes one: it would
    /// turn the scrolling of the person at the desk.
    var canTap: () -> Bool = { !TestRun.active }

    init(noticed: @escaping () -> Void = {}) {
        self.noticed = noticed
        posted.reserveCapacity(Self.noticedLimit)
        attributed.reserveCapacity(Self.noticedLimit)
    }

    deinit { stop() }

    /// Whether a tap is running now, listening or turning.
    var isRunning: Bool { lock.withLock { tap != nil } }

    /// Any thread. A wheel of `device` (its roster id) turned at `stamp`, in
    /// nanoseconds of uptime. The listener's thread calls this for every
    /// report, so it does no more than file it.
    func hear(device: String, stamp: UInt64) {
        lock.withLock { reports.add(device: device, stamp: stamp) }
    }

    /// Main. The sources ticked: the mice by roster id, and the pids the
    /// ticked apps are running as now.
    func set(devices: Set<String>, pids: Set<Int64>) {
        lock.withLock {
            self.devices = devices
            self.pids = pids
        }
    }

    /// Any thread. The pids of the apps that posted a scroll, and the ids of
    /// the mice a scroll was attributed to, since this was last asked.
    func takeNoticed() -> (pids: [Int64], devices: [String]) {
        lock.withLock {
            defer {
                posted.removeAll(keepingCapacity: true)
                attributed.removeAll(keepingCapacity: true)
            }
            return (posted, attributed)
        }
    }

    /// Main. Make the tap match the plan: none, listen-only or turning.
    /// `isRunning` says whether it could be made, which the caller logs: a
    /// callback's file says nothing to the log.
    func run(_ wanted: WheelPlan.Tap) {
        guard wanted != lock.withLock({ mode }) else { return }
        stop()
        guard wanted != .off, canTap() else { return }
        start(wanted)
    }

    /// The callback's whole work: the event, turned over or not. Internal
    /// so a test can hand it an event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system turns a slow tap off; this one is never slow on its
            // own, and a scroll that went past unturned is the cost.
            if let port = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let poster = event.getIntegerValueField(.eventSourceUnixProcessID)
        let stamp = event.timestamp
        let (turn, fresh) = lock.withLock { () -> (Bool, Bool) in
            let source = MouseScroll.attribution(scrollPhase: phase, momentumPhase: momentum, postingPID: poster,
                                                 ownPID: ownPID, stamp: stamp, reports: reports)
            var fresh = false
            switch source {
            case .posted(let pid):
                if posted.count < Self.noticedLimit, !posted.contains(pid) {
                    posted.append(pid)
                    fresh = true
                }
            case .device(let id):
                if attributed.count < Self.noticedLimit, !attributed.contains(id) {
                    attributed.append(id)
                    fresh = true
                }
            case .touch, .own, .ambiguous, .unknown:
                break
            }
            return (MouseScroll.turns(source, devices: devices, pids: pids), fresh)
        }
        if fresh { noticed() }
        if turn { MouseScroll.reverseVertical(event) }
        return Unmanaged.passUnretained(event)
    }

    private func start(_ wanted: WheelPlan.Tap) {
        let mine = lock.withLock { () -> Int? in
            guard thread == nil else { return nil }
            generation += 1
            mode = wanted
            return generation
        }
        guard let mine else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer { ready.signal() }
            guard let self else { return }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseScrollTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: wanted == .turn ? .defaultTap : .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                self.lock.withLock {
                    if self.generation == mine {
                        self.thread = nil
                        self.mode = .off
                    }
                }
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            let current = self.lock.withLock { () -> Bool in
                guard self.generation == mine else { return false }
                self.tap = tap
                self.runLoop = loop
                return true
            }
            guard current else {
                // Stopped while it was being made: never enabled, never kept.
                CFMachPortInvalidate(tap)
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "lodestar.mouse-scroll.tap"
        // Every scroll waits on this thread, so it runs as the input does.
        thread.qualityOfService = .userInteractive
        lock.withLock { self.thread = thread }
        thread.start()
        // The tap exists before this returns, or it never will; a bounded
        // wait, since main must never hang on a thread it started.
        _ = ready.wait(timeout: .now() + 1)
    }

    private func stop() {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.tap = nil
                self.runLoop = nil
                self.thread = nil
                self.mode = .off
                self.generation += 1
            }
            return (self.tap, self.runLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
    }
}
