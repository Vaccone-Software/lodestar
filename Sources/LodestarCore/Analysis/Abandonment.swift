import Foundation

/// Where effort leaked: each surface a gesture opens, the share of its
/// openings that ended in nothing, and the seconds those endings cost.
/// Every surface already logs its own giving-up — the launcher's abandon,
/// a nav chain hovered and dropped, a select or a paste left unread, a
/// draft that landed no words — but scattered across five event kinds and
/// summed nowhere. This is the standing answer to "what is being started
/// and not finished," priced the one way the log can: in the seconds the
/// instrument actually timed.
///
/// Read-time only, like the overhead beside it: nothing here is stored or
/// judged. A surface whose abandons carry no timing (the launcher does not
/// stamp its open seconds) reports the count and leaves the seconds at
/// zero rather than inventing them.
public struct Abandonment: Equatable {
    public struct Surface: Equatable {
        public let name: String
        /// Openings that produced their result.
        public let finished: Int
        /// Openings that ended in nothing.
        public let abandoned: Int
        /// Seconds spent in the abandoned openings, where the surface
        /// timed them; zero where it counts but does not time.
        public let secondsWasted: Double
        /// True when `secondsWasted` was timed rather than left at zero.
        public let timed: Bool

        public var opened: Int { finished + abandoned }
        public var rate: Double? {
            opened > 0 ? Double(abandoned) / Double(opened) : nil
        }
    }

    public let surfaces: [Surface]
    public let days: Int

    /// Total seconds a day spent on openings that produced nothing.
    public var wastedSecondsPerDay: Double {
        surfaces.reduce(0) { $0 + $1.secondsWasted } / Double(max(1, days))
    }

    public static func compute(events: [ObservationEvent], days: Int = 28,
                               now: Date = Date()) -> Abandonment {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let window = events.filter { $0.t >= cutoff }
        var stamps: Set<Int> = []

        // Counters per surface: finished, abandoned, wasted seconds.
        var navDone = 0, navGaveUp = 0; var navSeconds = 0.0
        var searchDone = 0, searchGaveUp = 0
        var selectDone = 0, selectGaveUp = 0; var selectSeconds = 0.0
        var pasteDone = 0, pasteGaveUp = 0; var pasteSeconds = 0.0
        var draftDone = 0, draftGaveUp = 0; var draftSeconds = 0.0

        for event in window {
            switch event.kind {
            case .chain:
                navDone += 1
                stamps.insert(day(event.t))
            case .abandon:
                navGaveUp += 1
                navSeconds += min(max(0, event.hover ?? 0), Observations.recallCeiling)
                stamps.insert(day(event.t))
            case .reach where event.route == "searcher":
                searchDone += 1
                stamps.insert(day(event.t))
            case .launcherAbandon:
                searchGaveUp += 1
                stamps.insert(day(event.t))
            case .select:
                guard let s = event.seconds, s >= 0, s < Overhead.selectCeiling else { continue }
                if event.action == "completed" { selectDone += 1 }
                else { selectGaveUp += 1; selectSeconds += s }
                stamps.insert(day(event.t))
            case .paste:
                guard let s = event.seconds, s >= 0, s < Overhead.pasteCeiling else { continue }
                if event.action == "abandoned" { pasteGaveUp += 1; pasteSeconds += s }
                else { pasteDone += 1 }
                stamps.insert(day(event.t))
            case .draft where event.source == "speak":
                guard let s = event.seconds, s >= 0, s < Overhead.draftCeiling else { continue }
                if event.action == "empty" || event.action == "cancelled" {
                    draftGaveUp += 1; draftSeconds += s
                } else {
                    draftDone += 1
                }
                stamps.insert(day(event.t))
            default:
                continue
            }
        }

        var surfaces: [Surface] = []
        func add(_ name: String, _ done: Int, _ gaveUp: Int, _ seconds: Double, timed: Bool) {
            guard done + gaveUp > 0 else { return }
            surfaces.append(Surface(name: name, finished: done, abandoned: gaveUp,
                                    secondsWasted: seconds, timed: timed))
        }
        add("dictation", draftDone, draftGaveUp, draftSeconds, timed: true)
        add("select", selectDone, selectGaveUp, selectSeconds, timed: true)
        add("clipboard", pasteDone, pasteGaveUp, pasteSeconds, timed: true)
        add("navigation", navDone, navGaveUp, navSeconds, timed: true)
        add("launcher", searchDone, searchGaveUp, 0, timed: false)

        return Abandonment(
            surfaces: surfaces.sorted {
                $0.secondsWasted > $1.secondsWasted
                    || ($0.secondsWasted == $1.secondsWasted && $0.abandoned > $1.abandoned)
                    || ($0.secondsWasted == $1.secondsWasted && $0.abandoned == $1.abandoned
                        && $0.name < $1.name)
            },
            days: max(1, stamps.count))
    }

    private static func day(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 86_400) }
}
