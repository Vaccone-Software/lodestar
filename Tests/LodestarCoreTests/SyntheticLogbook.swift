import Foundation
@testable import LodestarCore

/// A logbook that is the same every run: the tests that prove a read or a
/// roll unchanged compare its answers with the old path's, and a stream that
/// moved between runs could hide a difference in the noise.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }
}

enum SyntheticLogbook {
    /// Names that differ by case, an empty one and a missing one, because
    /// the model lowercases and skips what has no name.
    static let apps = ["Brave Browser", "brave browser", "Ghostty", "Slack", "Mail", "Xcode",
                       "Finder", "Claude", "Messages", "Notes", "Zoom", "Preview"]

    static func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// `perDay` events a day for `days` days from `start`, of every kind a
    /// logbook holds, a tenth of them appended a place late (the writers
    /// flush in batches, so a ring is nearly ordered and not quite).
    static func events(from start: Date, days: Int, perDay: Int, seed: UInt64 = 7) -> [ObservationEvent] {
        var random = SeededRandom(seed)
        var out: [ObservationEvent] = []
        var habit = Habit()
        let step = 86_400.0 / Double(perDay)
        for day in 0..<days {
            for slot in 0..<perDay {
                let t = start.addingTimeInterval(Double(day) * 86_400 + Double(slot) * step
                    + Double(random.below(1000)) / 1000)
                out.append(event(at: t, &random, &habit))
            }
        }
        var index = 1
        while index < out.count {
            if random.below(10) == 0 { out.swapAt(index - 1, index) }
            index += 1
        }
        return out
    }

    /// Where the hand goes next: mostly the usual successor of the app it is
    /// on, often back to the one before, and now and then anywhere, so the
    /// model has a stream to learn and the grid a best cell to find.
    struct Habit {
        var last = 0
        var before = 1
    }

    private static func event(at t: Date, _ random: inout SeededRandom, _ habit: inout Habit) -> ObservationEvent {
        let roll = random.below(20)
        switch roll {
        case 0..<10:
            var event = ObservationEvent(t: t, kind: .focus)
            let pick = random.below(60)
            if pick == 0 { event.app = nil } else if pick == 1 { event.app = "" } else {
                let way = random.below(100)
                let next = way < 50 ? (habit.last * 5 + 3) % apps.count
                    : way < 75 ? habit.before : random.below(apps.count)
                habit = Habit(last: next, before: habit.last)
                event.app = apps[next]
            }
            event.route = random.below(2) == 0 ? "chain" : "switcher"
            event.pulled = random.below(5) == 0 ? true : nil
            return event
        case 10:
            var event = ObservationEvent(t: t, kind: .chain)
            event.chain = ["b", "p"]
            event.gaps = [0.3 + Double(random.below(50)) / 100, 0.1]
            event.peeked = random.below(4) == 0
            return event
        case 11:
            var event = ObservationEvent(t: t, kind: .abandon)
            event.chain = ["b"]
            event.hover = Double(random.below(40)) / 10
            return event
        case 12:
            var event = ObservationEvent(t: t, kind: .reach)
            event.app = apps[random.below(apps.count)]
            event.route = ["graph", "searcher", "chord"][random.below(3)]
            event.openToCommit = Double(random.below(30)) / 10
            return event
        case 13:
            var event = ObservationEvent(t: t, kind: .verb)
            event.verb = ["scroll", "hints", "graph"][random.below(3)]
            return event
        case 14:
            var event = ObservationEvent(t: t, kind: .web)
            event.host = ["github.com", "example.com"][random.below(2)]
            event.profile = "brave:Work"
            event.source = "typed"
            event.row = "link"
            return event
        case 15, 16:
            var event = ObservationEvent(t: t, kind: .pulse)
            event.activeMinutes = 1 + random.below(14)
            event.keys = 100 + random.below(400)
            event.backspaces = random.below(30)
            event.clicks = random.below(20)
            event.ikN = 90
            event.ikSum = 16.5
            event.ikSumSq = 3.9
            event.boutIndex = random.below(6) == 0 ? 0 : 1 + random.below(8)
            event.boutSeconds = Double(random.below(3000))
            return event
        case 17:
            return ObservationEvent(t: t, kind: .window)
        case 18:
            var event = ObservationEvent(t: t, kind: .clicks)
            event.app = apps[random.below(apps.count)]
            event.clicks = 1 + random.below(30)
            event.trips = random.below(10)
            return event
        default:
            var event = ObservationEvent(t: t, kind: .latency)
            event.verb = "scroll-panes"
            event.seconds = Double(random.below(100)) / 1000
            return event
        }
    }

    /// The seconds either side of each month's turn, with what a month's
    /// end and its next beginning do to a fold: focus that straddles it,
    /// a pulse stretch that runs over it, a bout that is still open, and
    /// two events at one instant.
    static func boundaryEvents(monthStarts: [Date]) -> [ObservationEvent] {
        var out: [ObservationEvent] = []
        for (offset, start) in monthStarts.enumerated() {
            func focus(_ app: String, _ seconds: Double) -> ObservationEvent {
                var event = ObservationEvent(t: start.addingTimeInterval(seconds), kind: .focus)
                event.app = app
                return event
            }
            func pulse(_ seconds: Double, bout: Int) -> ObservationEvent {
                var event = ObservationEvent(t: start.addingTimeInterval(seconds), kind: .pulse)
                event.activeMinutes = 9
                event.boutIndex = bout
                event.boutSeconds = Double(bout) * 900
                return event
            }
            out.append(focus("Boundary A\(offset % 2)", -2))
            out.append(focus("Boundary B\(offset % 2)", -1))
            // The month's last two pulses, then a gap longer than a stretch
            // allows before the next month's first: that first pulse closes a
            // stretch that lives in the month before it.
            out.append(pulse(-3000, bout: 3))
            out.append(pulse(-2100, bout: 4))
            // Two focuses at one instant, two apps: the order they were
            // appended in is the order the fold sees.
            out.append(focus("Tie First", 0))
            out.append(focus("Tie Second", 0))
            // The first pulse of the new month starts a bout, which ends the
            // one the old month left open.
            out.append(pulse(60, bout: 0))
            out.append(pulse(2_400, bout: 0))
            out.append(focus("Boundary A\(offset % 2)", 3))
            // Two pulses at one instant, the later bout first: a bout that
            // closes at one and not the other depends on which is folded first.
            out.append(pulse(900, bout: 7))
            out.append(pulse(900, bout: 0))
        }
        return out
    }
}
