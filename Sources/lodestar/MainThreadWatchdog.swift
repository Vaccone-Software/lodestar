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
    /// The first answer's allowance. The watchdog starts inside
    /// `applicationDidFinishLaunching`, so its first ping cannot be
    /// answered until launch returns, and launch is not "legitimate work
    /// of tens of milliseconds": it asks every app for its windows. After
    /// a crash launches measured about 7 s, and under 0.35.2 two in a row
    /// took past 8 and were killed before they finished, a crash loop the
    /// watchdog made. A launch that never returns is still caught.
    let launchCeiling: TimeInterval
    /// What happens on a stall. The default logs and aborts; a test
    /// substitutes a hook.
    var onStall: (TimeInterval) -> Void = { seconds in
        Log.error("main thread stalled", ["seconds": seconds,
                                          "action": "aborting so launchd relaunches; see the crash report"])
        abort()
    }

    /// An answer this late is not a freeze, but it is long enough for the
    /// system to switch the key tap off, and keystrokes fall through to
    /// the app in front. Four times in a week the log said only "tap had
    /// stopped", right after a select or hints session, with nothing on
    /// what held main or for how long. A late answer is now written down,
    /// so a dropped keystroke has a duration and a neighbour in the log.
    let lateThreshold: TimeInterval
    /// What happens on a late answer, with how late and whether it was the
    /// launch's. The default logs; a test substitutes a hook.
    var onLate: (TimeInterval, Bool) -> Void = { seconds, launch in
        Log.error("main thread late", ["ms": Int(seconds * 1000), "during": launch ? "launch" : "run"])
    }

    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var answeredAt: Date?

    /// Asked every half second: a stall shorter than the gap between asks
    /// is caught only if it covers an ask, and the tap goes off in about
    /// a second.
    init(interval: TimeInterval = 0.5, ceiling: TimeInterval = 8, launchCeiling: TimeInterval = 60,
         lateThreshold: TimeInterval = 1) {
        self.interval = interval
        self.ceiling = ceiling
        self.launchCeiling = max(ceiling, launchCeiling)
        self.lateThreshold = lateThreshold
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
        var limit = launchCeiling
        var launching = true
        while running {
            lock.lock()
            answeredAt = nil
            lock.unlock()
            let asked = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.answeredAt = Date()
                self.lock.unlock()
            }
            // Wait for the pong in small steps, so a stop is honoured and
            // a prompt answer costs no more than the interval.
            let deadline = Date().addingTimeInterval(limit)
            var ok = false
            var answer: Date?
            while running, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock()
                answer = answeredAt
                lock.unlock()
                ok = answer != nil
                if ok { break }
            }
            guard running else { return }
            if !ok { onStall(limit) }
            if let answer, answer.timeIntervalSince(asked) >= lateThreshold {
                onLate(answer.timeIntervalSince(asked), launching)
            }
            limit = ceiling
            launching = false
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
