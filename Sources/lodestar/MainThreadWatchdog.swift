import Foundation
import LodestarCore

/// A crash is better than a freeze.
///
/// An input-path app has one failure it cannot recover from on its own: a
/// main thread that stops answering. The key tap runs there; when it
/// stops returning, the system switches the tap off, every gesture falls
/// through to the app in front, and nothing is logged, because nothing is
/// running. The one thing the system *does* recover from is a crash —
/// launchd relaunches within a second, the run marker records the death,
/// and macOS writes a report with every thread's stack, which is exactly
/// the diagnosis a freeze never leaves.
///
/// So a thread of its own pings main on a cadence and, when the pong does
/// not come back inside the ceiling, says so in the log and aborts. The
/// ceiling sits far past any legitimate main-thread work — a retile is
/// tens of milliseconds, the accessibility calls are off main already —
/// and an app that has held its main thread for that long is not going to
/// give it back.
final class MainThreadWatchdog {
    /// How often main is asked.
    let interval: TimeInterval
    /// How long main may take to answer before the process is given up.
    let ceiling: TimeInterval
    /// What happens on a stall. The default logs and aborts; a test
    /// substitutes a hook.
    var onStall: (TimeInterval) -> Void = { seconds in
        Log.error("main thread stalled", ["seconds": seconds,
                                          "action": "aborting so launchd relaunches; see the crash report"])
        abort()
    }

    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var answered = false

    init(interval: TimeInterval = 2, ceiling: TimeInterval = 8) {
        self.interval = interval
        self.ceiling = ceiling
    }

    func start() {
        guard thread == nil else { return }
        running = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "lodestar.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        thread = nil
    }

    private func loop() {
        while running {
            lock.lock()
            answered = false
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.answered = true
                self.lock.unlock()
            }
            // Wait for the pong in small steps, so a stop is honoured and
            // a prompt answer costs no more than the interval.
            let deadline = Date().addingTimeInterval(ceiling)
            var ok = false
            while running, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock()
                ok = answered
                lock.unlock()
                if ok { break }
            }
            guard running else { return }
            if !ok { onStall(ceiling) }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
