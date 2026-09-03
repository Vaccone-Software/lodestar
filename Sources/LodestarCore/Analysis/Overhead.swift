import Foundation

/// The product's own score: actual input cost against its computed floor,
/// per channel. The floor is a keystroke-level reading (Card, Moran &
/// Newell's KLM, priced with this user's own measured constants wherever
/// one exists), and the ratio is the fitness function every re-encoding
/// ultimately serves — a channel at 1.0 has nothing left to give, and
/// every point above it is backlog.
///
/// Read-time only, like every other view over the log: nothing here is
/// stored, judged, or surfaced anywhere but the printout that shows the
/// working. Channels the data cannot price honestly are omitted rather
/// than estimated into existence.
public struct Overhead: Equatable {
    /// KLM constants for acts the log counts but cannot time: homing
    /// (hand to mouse), pointing, and the button press. The one place a
    /// literature constant stands in for a measurement, and each line
    /// that leans on them says `measured: false`.
    public static let homingSeconds = 0.40
    public static let pointSeconds = 1.10
    public static let pressSeconds = 0.20
    /// A keyed act's floor: the keystrokes a compiled gesture needs (two
    /// of aim and one of commit — select's own arithmetic, and a graph
    /// chain's ceiling), at the hand's measured inter-key gap.
    public static let floorKeystrokes = 3.0
    /// A strip paste's floor: the strip opened and a label pressed.
    public static let pasteFloorKeystrokes = 2.0
    /// A strip open longer than this was a hunt through history, or an
    /// interruption, not a paste.
    static let pasteCeiling = 60.0
    /// A launcher search longer than this was an interruption, not a
    /// search; the chain gaps already carry their own ceiling.
    static let launcherCeiling = 30.0
    static let selectCeiling = 120.0

    public struct Channel: Equatable {
        public let name: String
        public let actsPerDay: Double
        public let actualSecondsPerDay: Double
        public let floorSecondsPerDay: Double
        /// True when the actual side was timed by the instrument; false
        /// when it is counts priced by KLM constants.
        public let measured: Bool

        public var ratio: Double? {
            floorSecondsPerDay > 0 ? actualSecondsPerDay / floorSecondsPerDay : nil
        }
    }

    /// One category of the pointing pool: an app and a role class, with
    /// the estimated seconds its clicks cost. The backlog query — what
    /// the mouse does that keys could learn, ranked by where the time is.
    public struct PoolEntry: Equatable {
        public let app: String
        public let role: String
        public let clicksPerDay: Double
        public let secondsPerDay: Double
    }

    public let channels: [Channel]

    /// Distinct local days among the stamps — the honest denominator for
    /// a channel that was not exercised every day of the window.
    static func activeDays(_ stamps: [Date]) -> Int {
        Set(stamps.map { Int($0.timeIntervalSince1970 / 86_400) }).count
    }

    public static func compute(events: [ObservationEvent], latency: LatencyModel?,
                               health: Health.Summary?, clicks: Health.Clicks?,
                               days: Int = 28, now: Date = Date()) -> Overhead {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let window = events.filter { $0.t >= cutoff }
        let interKey = health?.interKeyMean
        let keyedFloor = interKey.map { floorKeystrokes * $0 }
        var channels: [Channel] = []

        // Navigation: every completed chain at its measured gaps, every
        // launcher pick at its measured open-to-commit, against a floor
        // where each act is one bare-key gesture at this hand's own
        // trigger price. Any single letter prices the trigger — position
        // zero has no geometry — so "x" stands for them all.
        let triggerFloor = latency?.chainSeconds(["x"]) ?? 0.6
        var navActs = 0
        var navSeconds = 0.0
        var navStamps: [Date] = []
        for event in window {
            switch event.kind {
            case .chain:
                guard let gaps = event.gaps, !gaps.isEmpty else { continue }
                navActs += 1
                navSeconds += gaps.reduce(0) {
                    $0 + min(max(0, $1), Observations.recallCeiling)
                }
                navStamps.append(event.t)
            case .reach where event.route == "searcher":
                guard let commit = event.openToCommit, commit > 0 else { continue }
                navActs += 1
                navSeconds += min(commit, launcherCeiling)
                navStamps.append(event.t)
            default:
                continue
            }
        }
        let navDays = max(1, activeDays(navStamps))
        if navActs > 0 {
            channels.append(Channel(
                name: "navigation",
                actsPerDay: Double(navActs) / Double(navDays),
                actualSecondsPerDay: navSeconds / Double(navDays),
                floorSecondsPerDay: Double(navActs) * triggerFloor / Double(navDays),
                measured: true))
        }

        // Select: sessions at their measured seconds, against the keyed
        // floor. Needs the hand's inter-key gap; without it, silence.
        if let keyedFloor {
            var sessions = 0
            var seconds = 0.0
            var stamps: [Date] = []
            for event in window where event.kind == .select {
                guard let s = event.seconds, s > 0, s < selectCeiling else { continue }
                sessions += 1
                seconds += s
                stamps.append(event.t)
            }
            if sessions > 0 {
                let selectDays = max(1, activeDays(stamps))
                channels.append(Channel(
                    name: "select",
                    actsPerDay: Double(sessions) / Double(selectDays),
                    actualSecondsPerDay: seconds / Double(selectDays),
                    floorSecondsPerDay: Double(sessions) * keyedFloor / Double(selectDays),
                    measured: true))
            }
        }

        // Clipboard: every paste from the strip at its measured seconds
        // from open to paste, against two keystrokes at the hand's own
        // gap — the strip and a label. Abandons are not priced: a hunt
        // that found nothing is not a paste that took long.
        if let interKey {
            var pastes = 0
            var seconds = 0.0
            var stamps: [Date] = []
            for event in window where event.kind == .paste && event.action == "pasted" {
                guard let s = event.seconds, s > 0, s < pasteCeiling else { continue }
                pastes += 1
                seconds += s
                stamps.append(event.t)
            }
            if pastes > 0 {
                let pasteDays = max(1, activeDays(stamps))
                channels.append(Channel(
                    name: "clipboard",
                    actsPerDay: Double(pastes) / Double(pasteDays),
                    actualSecondsPerDay: seconds / Double(pasteDays),
                    floorSecondsPerDay: Double(pastes) * pasteFloorKeystrokes * interKey
                        / Double(pasteDays),
                    measured: true))
            }
        }

        // Typing: counts priced at the measured inter-key gap. The floor
        // strikes the correction loop — each backspace erases a character
        // that was typed and is itself a keystroke, so two keys of every
        // correction bought nothing. The ratio is the correction tax and
        // does not depend on the gap at all.
        if let health, let interKey, health.keys > 0, health.days > 0 {
            let healthDays = Double(health.days)
            let useful = max(0, health.keys - 2 * health.backspaces)
            channels.append(Channel(
                name: "typing",
                actsPerDay: Double(health.keys) / healthDays,
                actualSecondsPerDay: Double(health.keys) * interKey / healthDays,
                floorSecondsPerDay: Double(useful) * interKey / healthDays,
                measured: false))
        }

        // Pointing: clicks priced by KLM — a hand trip pays homing, the
        // point, and the press; an in-flow click pays point and press —
        // against the keyed floor, which is what the same act costs once
        // something like select has learned it.
        if let clicks, let keyedFloor, clicks.clicks > 0, clicks.days > 0 {
            let clickDays = Double(clicks.days)
            let inFlow = clicks.clicks - clicks.trips
            let actual = Double(clicks.trips) * (homingSeconds + pointSeconds + pressSeconds)
                + Double(inFlow) * (pointSeconds + pressSeconds)
            channels.append(Channel(
                name: "pointing",
                actsPerDay: Double(clicks.clicks) / clickDays,
                actualSecondsPerDay: actual / clickDays,
                floorSecondsPerDay: Double(clicks.clicks) * keyedFloor / clickDays,
                measured: false))
        }

        return Overhead(channels: channels)
    }

    /// The pointing pool ranked: app × role class by estimated cost, the
    /// standing answer to "what should the keyboard learn next". Roles do
    /// not carry their own trip counts, so every category is priced at
    /// the pool's overall trip share.
    public static func pointingBacklog(clicks: Health.Clicks, limit: Int = 6)
        -> [PoolEntry] {
        guard clicks.clicks > 0, clicks.days > 0 else { return [] }
        let tripShare = clicks.tripShare ?? 0
        let perClick = tripShare * (homingSeconds + pointSeconds + pressSeconds)
            + (1 - tripShare) * (pointSeconds + pressSeconds)
        let days = Double(clicks.days)
        var entries: [PoolEntry] = []
        for (app, record) in clicks.apps {
            for (role, count) in record.roles where role != ClickPulse.other {
                entries.append(PoolEntry(
                    app: app, role: role,
                    clicksPerDay: Double(count) / days,
                    secondsPerDay: Double(count) * perClick / days))
            }
        }
        return entries
            .sorted {
                $0.secondsPerDay > $1.secondsPerDay
                    || ($0.secondsPerDay == $1.secondsPerDay
                        && ($0.app, $0.role) < ($1.app, $1.role))
            }
            .prefix(limit)
            .map { $0 }
    }
}
