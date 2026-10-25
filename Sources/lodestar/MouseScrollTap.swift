import AppKit
import LodestarCore

/// app.mouse-scrolling's hands: an active tap on scroll events alone, on a
/// thread of its own, there only while the setting is not System. Every
/// scroll on the machine waits on its callback, so the callback reads two
/// values under a lock nobody holds for long and turns three fields over;
/// it never logs, reads a preference or touches the main thread. A stall
/// here would be a stall in every scroll, which is why it is not the key
/// tap's job and shares no thread with it.
///
/// It sits at the tail of the session taps. Health's listening tap is at
/// the head, so the record keeps what the fingers did, never what this
/// made of it.
final class MouseScrollTap {
    private let lock = NSLock()
    private var want = MouseScroll.Direction.system
    /// The Mac's own direction as last read, nil until then. The callback
    /// takes natural while it is unknown: that is the system's default.
    private var systemNatural: Bool?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    /// Each start's token, moved on by every stop: a tap made after its
    /// start was stopped is dropped rather than kept, so two taps never
    /// run at once (two would turn the wheel back again).
    private var generation = 0
    private let ownPID = Int64(getpid())

    /// A global-domain read waits on cfprefsd, and one on main never came
    /// back after a Bluetooth restart (the 2026-09-28 crash), so it is read
    /// here, on a queue of its own: when the tap starts, when System
    /// Settings says the direction changed, and every half minute while
    /// the tap runs. Replaced by the tests, from the start: the first read
    /// is asked for as the tap is made.
    var readNatural: () -> Bool
    static let systemRead: () -> Bool = {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                  kCFPreferencesAnyApplication) as? Bool ?? true
    }
    /// Whether a real tap may be made. A test run never makes one: it would
    /// turn the scrolling of the person at the desk.
    var canTap: () -> Bool = TestRun.active ? { false } : { Permissions.isTrusted }

    private let reads = DispatchQueue(label: "lodestar.mouse-scroll.direction", qos: .utility)
    private var reading = false
    private var poll: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    init(readNatural: @escaping () -> Bool = MouseScrollTap.systemRead) {
        self.readNatural = readNatural
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("SwipeScrollDirectionDidChangeNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        stop()
    }

    /// The Mac's own direction as last read, for the Settings row.
    var naturalScrolling: Bool? { lock.withLock { systemNatural } }

    /// Whether a tap is turning the wheel now.
    var isRunning: Bool { lock.withLock { tap != nil } }

    /// Main. The setting, from the config at launch and on every reload.
    func configure(_ direction: MouseScroll.Direction) {
        let changed = lock.withLock { () -> Bool in
            defer { want = direction }
            return want != direction
        }
        if direction == .system {
            stop()
        } else {
            start()
        }
        if changed { Log.info("mouse scrolling: \(direction.rawValue)") }
    }

    /// Any thread. Reads the Mac's direction on the queue; a read already
    /// under way answers for this one.
    func refresh() {
        let begin = lock.withLock { () -> Bool in
            guard !reading else { return false }
            reading = true
            return true
        }
        guard begin else { return }
        let read = readNatural
        reads.async { [weak self] in
            let natural = read()
            guard let self else { return }
            self.lock.withLock {
                self.systemNatural = natural
                self.reading = false
            }
        }
    }

    /// For the tests: every read asked for so far has landed.
    func drainForTesting() {
        reads.sync {}
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
        // Until the Mac's direction has been read, nothing is turned: a guess
        // would be the wrong way round on half of all Macs.
        let (direction, known) = lock.withLock { (want, systemNatural) }
        guard let natural = known else { return Unmanaged.passUnretained(event) }
        if MouseScroll.reverses(event, want: direction, systemNatural: natural, ownPID: ownPID) {
            MouseScroll.reverseVertical(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func start() {
        guard canTap() else { return }
        let mine = lock.withLock { () -> Int? in
            guard thread == nil else { return nil }
            generation += 1
            return generation
        }
        guard let mine else { return }
        refresh()
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
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Log.error("mouse scrolling: could not create the scroll tap")
                self.lock.withLock { if self.generation == mine { self.thread = nil } }
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

        let timer = DispatchSource.makeTimerSource(queue: reads)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poll = timer
    }

    private func stop() {
        poll?.cancel()
        poll = nil
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.tap = nil
                self.runLoop = nil
                self.thread = nil
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
