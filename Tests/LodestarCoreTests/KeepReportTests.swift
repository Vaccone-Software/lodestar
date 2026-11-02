import XCTest
@testable import LodestarCore

/// Keep's anatomy is read off the same `.paste` events the abandonment line
/// counts, so the breakdown must add up to that line and name where the
/// hand left.
final class KeepReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func paste(_ action: String, source: String? = nil, row: String? = nil,
                       rank: Int? = nil, typed: Int = 0, seconds: Double = 2,
                       firstKey: Double? = 0.5, app: String = "slack", matches: Int? = nil,
                       depth: Int? = nil, closed: String? = nil, after: String? = nil,
                       daysAgo: Double = 0) -> ObservationEvent {
        var event = ObservationEvent(t: now.addingTimeInterval(-daysAgo * 86_400), kind: .paste)
        event.action = action
        event.source = source
        event.row = row
        event.rank = rank
        event.typed = typed
        event.seconds = seconds
        event.openToFirstKey = firstKey
        event.app = app
        event.matches = matches
        event.depth = depth
        event.closed = closed
        event.after = after
        return event
    }

    func testNoPastesNoReport() {
        XCTAssertNil(KeepReport.compute(events: [], now: now))
    }

    func testTheOutcomesAgreeWithTheAbandonmentLine() throws {
        let events = [
            paste("pasted", source: "label", row: "plain", rank: 0),
            paste("pasted", source: "label", row: "native", rank: 0),
            paste("acted", source: "label", row: "pin", rank: 1),
            paste("abandoned", firstKey: nil),
            paste("abandoned", firstKey: nil),
            paste("abandoned", source: "label", rank: 2, firstKey: 1),
            // A hunt past the ceiling is not an opening, here as there.
            paste("abandoned", seconds: 90),
            // Outside the window.
            paste("pasted", source: "label", row: "plain", rank: 0, daysAgo: 40),
        ]
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.opens, 6)
        XCTAssertEqual(keep.pasted, 2)
        XCTAssertEqual(keep.acted, 1)
        XCTAssertEqual(keep.abandoned, 3)
        XCTAssertEqual(keep.actedVerbs, ["pin": 1])
        let leaks = Abandonment.compute(events: events, now: now)
        let clipboard = try XCTUnwrap(leaks.surfaces.first { $0.name == "clipboard" })
        XCTAssertEqual(clipboard.opened, keep.opens)
        XCTAssertEqual(clipboard.abandoned, keep.abandoned)
    }

    func testHowPastesWereAddressedAndWhichCard() throws {
        var events: [ObservationEvent] = []
        for _ in 0..<3 { events.append(paste("pasted", source: "label", row: "plain", rank: 0)) }
        events.append(paste("pasted", source: "label", row: "native", rank: 7))
        events.append(paste("pasted", source: "pin", row: "plain", rank: 2))
        events.append(paste("pasted", source: "pin", row: "reading", rank: 2))
        events.append(paste("pasted", source: "search", row: "plain", rank: 4, typed: 3))
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.byLabel, 4)
        XCTAssertEqual(keep.byKeepsake, 2)
        XCTAssertEqual(keep.bySearch, 1)
        XCTAssertEqual(keep.plain, 5)
        XCTAssertEqual(keep.native, 1)
        XCTAssertEqual(keep.reading, 1)
        XCTAssertEqual(keep.labelRanks.count, Clipboard.recentLabels.count)
        XCTAssertEqual(keep.labelRanks[0], 3)
        XCTAssertEqual(keep.labelRanks[4], 0, "a search's rank is among its matches, not the row")
        XCTAssertEqual(keep.labelRanks[7], 1)
        XCTAssertEqual(keep.slots, [0, 2, 0, 0], "keepsake slots count from one")
    }

    func testAbandonedOpensAreToldByTheFurthestTheHandGot() throws {
        let events = [
            paste("abandoned", seconds: 1, firstKey: nil),
            paste("abandoned", seconds: 1, firstKey: nil),
            paste("abandoned", typed: 4, seconds: 3, firstKey: 0.4),
            paste("abandoned", source: "search", typed: 2, seconds: 9, firstKey: 0.4),
            paste("abandoned", source: "label", rank: 1, seconds: 5, firstKey: 0.4),
            paste("abandoned", seconds: 7, firstKey: 0.4),
            paste("pasted", source: "label", row: "plain", rank: 0, seconds: 2, firstKey: 0.6),
            paste("pasted", source: "label", row: "plain", rank: 0, seconds: 4, firstKey: 1.0),
        ]
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.abandoned, 6)
        XCTAssertEqual(keep.lookedAndLeft, 2)
        XCTAssertEqual(keep.typedAndLeft, 1)
        XCTAssertEqual(keep.namedAndLeft, 2, "a card named outranks the search that found it")
        XCTAssertEqual(keep.otherKeyAndLeft, 1)
        XCTAssertEqual(keep.lookedAndLeft + keep.typedAndLeft + keep.namedAndLeft
                       + keep.otherKeyAndLeft, keep.abandoned)
        XCTAssertEqual(keep.abandonedSeconds ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(keep.pastedSeconds ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(keep.pastedFirstKey ?? 0, 0.8, accuracy: 0.001)
    }

    func testTheSearchSplitsPastesFromLeavingsAndMeasuresDepth() throws {
        let events = [
            paste("pasted", source: "search", row: "plain", rank: 0, typed: 3, matches: 2, depth: 1),
            paste("pasted", source: "search", row: "plain", rank: 0, typed: 3, matches: 4, depth: 12),
            paste("pasted", source: "search", row: "plain", rank: 0, typed: 2, matches: 9, depth: 8),
            paste("abandoned", typed: 5, matches: 0),
            paste("acted", source: "search", row: "save", typed: 2, matches: 1),
            // No search at all.
            paste("pasted", source: "label", row: "plain", rank: 0),
        ]
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.searchPasted, 3)
        XCTAssertEqual(keep.searchLeft, 1)
        XCTAssertEqual(keep.searchActed, 1)
        XCTAssertEqual(keep.medianMatches ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(keep.depthOnShow, 1)
        XCTAssertEqual(keep.depthBeyond, 2, "depth eight is the first card past the eight on show")
        XCTAssertEqual(keep.medianDepth ?? 0, 8, accuracy: 0.001)
    }

    func testDestinationsAreCountedFromPastesMostFirst() throws {
        var events: [ObservationEvent] = []
        for _ in 0..<3 { events.append(paste("pasted", source: "label", row: "plain", rank: 0, app: "ghostty")) }
        events.append(paste("pasted", source: "label", row: "plain", rank: 0, app: "slack"))
        events.append(paste("abandoned", app: "mail"))
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.apps, [KeepReport.Landing(app: "ghostty", count: 3),
                                   KeepReport.Landing(app: "slack", count: 1)])
    }

    func testNoKeyOpeningsAreToldByHowTheyClosedAndWhatCameNext() throws {
        let events = [
            paste("abandoned", firstKey: nil, closed: "escape", after: "paste"),
            paste("abandoned", firstKey: nil, closed: "escape", after: "paste"),
            paste("abandoned", firstKey: nil, closed: "escape", after: "copy"),
            paste("abandoned", firstKey: nil, closed: "toggle", after: "reopen"),
            paste("abandoned", firstKey: nil, closed: "click"),
            paste("abandoned", firstKey: nil, closed: "lode", after: "typed"),
            // Before the strip watched: it says neither, and is not guessed.
            paste("abandoned", firstKey: nil),
            // A key was struck, so it is not a no-key opening.
            paste("abandoned", firstKey: 0.5, closed: "escape", after: "typed"),
        ]
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.lookedAndLeft, 7)
        XCTAssertEqual(keep.thenWatched, 6)
        XCTAssertEqual(keep.thenClosed, ["escape": 3, "toggle": 1, "click": 1, "lode": 1])
        XCTAssertEqual(keep.thenNext, ["paste": 2, "copy": 1, "reopen": 1, "nothing": 1, "typed": 1])
        XCTAssertEqual(keep.thenClosed.values.reduce(0, +), keep.thenWatched)
        XCTAssertEqual(keep.thenNext.values.reduce(0, +), keep.thenWatched)
    }

    func testUndoneCountsOnlyPastesMadeSinceTheStripBeganWatching() throws {
        let events = [
            // Before: no word yet to tell a paste watched from one that was not.
            paste("pasted", source: "label", row: "plain", rank: 0, daysAgo: 3),
            paste("pasted", source: "label", row: "plain", rank: 0, daysAgo: 2),
            paste("abandoned", firstKey: nil, closed: "escape", daysAgo: 1),
            paste("pasted", source: "label", row: "plain", rank: 0, after: "undo", daysAgo: 0.5),
            paste("pasted", source: "label", row: "plain", rank: 1, after: "typed", daysAgo: 0.4),
            paste("pasted", source: "pin", row: "plain", rank: 2, daysAgo: 0.3),
        ]
        let keep = try XCTUnwrap(KeepReport.compute(events: events, now: now))
        XCTAssertEqual(keep.watchedPastes, 3)
        XCTAssertEqual(keep.undone, 1)
    }

    func testRecordsFromBeforeTheWatchSayNothingOfIt() throws {
        let keep = try XCTUnwrap(KeepReport.compute(events: [
            paste("pasted", source: "label", row: "plain", rank: 0),
            paste("abandoned", firstKey: nil),
        ], now: now))
        XCTAssertEqual(keep.thenWatched, 0)
        XCTAssertEqual(keep.watchedPastes, 0)
        XCTAssertEqual(keep.undone, 0)
    }

    func testTheWordsSurviveTheLog() throws {
        let event = paste("abandoned", firstKey: nil, closed: "click", after: "reopen")
        let back = try JSONDecoder().decode(ObservationEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(back.closed, "click")
        XCTAssertEqual(back.after, "reopen")
        let old = try JSONDecoder().decode(ObservationEvent.self,
                                           from: Data(#"{"t":0,"kind":"paste","action":"pasted"}"#.utf8))
        XCTAssertNil(old.closed)
        XCTAssertNil(old.after)
    }
}
