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
                       depth: Int? = nil, daysAgo: Double = 0) -> ObservationEvent {
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
        XCTAssertEqual(keep.labelRanks[4], 1)
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
}
