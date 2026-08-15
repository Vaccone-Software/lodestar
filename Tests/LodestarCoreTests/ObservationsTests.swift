import XCTest
@testable import LodestarCore

/// What Lodestar notices, and what it refuses to conclude from too little.
/// Every recommendation the app will ever make rests on these numbers, so the
/// silence rules are as much the contract as the maths.
final class ObservationsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func later(_ weeks: Int = 0, _ seconds: TimeInterval = 0) -> Date {
        start.addingTimeInterval(Double(weeks) * 604_800 + seconds)
    }

    // MARK: - Recording

    func testAChainRecordsItsMedianPause() {
        var o = Observations()
        o.chainCompleted(["e", "p"], gaps: [0.2, 0.4, 0.6], at: start)
        XCTAssertEqual(o.addresses["e p"]?.completions, 1)
        XCTAssertEqual(o.addresses["e p"]?.recent, [0.4])
        XCTAssertEqual(o.addresses["e p"]?.early, [0.4])
    }

    func testAGenuinelySlowRecallIsKeptBecauseItIsTheSignal() {
        // The first ceiling was two seconds, which threw away exactly the
        // addresses worth finding and left only the fluent ones in the median.
        var o = Observations()
        for _ in 0..<5 { o.chainCompleted(["e", "p"], gaps: [3.4], at: start) }
        XCTAssertEqual(o.fluency(["e", "p"])?.median ?? 0, 3.4, accuracy: 0.0001)
    }

    func testAnInterruptedChainContributesNoTiming() {
        // Chains wait indefinitely on purpose, so a phone call mid chain would
        // otherwise put minutes into every average here.
        var o = Observations()
        o.chainCompleted(["g"], gaps: [412.0], at: start)
        XCTAssertEqual(o.addresses["g"]?.completions, 1, "the completion still counts")
        XCTAssertEqual(o.addresses["g"]?.recent, [], "but the pause is not a recall event")
        XCTAssertNil(o.fluency(["g"]))
    }

    func testEarlySamplesAreKeptAndRecentSamplesRoll() {
        var o = Observations()
        for i in 0..<30 { o.chainCompleted(["s"], gaps: [Double(i) / 100 + 0.1], at: start) }
        let record = o.addresses["s"]
        XCTAssertEqual(record?.completions, 30)
        XCTAssertEqual(record?.early.count, Observations.earlyCap, "the beginning is kept forever")
        XCTAssertEqual(record?.recent.count, Observations.recentCap, "the present rolls")
        XCTAssertEqual(record?.early.first, 0.1, "the first sample is the first one taken")
        XCTAssertEqual(record?.recent.last ?? 0, 0.39, accuracy: 0.0001)
    }

    func testAbandonsAndWrongLettersAreCountedSeparately() {
        var o = Observations()
        o.chainCompleted(["b"], gaps: [0.3], at: start)
        o.chainAbandoned(["b"], at: start)
        o.wrongLetter(after: ["b"], at: start)
        let record = o.addresses["b"]
        XCTAssertEqual(record?.completions, 1)
        XCTAssertEqual(record?.abandons, 1)
        XCTAssertEqual(record?.wrongLetters, 1)
    }

    func testReachesAreCountedByRoute() {
        var o = Observations()
        o.reached("Slack", via: .graph, at: start)
        o.reached("slack", via: .searcher, charactersTyped: 3, at: start)
        o.reached("SLACK", via: .breath, at: start)
        let record = o.apps["slack"]
        XCTAssertEqual(record?.reaches, 3, "one app however it is capitalised")
        XCTAssertEqual(record?.graph, 1)
        XCTAssertEqual(record?.searcher, 1)
        XCTAssertEqual(record?.breath, 1)
        XCTAssertEqual(record?.typed, [3], "characters are recorded for searches only")
    }

    func testWeeksAreBoundedSoTheFileCannotBecomeAHistory() {
        var o = Observations()
        for week in 0..<20 { o.chainCompleted(["g"], gaps: [0.2], at: later(week)) }
        XCTAssertEqual(o.addresses["g"]?.weeks.count, Observations.weekCap)
        XCTAssertEqual(o.addresses["g"]?.completions, 20, "the count survives; the calendar does not")
    }

    // MARK: - Silence rules

    func testNothingIsConcludedFromTooFewSamples() {
        var o = Observations()
        for _ in 0..<4 {
            o.chainCompleted(["e", "p"], gaps: [0.9], at: start)
            o.chainAbandoned(["e", "p"], at: start)
        }
        o.reached("Outlook", via: .searcher, charactersTyped: 4, at: start)
        XCTAssertNil(o.fluency(["e", "p"]), "four samples is not a habit")
        XCTAssertNil(o.learningTrend(["e", "p"]))
        XCTAssertNil(o.routeShare("Outlook"), "one reach says nothing")
        XCTAssertNotNil(o.abandonRate(["e", "p"]), "eight events is enough to see a pattern")
    }

    func testActiveWeeksSeparatesAHabitFromADay() {
        var o = Observations()
        for i in 0..<10 { o.chainCompleted(["a"], gaps: [0.2], at: later(0, Double(i))) }
        XCTAssertEqual(o.activeWeeks(address: ["a"]), 1, "ten uses in one day is one week")
        o.chainCompleted(["a"], gaps: [0.2], at: later(1))
        XCTAssertEqual(o.activeWeeks(address: ["a"]), 2)
    }

    // MARK: - Reading

    func testFluencyIsTheMedianOfRecentPauses() {
        var o = Observations()
        for gap in [0.9, 0.2, 0.3, 0.25, 0.28] { o.chainCompleted(["w"], gaps: [gap], at: start) }
        let fluency = o.fluency(["w"])
        XCTAssertEqual(fluency?.samples, 5)
        XCTAssertEqual(fluency?.median ?? 0, 0.28, accuracy: 0.0001,
                       "the median ignores the one slow start")
    }

    func testLearningTrendBendsDownwardWhileAnAddressIsBeingLearned() {
        var learning = Observations()
        for gap in [1.2, 1.0, 0.9, 0.7, 0.5, 0.4] {
            learning.chainCompleted(["l"], gaps: [gap], at: start)
        }
        let slope = learning.learningTrend(["l"])
        XCTAssertNotNil(slope)
        XCTAssertLessThan(slope!, 0, "getting faster")

        var stuck = Observations()
        for gap in [1.1, 1.0, 1.2, 1.1, 1.05, 1.15] {
            stuck.chainCompleted(["e", "o"], gaps: [gap], at: start)
        }
        let flat = stuck.learningTrend(["e", "o"])
        XCTAssertNotNil(flat)
        XCTAssertGreaterThan(flat!, -0.05, "never bent: this binding is not working out")
    }

    func testRouteShareFindsAnAddressGoingUnused() {
        var o = Observations()
        for _ in 0..<9 { o.reached("Outlook", via: .searcher, charactersTyped: 4, at: start) }
        o.reached("Outlook", via: .graph, at: start)
        XCTAssertEqual(o.routeShare("Outlook") ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(o.medianTyped("Outlook"), 4, "what the search actually cost")
    }

    func testTypicalPauseIsThisPersonsOwnBaseline() {
        // A fixed threshold would insult fast typists and flatter slow ones.
        var o = Observations()
        for _ in 0..<5 { o.chainCompleted(["a"], gaps: [0.2], at: start) }
        for _ in 0..<5 { o.chainCompleted(["b"], gaps: [0.4], at: start) }
        for _ in 0..<5 { o.chainCompleted(["c"], gaps: [1.5], at: start) }
        XCTAssertEqual(o.typicalPause() ?? 0, 0.4, accuracy: 0.0001)
    }

    func testUnusedAddressesAreTheOnesBoundButNeverTyped() {
        var o = Observations()
        o.chainCompleted(["g"], gaps: [0.2], at: start)
        // Order follows the list it was given, so the caller keeps control of it.
        XCTAssertEqual(o.unused(among: [["g"], ["v", "z"], ["m"]]), [["v", "z"], ["m"]])
    }

    func testVerbsAreCountedSoADeadFeatureCanSaySo() {
        var o = Observations()
        o.verbUsed("hints", at: start)
        o.verbUsed("hints", at: start)
        XCTAssertEqual(o.verbs["hints"], 2)
        XCTAssertNil(o.verbs["scroll"])
    }

    // MARK: - Shape

    func testItRoundTripsThroughJSON() throws {
        var o = Observations()
        o.chainCompleted(["e", "p"], gaps: [0.3], at: start)
        o.reached("Proton Mail", via: .graph, at: start)
        o.verbUsed("clipboard", at: start)
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(Observations.self, from: data)
        XCTAssertEqual(back, o)
        XCTAssertEqual(back.version, Observations.currentVersion)
    }

    func testItRecordsNoContentAnywhere() throws {
        // The guard rail, asserted rather than trusted: whatever else changes
        // here, nothing that could identify a document, a page or a phrase may
        // end up in the file.
        var o = Observations()
        o.chainCompleted(["e", "p"], gaps: [0.3], at: start)
        o.reached("Proton Mail", via: .searcher, charactersTyped: 6, at: start)
        o.verbUsed("hints", at: start)
        let json = String(data: try JSONEncoder().encode(o), encoding: .utf8) ?? ""
        for forbidden in ["http", "://", "Inbox", "window", "title", "query", "clip"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()),
                           "observations must never carry \(forbidden)")
        }
    }
}
