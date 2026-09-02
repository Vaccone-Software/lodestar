import AppKit
import LodestarCore

/// Predicted warming: the accessibility trees of the apps most likely to
/// be next are asked to stand *before* the switch, so the first text mode
/// after it — hints, select — finds a tree instead of building one.
///
/// The prediction is `NextApp`'s, learned from every focus change and
/// scored in shadow over the ring: the strategy and its tuning are
/// whatever measurably predicts this person best. The warming itself is
/// the cheapest act in the app — one attribute set per app, throttled to
/// one per half minute — and it is kept cheap three ways: it waits for
/// the hand to settle after a switch, so a burst of switches warms once;
/// it runs on a utility queue behind a short messaging timeout, so a hung
/// app costs a quarter second there and nothing on main; and it warms
/// only apps with a live window, so it never launches or wakes anything.
/// It records its own cost as a latency event when a batch was slow,
/// never otherwise, because the instrument observing itself must not
/// fill the ring with microseconds.
///
/// Two cadences, because the two costs differ: re-seeding the model from
/// the ring is one pass of dictionary increments and happens every half
/// hour; re-tuning scores every grid cell on every switch of the recent
/// stream (one pass, under a second on a fortnight of switches, plus a
/// second to score the strategies) and happens every six hours, since
/// the tuning barely moves from one day to the next.
final class Prewarmer {
    /// How long the hand must rest after a switch before warming: a
    /// glance loop switches back within a second, and the warmth is for
    /// the switch after the settled one.
    static let settle: TimeInterval = 0.4
    /// Apps warmed per switch. Measured on the stream this was built
    /// against, three predictions cover nine switches in ten.
    static let count = 3
    /// How often the model is re-seeded from the ring.
    static let seedInterval: TimeInterval = 30 * 60
    /// How often the blend is re-tuned and the strategies re-scored.
    static let tuneInterval: TimeInterval = 6 * 3600
    /// The boot seed waits this long, so the keyboard comes first.
    static let bootDelay: TimeInterval = 10
    /// A batch slower than this is written down; faster is the norm.
    static let slowBatch: TimeInterval = 0.05

    var observations: ObservationStore?
    /// App name (lowercased) → a pid with a live window, read on main.
    var runningApps: () -> [String: pid_t] = { [:] }

    private var model = NextApp()
    private var strategy: NextApp.Strategy = .blend
    private var tuning = NextApp.Tuning()
    private var pending: DispatchWorkItem?
    /// Stamped at init so the first refresh is the boot's, after its
    /// delay — not the first focus change during launch.
    private var seededAt = Date()
    private var tunedAt = Date.distantPast
    private var refreshing = false
    private let queue = DispatchQueue(label: "lodestar.prewarm", qos: .utility)

    /// What the warmer believes, for the log and any harness.
    private(set) var lastPredicted: [String] = []

    /// Focus landed: the model learns, and once the hand settles the
    /// predicted apps are warmed.
    func focused(app: String) {
        model.observe(app)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.warmPredicted() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
        if Date().timeIntervalSince(seededAt) >= Self.seedInterval { refresh() }
    }

    /// Seed the model from the ring after boot, then keep it tuned.
    func boot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootDelay) { [weak self] in
            self?.refresh()
        }
    }

    private func warmPredicted() {
        pending = nil
        let predicted = model.predict(strategy, k: Self.count)
        lastPredicted = predicted
        guard !predicted.isEmpty else { return }
        let running = runningApps()
        let pids = predicted.compactMap { running[$0] }
        guard !pids.isEmpty else { return }
        queue.async { [weak self] in
            let began = Date()
            var warmed = 0
            for pid in pids where AXWarmer.warm(pid) { warmed += 1 }
            let elapsed = Date().timeIntervalSince(began)
            guard warmed > 0, elapsed >= Self.slowBatch else { return }
            DispatchQueue.main.async {
                self?.observations?.latency(surface: "prewarm", seconds: elapsed)
            }
        }
    }

    /// Re-seed from the ring — and re-tune when that is due — off main.
    /// The live history since boot is replayed onto the seeded model so
    /// nothing learned today is lost to the refresh.
    func refresh() {
        guard !refreshing, let log = observations?.log else { return }
        refreshing = true
        seededAt = Date()
        let retune = Date().timeIntervalSince(tunedAt) >= Self.tuneInterval
        let current = tuning
        queue.async { [weak self] in
            let events = log.snapshot(days: EventLog.advisorWindowDays)
            let tuning = retune ? NextApp.tune(events: events) : current
            let scores = retune ? NextApp.evaluate(events: events, tuning: tuning) : []
            var seeded = NextApp(tuning: tuning)
            for event in events.filter({ $0.kind == .focus }).sorted(by: { $0.t < $1.t }) {
                if let app = event.app { seeded.observe(app) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for app in self.model.history { seeded.observe(app) }
                self.model = seeded
                self.tuning = tuning
                self.refreshing = false
                guard retune else { return }
                self.tunedAt = Date()
                self.strategy = NextApp.best(scores)
                if let chosen = scores.first(where: { $0.strategy == self.strategy }) {
                    Log.info("prewarm", [
                        "strategy": self.strategy.rawValue,
                        "switches": "\(chosen.switches)",
                        "hit3": String(format: "%.0f%%", chosen.hits[2] * 100),
                    ])
                }
            }
        }
    }
}
