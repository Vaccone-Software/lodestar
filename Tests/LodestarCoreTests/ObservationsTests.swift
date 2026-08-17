import XCTest
@testable import LodestarCore

/// The materialized view over the event log. Every recommendation the app
/// will ever make rests on these numbers, so the caps, the tagging, and the
/// one-entry-point rule are as much the contract as the maths.
final class ObservationsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func later(_ weeks: Int = 0, _ seconds: TimeInterval = 0) -> Date {
        start.addingTimeInterval(Double(weeks) * 604_800 + seconds)
    }

    // MARK: - Event helpers

    private func chain(_ letters: [String], gaps: [Double], peeked: Bool = false,
                       at date: Date? = nil) -> ObservationEvent {
        var event = ObservationEvent(t: date ?? start, kind: .chain)
        event.chain = letters
        event.gaps = gaps
        event.peeked = peeked
        return event
    }

    private func reach(_ app: String, route: String, typed: Int? = nil,
                       rank: Int? = nil, listLength: Int? = nil,
                       openToCommit: Double? = nil, prefix: String? = nil,
                       at date: Date? = nil) -> ObservationEvent {
        var event = ObservationEvent(t: date ?? start, kind: .reach)
        event.app = app
        event.route = route
        event.typed = typed
        event.rank = rank
        event.listLength = listLength
        event.openToCommit = openToCommit
        event.queryPrefix = prefix
        return event
    }

    // MARK: - Recording

    func testAChainKeepsEveryGapTaggedByPosition() {
        var o = Observations()
        o.apply(chain(["e", "p"], gaps: [0.2, 0.4]))
        let record = o.addresses["e p"]
        XCTAssertEqual(record?.completions, 1)
        XCTAssertEqual(record?.recent.count, 2, "both gaps survive, not their median")
        XCTAssertEqual(record?.recent.first?.pos, 0, "the trigger gap knows it is one")
        XCTAssertEqual(record?.recent.last?.pos, 1)
        XCTAssertEqual(record?.trigger.n, 1)
        XCTAssertEqual(record?.inner.n, 1)
        XCTAssertEqual(exp(record?.recent.first?.log ?? 0), 0.2, accuracy: 0.0001)
    }

    func testAGenuinelySlowRecallIsKeptBecauseItIsTheSignal() {
        var o = Observations()
        for _ in 0..<5 { o.apply(chain(["e", "p"], gaps: [3.4])) }
        XCTAssertEqual(o.fluency(["e", "p"], pos: 0)?.median ?? 0, 3.4, accuracy: 0.001)
    }

    func testAnInterruptedChainContributesNoTiming() {
        // Chains wait indefinitely on purpose, so a phone call mid chain would
        // otherwise put minutes into every statistic here.
        var o = Observations()
        o.apply(chain(["g"], gaps: [412.0]))
        XCTAssertEqual(o.addresses["g"]?.completions, 1, "the completion still counts")
        XCTAssertEqual(o.addresses["g"]?.recent.count, 0, "the pause is not a recall event")
    }

    func testPeekedCompletionsAreLabeled() {
        var o = Observations()
        o.apply(chain(["g"], gaps: [1.2], peeked: true))
        o.apply(chain(["g"], gaps: [0.2]))
        let record = o.addresses["g"]
        XCTAssertEqual(record?.peeked, 1)
        XCTAssertEqual(record?.recent.first?.peeked, true, "the map consultation rides the sample")
        XCTAssertEqual(record?.recent.last?.peeked, false)
        XCTAssertNil(o.blindRate(["g"]), "two completions is not enough to conclude")
        for _ in 0..<3 { o.apply(chain(["g"], gaps: [0.2])) }
        XCTAssertEqual(o.blindRate(["g"]) ?? 0, 0.8, accuracy: 0.0001)
    }

    func testEarlySamplesAreKeptAndRecentSamplesRoll() {
        var o = Observations()
        for i in 0..<100 { o.apply(chain(["s"], gaps: [Double(i) / 100 + 0.1])) }
        let record = o.addresses["s"]
        XCTAssertEqual(record?.completions, 100)
        XCTAssertEqual(record?.first.count, Observations.firstCap, "the beginning is kept")
        XCTAssertEqual(record?.recent.count, Observations.recentCap, "the present rolls")
        XCTAssertEqual(record?.first.first?.ordinal, 1, "the curve knows its x-axis")
        XCTAssertEqual(record?.recent.last?.ordinal, 100)
    }

    func testAnAbandonCarriesItsHover() {
        var o = Observations()
        var event = ObservationEvent(t: start, kind: .abandon)
        event.chain = ["b"]
        event.hover = 4.0
        o.apply(event)
        let record = o.addresses["b"]
        XCTAssertEqual(record?.abandons, 1)
        XCTAssertEqual(exp(record?.hover.mean ?? 0), 4.0, accuracy: 0.001,
                       "couldn't-recall and wrong-tool escapes must stay tellable apart")
    }

    func testWrongKeysBuildAConfusionMatrix() {
        var o = Observations()
        for _ in 0..<3 {
            var event = ObservationEvent(t: start, kind: .wrongKey)
            event.chain = ["b"]
            event.pressed = "w"
            o.apply(event)
        }
        XCTAssertEqual(o.addresses["b"]?.wrongKeys, 3)
        XCTAssertEqual(o.addresses["b"]?.confusion["w"], 3,
                       "the letter the hand believed in is the evidence")
    }

    func testReachesAreCountedByRouteAndLauncherCostIsKept() {
        var o = Observations()
        o.apply(reach("Slack", route: "graph"))
        o.apply(reach("slack", route: "searcher", typed: 3, rank: 0, listLength: 6,
                      openToCommit: 1.8, prefix: "sl"))
        o.apply(reach("SLACK", route: "breath"))
        o.apply(reach("slack", route: "chooser"))
        let record = o.apps["slack"]
        XCTAssertEqual(record?.reaches, 4, "one app however it is capitalised")
        XCTAssertEqual(record?.graph, 1)
        XCTAssertEqual(record?.searcher, 1)
        XCTAssertEqual(record?.chooser, 1)
        XCTAssertEqual(record?.typed.mean ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(record?.rank.mean ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(exp(record?.commit.mean ?? 0), 1.8, accuracy: 0.001,
                       "the launcher's price in seconds, so routes share a currency")
        XCTAssertEqual(record?.prefixes["sl"], 1, "the name in the head")
    }

    func testWeeksAreBoundedSoTheFileCannotBecomeAHistory() {
        var o = Observations()
        for week in 0..<20 { o.apply(chain(["g"], gaps: [0.2], at: later(week))) }
        XCTAssertEqual(o.addresses["g"]?.weeks.count, Observations.weekCap)
        XCTAssertEqual(o.addresses["g"]?.completions, 20, "the count survives; the calendar does not")
    }

    func testHostsAreRecordedWithTheirProfiles() {
        var o = Observations()
        for _ in 0..<3 {
            var event = ObservationEvent(t: start, kind: .web)
            event.host = "GitHub.com"
            event.profile = "brave:work"
            event.source = "typed"
            o.apply(event)
        }
        let record = o.hosts["github.com"]
        XCTAssertEqual(record?.count, 3)
        XCTAssertEqual(record?.profiles["brave:work"], 3)
        XCTAssertEqual(record?.sources["typed"], 3)
    }

    func testFocusBuildsTransitionsAndSkipsRepeats() {
        var o = Observations()
        for app in ["Ghostty", "Brave", "Brave", "Ghostty", "Brave"] {
            var event = ObservationEvent(t: start, kind: .focus)
            event.app = app
            o.apply(event)
        }
        XCTAssertEqual(o.transitions["ghostty"]?["brave"] ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(o.transitions["brave"]?["ghostty"] ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(o.transitions["brave"]?["brave"], "staying put is not a move")
    }

    func testAnEpochBumpRestartsTheLearningCurve() {
        var o = Observations()
        for _ in 0..<8 { o.apply(chain(["b", "g"], gaps: [0.3, 0.4])) }
        XCTAssertEqual(o.addresses["b g"]?.first.count, 16, "two gaps per completion")
        var event = ObservationEvent(t: start, kind: .epoch)
        event.address = "b g"
        event.change = "retargeted"
        event.epoch = 1
        o.apply(event)
        let record = o.addresses["b g"]
        XCTAssertEqual(record?.epoch, 1)
        XCTAssertEqual(record?.first.count, 0, "a rebind restarts the curve")
        XCTAssertEqual(record?.trigger.n, 0)
        XCTAssertEqual(record?.completions, 8, "history of use survives; fluency does not")
        o.apply(chain(["b", "g"], gaps: [0.9, 0.9]))
        XCTAssertEqual(o.addresses["b g"]?.recent.last?.epoch, 1,
                       "new samples wear the new epoch")
    }

    func testAdoptionIsDetectedFromEpochEvents() {
        var o = Observations()
        var offered = ObservationEvent(t: start, kind: .coach)
        offered.action = "offered"
        offered.rec = "bind"
        offered.app = "facetime"
        offered.address = "f"
        offered.seconds = 20
        o.apply(offered)
        XCTAssertEqual(o.ledger.first?.offers, 1)
        XCTAssertEqual(o.ledger.first?.status, "offered")
        // The user writes lode F by hand instead of tapping — adopted all
        // the same.
        var event = ObservationEvent(t: later(1), kind: .epoch)
        event.address = "f"
        event.change = "added"
        event.epoch = 1
        o.apply(event)
        XCTAssertEqual(o.ledger.first?.adoptedWeek, Observations.week(later(1)),
                       "the flywheel closes without the user filing anything")
    }

    func testCoachEventsBuildTheLedger() {
        var o = Observations()
        var offered = ObservationEvent(t: start, kind: .coach)
        offered.action = "offered"
        offered.rec = "route"
        offered.app = "github.com"
        offered.seconds = 12
        o.apply(offered)
        o.apply(offered)
        var accepted = offered
        accepted.action = "accepted"
        accepted.t = later(0, 3600)
        o.apply(accepted)
        let entry = o.ledger.first
        XCTAssertEqual(o.ledger.count, 1, "one identity, one entry")
        XCTAssertEqual(entry?.offers, 2)
        XCTAssertEqual(entry?.status, "accepted")
        XCTAssertEqual(entry?.acceptedWeek, Observations.week(start))

        var never = ObservationEvent(t: start, kind: .coach)
        never.action = "never"
        never.rec = "bind"
        never.app = "music"
        never.seconds = 8
        o.apply(never)
        XCTAssertEqual(o.ledger.first { $0.target == "music" }?.status, "never",
                       "a no is remembered, which is what makes it safe to give")
    }

    // MARK: - The view is a view

    func testRebuildFromEventsEqualsIncrementalApplication() {
        var events: [ObservationEvent] = []
        for i in 0..<30 {
            events.append(chain(["g"], gaps: [0.1 + Double(i % 5) / 10],
                                peeked: i % 7 == 0, at: later(i / 10)))
            events.append(reach("slack", route: i % 3 == 0 ? "graph" : "searcher",
                                typed: 3, rank: 0, listLength: 5, openToCommit: 1.5,
                                at: later(i / 10)))
        }
        var focusEvent = ObservationEvent(t: later(1), kind: .focus)
        focusEvent.app = "ghostty"
        events.append(focusEvent)

        var incremental = Observations()
        for event in events { incremental.apply(event) }
        XCTAssertEqual(Observations.rebuild(from: events), incremental,
                       "one entry point, so the live view and a replay cannot disagree")
    }

    // MARK: - Silence rules

    func testNothingIsConcludedFromTooFewSamples() {
        var o = Observations()
        for _ in 0..<4 { o.apply(chain(["e", "p"], gaps: [0.9])) }
        o.apply(reach("Outlook", route: "searcher", typed: 4))
        XCTAssertNil(o.fluency(["e", "p"], pos: 0), "four samples is not a habit")
        XCTAssertNil(o.routeShare("Outlook"), "one reach says nothing")
    }

    func testAbandonsAggregateOverTheSubtree() {
        // Escapes attach to the prefix where the hand stalled; v1 asked each
        // leaf and heard silence. The subtree view is the fix.
        var o = Observations()
        for _ in 0..<3 {
            var event = ObservationEvent(t: start, kind: .abandon)
            event.chain = ["b"]
            event.hover = 2
            o.apply(event)
        }
        o.apply(chain(["b", "g"], gaps: [0.2, 0.3]))
        o.apply(chain(["b", "d"], gaps: [0.2, 0.3]))
        XCTAssertEqual(o.abandonRate(prefix: ["b"]) ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertNil(o.abandonRate(prefix: ["b", "g"]), "the leaf alone is too thin")
    }

    func testActiveWeeksSeparatesAHabitFromADay() {
        var o = Observations()
        for i in 0..<10 { o.apply(chain(["a"], gaps: [0.2], at: later(0, Double(i)))) }
        XCTAssertEqual(o.activeWeeks(address: ["a"]), 1, "ten uses in one day is one week")
        o.apply(chain(["a"], gaps: [0.2], at: later(1)))
        XCTAssertEqual(o.activeWeeks(address: ["a"]), 2)
    }

    // MARK: - Reading

    func testFluencyIsPositionScopedSoChainLengthCannotMasquerade() {
        var o = Observations()
        for _ in 0..<6 { o.apply(chain(["b", "d"], gaps: [0.2, 0.6])) }
        XCTAssertEqual(o.fluency(["b", "d"], pos: 0)?.median ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(o.fluency(["b", "d"], pos: 1)?.median ?? 0, 0.6, accuracy: 0.001,
                       "the recall gap and the motor gap are different events")
    }

    func testRouteShareFindsAnAddressGoingUnused() {
        var o = Observations()
        for _ in 0..<9 { o.apply(reach("Outlook", route: "searcher", typed: 4)) }
        o.apply(reach("Outlook", route: "graph"))
        XCTAssertEqual(o.routeShare("Outlook") ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(o.medianTyped("Outlook"), 4, "what the search actually cost")
    }

    func testTypicalPauseIsThisPersonsOwnBaseline() {
        // A fixed threshold would insult fast typists and flatter slow ones.
        var o = Observations()
        for _ in 0..<5 { o.apply(chain(["a"], gaps: [0.2])) }
        for _ in 0..<5 { o.apply(chain(["b"], gaps: [0.4])) }
        for _ in 0..<5 { o.apply(chain(["c"], gaps: [1.5])) }
        XCTAssertEqual(o.typicalPause() ?? 0, 0.4, accuracy: 0.001)
    }

    func testUnusedAddressesAreTheOnesBoundButNeverTyped() {
        var o = Observations()
        o.apply(chain(["g"], gaps: [0.2]))
        XCTAssertEqual(o.unused(among: [["g"], ["v", "z"], ["m"]]), [["v", "z"], ["m"]])
    }

    func testMultiScaleUsageDecaysByHalfLife() {
        var usage = Observations.MultiScale()
        usage.bump(at: start)
        XCTAssertEqual(usage.value(scale: 0, at: later(0, 86_400)), 0.5, accuracy: 0.001,
                       "one day at the one-day half-life")
        XCTAssertEqual(usage.value(scale: 1, at: later(1)), 0.5, accuracy: 0.001)
        usage.bump(at: later(0, 86_400))
        XCTAssertEqual(usage.value(scale: 0, at: later(0, 86_400)), 1.5, accuracy: 0.001)
    }

    // MARK: - Shape

    func testItRoundTripsThroughJSON() throws {
        var o = Observations()
        o.apply(chain(["e", "p"], gaps: [0.3, 0.2], peeked: true))
        o.apply(reach("Proton Mail", route: "graph"))
        var web = ObservationEvent(t: start, kind: .web)
        web.host = "github.com"
        web.profile = "brave:work"
        web.source = "typed"
        o.apply(web)
        var verb = ObservationEvent(t: start, kind: .verb)
        verb.verb = "clipboard"
        o.apply(verb)
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(Observations.self, from: data)
        XCTAssertEqual(back, o)
        XCTAssertEqual(back.version, Observations.currentVersion)
    }

    func testItRecordsHowYouGotPlacesNeverWhatYouWereDoing() throws {
        // The v2 guard rail. The file now deliberately carries hosts, app
        // names, and timings — the routing facts. What it must never carry:
        // a window title, a clipboard, a URL path, or a query beyond its
        // first two characters.
        var o = Observations()
        o.apply(chain(["e", "p"], gaps: [0.3]))
        o.apply(reach("Proton Mail", route: "searcher", typed: 6, prefix: "pr"))
        var web = ObservationEvent(t: start, kind: .web)
        web.host = "example.com"
        web.profile = "brave:work"
        web.source = "typed"
        o.apply(web)
        let json = String(data: try JSONEncoder().encode(o), encoding: .utf8) ?? ""
        for forbidden in ["title", "clipboard", "query\"", "path", "example.com/"] {
            XCTAssertFalse(json.lowercased().contains(forbidden),
                           "observations must never carry \(forbidden)")
        }
        for record in o.apps.values {
            for prefix in record.prefixes.keys {
                XCTAssertLessThanOrEqual(prefix.count, 2,
                                         "the first two characters, never the query")
            }
        }
    }
}
