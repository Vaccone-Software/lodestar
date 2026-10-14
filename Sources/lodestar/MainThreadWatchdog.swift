import Foundation
import LodestarCore
import Stoic

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
    /// What the default stall does. An abort and a launchd relaunch is the
    /// right answer to a freeze, and the wrong one in the middle of a
    /// crash loop: a relaunch that stalls again and is aborted again is
    /// the loop. In safe mode (see `LaunchGuard` in main) the stall is
    /// written down and the process left alone.
    enum Response: Equatable {
        case abort
        case logOnly
    }
    var response = Response.abort
    /// What happens on a stall; nil is the default, which follows
    /// `response`. A test substitutes a hook.
    var onStall: ((TimeInterval) -> Void)?
    /// Told after the default response has been carried out without
    /// ending the process (`.logOnly`); a test listens here to see that
    /// safe mode logged and lived.
    var onLogged: (() -> Void)?

    private func stalled(for seconds: TimeInterval) {
        if let onStall { onStall(seconds); return }
        switch response {
        case .abort:
            Log.error("main thread stalled", ["seconds": seconds,
                                              "action": "aborting so launchd relaunches; see the crash report"])
            abort()
        case .logOnly:
            Log.error("main thread stalled", ["seconds": seconds,
                                              "action": "safe mode: not aborting, the last launches did not finish"])
            onLogged?()
        }
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

    /// Time is measured on a clock that stands still while the Mac
    /// sleeps. On the wall clock (`Date`) a lid closed with a ping
    /// outstanding came back to an "eight seconds" that were hours, and
    /// the app aborted itself on waking; a clock set back or forward did
    /// the same. Injectable, so the decisions are tested without waiting.
    private let clock: AnyClock
    typealias Instant = AnyClock.Instant

    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var answeredAt: Instant?

    /// Asked every half second: a stall shorter than the gap between asks
    /// is caught only if it covers an ask, and the tap goes off in about
    /// a second.
    init(interval: TimeInterval = 0.5, ceiling: TimeInterval = 8, launchCeiling: TimeInterval = 60,
         lateThreshold: TimeInterval = 1, clock: AnyClock = .suspending) {
        self.clock = clock
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

    /// What one ask has come to, judged from the clock alone.
    enum Verdict: Equatable {
        /// No answer yet and time left.
        case waiting
        /// Answered; `late` is how long it took when that reached the
        /// late threshold.
        case answered(late: Duration?)
        /// No answer, and the allowance is spent.
        case stalled
    }

    static func judge(asked: Instant, now: Instant, answered: Instant?,
                      limit: Duration, lateThreshold: Duration) -> Verdict {
        if let answered {
            let took = asked.duration(to: answered)
            return .answered(late: took >= lateThreshold ? took : nil)
        }
        return asked.duration(to: now) >= limit ? .stalled : .waiting
    }

    private func loop() {
        var limit = launchCeiling
        var launching = true
        while running {
            lock.lock()
            answeredAt = nil
            lock.unlock()
            let asked = clock.now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.answeredAt = self.clock.now
                self.lock.unlock()
            }
            // Wait for the pong in small steps, so a stop is honoured and
            // a prompt answer costs no more than the interval.
            var verdict = Verdict.waiting
            while running, verdict == .waiting {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock()
                let answer = answeredAt
                lock.unlock()
                verdict = Self.judge(asked: asked, now: clock.now, answered: answer,
                                     limit: .seconds(limit), lateThreshold: .seconds(lateThreshold))
            }
            guard running else { return }
            switch verdict {
            case .stalled:
                stalled(for: limit)
            case .answered(let late?):
                onLate(TimeInterval(late.components.seconds) + TimeInterval(late.components.attoseconds) / 1e18,
                       launching)
            case .answered(nil), .waiting:
                break
            }
            limit = ceiling
            launching = false
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
