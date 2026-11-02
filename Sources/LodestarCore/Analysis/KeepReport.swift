import Foundation

/// Where Keep, the clipboard strip, loses its openings. The abandonment
/// line says how many strip openings ended in nothing; this says what the
/// hand was doing when it left, from the same `.paste` events and nothing
/// new: a look with no key at all, a search typed and dropped, a card
/// named whose panel never acted, or some other key that led nowhere.
///
/// It counts the events the abandonment line counts (a strip open under a
/// minute), so the two never disagree about how many openings there were.
/// Read-time only, like the rest of the analysis: nothing here is stored,
/// and there is no clip in the events to print.
public struct KeepReport: Equatable {
    public struct Landing: Equatable {
        public let app: String
        public let count: Int
    }

    public let days: Int
    public let opens: Int
    public let pasted: Int
    public let acted: Int
    public let abandoned: Int
    /// What the panel verbs were, for the openings that ended in one.
    public let actedVerbs: [String: Int]

    /// How the pastes were addressed, and in what form.
    public let byLabel: Int
    public let byKeepsake: Int
    public let bySearch: Int
    public let plain: Int
    public let native: Int
    public let reading: Int

    /// Label pastes by the card's rank (0 the newest, on J), always as many as
    /// there are labels, and by keepsake slot (1 through the slot count).
    public let labelRanks: [Int]
    public let slots: [Int]

    /// An abandoned opening, told by the furthest the hand got. The four
    /// add up to `abandoned`.
    public let lookedAndLeft: Int
    public let typedAndLeft: Int
    public let namedAndLeft: Int
    public let otherKeyAndLeft: Int

    /// Median seconds open, and the median wait to the first key.
    public let abandonedSeconds: Double?
    public let pastedSeconds: Double?
    public let pastedFirstKey: Double?

    /// The search: openings that used one, how each ended, how many cards
    /// answered, and how far down the history the pasted ones were.
    public let searchPasted: Int
    public let searchActed: Int
    public let searchLeft: Int
    public let medianMatches: Double?
    public let depthOnShow: Int
    public let depthBeyond: Int
    public let medianDepth: Double?

    /// Where pastes landed, most first.
    public let apps: [Landing]

    public var perDay: Double { Double(opens) / Double(max(1, days)) }
    public var searches: Int { searchPasted + searchActed + searchLeft }

    /// Nil when the strip was not opened in the window.
    public static func compute(events: [ObservationEvent], days: Int = 28, now: Date = Date(),
                               calendar: Calendar = .current) -> KeepReport? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let opens = events.filter {
            guard $0.kind == .paste, $0.t >= cutoff,
                  let seconds = $0.seconds, seconds >= 0, seconds < Overhead.pasteCeiling
            else { return false }
            return true
        }
        guard !opens.isEmpty else { return nil }

        let pastes = opens.filter { $0.action == "pasted" }
        let acts = opens.filter { $0.action == "acted" }
        let left = opens.filter { $0.action != "pasted" && $0.action != "acted" }

        var verbs: [String: Int] = [:]
        for event in acts { verbs[event.row ?? "other", default: 0] += 1 }

        var labelRanks = Array(repeating: 0, count: Clipboard.recentLabels.count)
        var slots = Array(repeating: 0, count: Clipboard.pinSlots)
        for event in pastes {
            guard let rank = event.rank else { continue }
            if event.source == "pin", rank >= 1, rank <= slots.count {
                slots[rank - 1] += 1
            } else if event.source == "label", rank >= 0, rank < labelRanks.count {
                labelRanks[rank] += 1
            }
        }

        // The furthest the hand got, in the order a hand gets there: a key
        // of any kind, then a typed search, then a card named.
        var looked = 0, typed = 0, named = 0, other = 0
        for event in left {
            if event.openToFirstKey == nil { looked += 1 }
            else if event.source != nil { named += 1 }
            else if (event.typed ?? 0) > 0 { typed += 1 }
            else { other += 1 }
        }

        let searchOpens = opens.filter { $0.source == "search" || ($0.typed ?? 0) > 0 }
        let searchPastes = searchOpens.filter { $0.action == "pasted" }
        let shown = Clipboard.recentLabels.count
        let depths = searchPastes.compactMap(\.depth)

        var landed: [String: Int] = [:]
        for event in pastes { landed[event.app ?? "unknown", default: 0] += 1 }

        func median(_ values: [Double?]) -> Double? { Maths.median(values.compactMap { $0 }) }

        return KeepReport(
            days: max(1, Set(opens.map { DayFile.day(of: $0.t, calendar: calendar) }).count),
            opens: opens.count, pasted: pastes.count, acted: acts.count, abandoned: left.count,
            actedVerbs: verbs,
            byLabel: pastes.filter { $0.source == "label" }.count,
            byKeepsake: pastes.filter { $0.source == "pin" }.count,
            bySearch: pastes.filter { $0.source == "search" }.count,
            plain: pastes.filter { $0.row == "plain" }.count,
            native: pastes.filter { $0.row == "native" }.count,
            reading: pastes.filter { $0.row == "reading" }.count,
            labelRanks: labelRanks, slots: slots,
            lookedAndLeft: looked, typedAndLeft: typed, namedAndLeft: named, otherKeyAndLeft: other,
            abandonedSeconds: median(left.map(\.seconds)),
            pastedSeconds: median(pastes.map(\.seconds)),
            pastedFirstKey: median(pastes.map(\.openToFirstKey)),
            searchPasted: searchPastes.count,
            searchActed: searchOpens.filter { $0.action == "acted" }.count,
            searchLeft: searchOpens.filter { $0.action != "pasted" && $0.action != "acted" }.count,
            medianMatches: median(searchOpens.map { $0.matches.map(Double.init) }),
            depthOnShow: depths.filter { $0 < shown }.count,
            depthBeyond: depths.filter { $0 >= shown }.count,
            medianDepth: Maths.median(depths.map(Double.init)),
            apps: landed.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { Landing(app: $0.key, count: $0.value) })
    }
}
