import XCTest
@testable import LodestarCore

/// The dictation channel and the abandonment view: the two halves of
/// pricing the text and effort the scorecard used to omit.
final class DictationChannelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func draft(_ action: String, words: Int, seconds: Double,
                       source: String = "speak") -> ObservationEvent {
        var event = ObservationEvent(t: start, kind: .draft)
        event.source = source
        event.action = action
        event.words = words
        event.seconds = seconds
        return event
    }

    func testDictationPricesSpokenSecondsAgainstWordsKept() {
        // Two landed drafts of 150 words in 90s each, and one empty draft
        // that cost 30s and kept nothing.
        let events = [
            draft("pasted", words: 150, seconds: 90),
            draft("pasted", words: 150, seconds: 90),
            draft("empty", words: 0, seconds: 30),
        ]
        let now = start.addingTimeInterval(3600)
        let overhead = Overhead.compute(events: events, latency: nil, health: nil,
                                        clicks: nil, now: now)
        guard let dictation = overhead.channels.first(where: { $0.name == "dictation" }) else {
            return XCTFail("spoken drafts are a dictation channel")
        }
        XCTAssertTrue(dictation.measured)
        // 300 words at 2.5/s is a 120s floor; the actual is 210s of open
        // time, empty draft included.
        XCTAssertEqual(dictation.actualSecondsPerDay, 210, accuracy: 1e-6)
        XCTAssertEqual(dictation.floorSecondsPerDay, 120, accuracy: 1e-6)
        XCTAssertEqual(dictation.ratio ?? 0, 1.75, accuracy: 1e-6,
                       "the empty draft is dictation's correction tax")
    }

    func testEditDoorIsNotDictation() {
        let events = [draft("pasted", words: 100, seconds: 40, source: "edit")]
        let overhead = Overhead.compute(events: events, latency: nil, health: nil,
                                        clicks: nil, now: start.addingTimeInterval(3600))
        XCTAssertNil(overhead.channels.first(where: { $0.name == "dictation" }),
                     "the edit door is text editing, not speech")
    }

    func testDrafsThatLandedNoWordsMakeNoChannel() {
        let events = [draft("empty", words: 0, seconds: 30),
                      draft("cancelled", words: 0, seconds: 10)]
        let overhead = Overhead.compute(events: events, latency: nil, health: nil,
                                        clicks: nil, now: start.addingTimeInterval(3600))
        XCTAssertNil(overhead.channels.first(where: { $0.name == "dictation" }),
                     "a floor of zero words is no floor at all")
    }
}

final class AbandonmentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ kind: ObservationEvent.Kind, action: String? = nil,
                       source: String? = nil, seconds: Double? = nil,
                       hover: Double? = nil, route: String? = nil) -> ObservationEvent {
        var e = ObservationEvent(t: start, kind: kind)
        e.action = action; e.source = source; e.seconds = seconds
        e.hover = hover; e.route = route
        return e
    }

    func testEachSurfaceCountsAndPricesItsAbandons() {
        let events = [
            // Dictation: one landed, two abandoned costing 30s.
            event(.draft, action: "pasted", source: "speak", seconds: 90),
            event(.draft, action: "empty", source: "speak", seconds: 20),
            event(.draft, action: "cancelled", source: "speak", seconds: 10),
            // Select: three done, one abandoned at 2s.
            event(.select, action: "completed", seconds: 3),
            event(.select, action: "completed", seconds: 3),
            event(.select, action: "completed", seconds: 3),
            event(.select, action: "abandoned", seconds: 2),
            // Nav: a chain and a hovered abandon.
            event(.chain),
            event(.abandon, hover: 1.5),
            // Launcher: one committed, one abandoned (untimed).
            event(.reach, route: "searcher"),
            event(.launcherAbandon),
        ]
        let leaks = Abandonment.compute(events: events, days: 28, now: start.addingTimeInterval(3600))
        let byName = Dictionary(uniqueKeysWithValues: leaks.surfaces.map { ($0.name, $0) })

        XCTAssertEqual(byName["dictation"]?.abandoned, 2)
        XCTAssertEqual(byName["dictation"]?.opened, 3)
        XCTAssertEqual(byName["dictation"]?.secondsWasted ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(byName["dictation"]?.rate ?? 0, 2.0 / 3.0, accuracy: 1e-6)

        XCTAssertEqual(byName["select"]?.abandoned, 1)
        XCTAssertEqual(byName["select"]?.secondsWasted ?? 0, 2, accuracy: 1e-6)

        XCTAssertEqual(byName["navigation"]?.abandoned, 1)
        XCTAssertEqual(byName["navigation"]?.secondsWasted ?? 0, 1.5, accuracy: 1e-6)

        XCTAssertEqual(byName["launcher"]?.abandoned, 1)
        XCTAssertEqual(byName["launcher"]?.timed, false, "the launcher does not stamp open seconds")
        XCTAssertEqual(byName["launcher"]?.secondsWasted ?? -1, 0, "untimed, not invented")

        // Dictation led the leak, so it sorts first by wasted seconds.
        XCTAssertEqual(leaks.surfaces.first?.name, "dictation")
        // All events share one day, so the honest denominator is 1.
        XCTAssertEqual(leaks.days, 1)
        XCTAssertEqual(leaks.wastedSecondsPerDay, 33.5, accuracy: 1e-6)
    }

    func testAnEmptyWindowHasNoSurfaces() {
        let leaks = Abandonment.compute(events: [], days: 28)
        XCTAssertTrue(leaks.surfaces.isEmpty)
        XCTAssertEqual(leaks.wastedSecondsPerDay, 0)
    }
}
