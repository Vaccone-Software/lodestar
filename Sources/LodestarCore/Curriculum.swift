import Foundation

/// The first weeks, one lesson at a time.
///
/// The walk teaches three things and stops: the key, the launcher, a few
/// letters. Everything else Lodestar can do is taught later, by the same
/// companion card, one gesture at a time, on a calendar the hand sets.
/// A lesson is due when the record is old enough for it, the gesture has
/// never once fired, the walk is finished, and nothing else was offered
/// in the last couple of days. A lesson passed over retries once, days
/// later, then parks for good; a gesture the hand found on its own is
/// never taught. The coach's ledger cannot carry this — its evidence is a
/// felt cost measured in seconds, and a feature never used has cost
/// nothing yet — so the curriculum keeps its own small record, in the
/// machine-owned state beside the walk's.
public enum Curriculum {
    public enum Lesson: String, CaseIterable, Codable, Equatable {
        case inside, web, clipboard, sheet, draft, select, commands, scroll
    }

    public struct Record: Codable, Equatable {
        public var offers: Int
        public var lastOfferedAt: Date?
        public var completedAt: Date?

        public init(offers: Int = 0, lastOfferedAt: Date? = nil, completedAt: Date? = nil) {
            self.offers = offers
            self.lastOfferedAt = lastOfferedAt
            self.completedAt = completedAt
        }
    }

    /// The order lessons arrive in, the verb the record counts each under
    /// (nil when only the card's own signal can prove it), and the day
    /// after the record began that each becomes due.
    public struct Entry {
        public let lesson: Lesson
        public let verb: String?
        public let day: Int
    }

    public static let order: [Entry] = [
        Entry(lesson: .inside, verb: "hints", day: 2),
        Entry(lesson: .web, verb: "web", day: 4),
        Entry(lesson: .clipboard, verb: "clipboard", day: 6),
        Entry(lesson: .sheet, verb: "cheat", day: 8),
        Entry(lesson: .draft, verb: "draft", day: 11),
        Entry(lesson: .select, verb: "select", day: 14),
        Entry(lesson: .commands, verb: "menu", day: 17),
        Entry(lesson: .scroll, verb: "scroll", day: 20),
    ]

    /// Days between any two lessons, whatever their own schedule says.
    public static let spacingDays = 2
    /// Days before a lesson passed over is offered again.
    public static let retryDays = 5
    /// Offers before a lesson parks for good.
    public static let maxOffers = 2

    public static func position(of lesson: Lesson) -> (Int, Int) {
        let index = order.firstIndex { $0.lesson == lesson } ?? 0
        return (index + 1, order.count)
    }

    /// The lesson due now, if any.
    ///
    /// - `since`: when the record began, which is when Lodestar first ran.
    /// - `verbsLastUsed`: the record's stamp per verb; a stamp at all means
    ///   the hand found the gesture itself.
    /// - `walkDone`: the day-one walk is finished. Lessons wait for it.
    public static func next(now: Date, since: Date, verbsLastUsed: [String: Date],
                            records: [Lesson: Record], walkDone: Bool) -> Lesson? {
        guard walkDone, since != .distantPast else { return nil }
        let lastOffer = records.values.compactMap(\.lastOfferedAt).max()
        if let lastOffer, now.timeIntervalSince(lastOffer) < Double(spacingDays) * 86_400 {
            return nil
        }
        for entry in order {
            let record = records[entry.lesson] ?? Record()
            if record.completedAt != nil { continue }
            if let verb = entry.verb, verbsLastUsed[verb] != nil { continue }
            if record.offers >= maxOffers { continue }
            if now.timeIntervalSince(since) < Double(entry.day) * 86_400 { continue }
            if let offered = record.lastOfferedAt,
               now.timeIntervalSince(offered) < Double(retryDays) * 86_400 { continue }
            return entry.lesson
        }
        return nil
    }

    public static func offered(_ record: Record?, at now: Date) -> Record {
        var out = record ?? Record()
        out.offers += 1
        out.lastOfferedAt = now
        return out
    }

    public static func completed(_ record: Record?, at now: Date) -> Record {
        var out = record ?? Record()
        out.completedAt = now
        return out
    }
}
