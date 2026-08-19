import XCTest
@testable import LodestarCore

final class FuzzyTests: XCTestCase {
    func testNonMatchIsNil() {
        XCTAssertNil(Fuzzy.score(query: "xyz", candidate: "Slack"))
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(Fuzzy.score(query: "slk", candidate: "Slack"))
        XCTAssertNotNil(Fuzzy.score(query: "gh", candidate: "Ghostty"))
        XCTAssertNotNil(Fuzzy.score(query: "pm", candidate: "Proton Mail"))
    }

    func testPrefixBeatsScattered() {
        let ranked = Fuzzy.rank(
            query: "s",
            candidates: ["Slack", "Finder", "Visual Studio Code"],
            key: { $0 }
        )
        XCTAssertEqual(ranked.first, "Slack")
        XCTAssertFalse(ranked.contains("Finder"))
    }

    func testWordInitialsRankHighly() {
        let score = Fuzzy.score(query: "pm", candidate: "Proton Mail")!
        let scattered = Fuzzy.score(query: "pm", candidate: "Pixelmator")!
        XCTAssertGreaterThan(score, scattered)
    }

    func testShorterNameWinsTies() {
        let ranked = Fuzzy.rank(query: "music", candidates: ["Music", "Amazon Music Player"], key: { $0 })
        XCTAssertEqual(ranked.first, "Music")
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertNotNil(Fuzzy.score(query: "", candidate: "Anything"))
    }

    // MARK: - Title affinity (re-matching a dead breath member)

    /// The bug this exists to stop. Containment was symmetric and had no
    /// floor, so a window titled "a" matched any target containing an "a" —
    /// and could take a saved layout's slot from the window that belonged in
    /// it, permanently, because the rebind is written to disk.
    func testAOneLetterTitleEarnsNothingAgainstALongTarget() {
        XCTAssertEqual(Fuzzy.titleAffinity(of: "a", against: "Asana — Customer Portal"), 0)
        XCTAssertEqual(Fuzzy.titleAffinity(of: "x", against: "Inbox • someone@example.com"), 0)
    }

    /// And the real window still wins it.
    func testTheRealWindowOutranksTheOneLetterOne() {
        let target = "Asana — Customer Portal"
        XCTAssertGreaterThan(Fuzzy.titleAffinity(of: "Asana — Customer Portal", against: target),
                             Fuzzy.titleAffinity(of: "a", against: target))
    }

    func testTheTiersAreOrdered() {
        let target = "Inbox • rvaccone@example.com"
        let exact = Fuzzy.titleAffinity(of: target, against: target)
        let contained = Fuzzy.titleAffinity(of: "Inbox • rvaccone@example.com — Outlook", against: target)
        let prefixed = Fuzzy.titleAffinity(of: "Inbox is a place I visit", against: target)
        let unrelated = Fuzzy.titleAffinity(of: "Slack", against: target)
        XCTAssertGreaterThan(exact, contained)
        XCTAssertGreaterThan(contained, prefixed)
        XCTAssertGreaterThan(prefixed, unrelated)
        XCTAssertEqual(unrelated, 0)
    }

    /// Containment is symmetric on purpose — a saved title may be the longer
    /// or the shorter of the pair — but only above the floor.
    func testContainmentIsSymmetricAboveTheFloorAndSilentBelowIt() {
        XCTAssertGreaterThan(Fuzzy.titleAffinity(of: "Release notes", against: "Release notes — draft"), 0)
        XCTAssertGreaterThan(Fuzzy.titleAffinity(of: "Release notes — draft", against: "Release notes"), 0)
        // "abc" is inside "abcdef", but three characters are not evidence.
        XCTAssertEqual(Fuzzy.titleAffinity(of: "abc", against: "abcdef"), 0)
    }

    func testAPrefixMustReachTheFloorToo() {
        XCTAssertEqual(Fuzzy.titleAffinity(of: "Zoo", against: "Zoom Meeting"), 0)
        XCTAssertGreaterThan(Fuzzy.titleAffinity(of: "Zoom Meeting 42", against: "Zoom Meeting 91"), 0)
    }

    func testALongerOverlapOutranksAShorterOne() {
        let target = "Customer Portal Release"
        XCTAssertGreaterThan(
            Fuzzy.titleAffinity(of: "Customer Portal Release — 2026", against: target),
            Fuzzy.titleAffinity(of: "Customer Portal Release", against: "Customer Portal Rel"))
    }

    func testAnEmptyTitleNeverMatches() {
        XCTAssertEqual(Fuzzy.titleAffinity(of: "", against: "Anything"), 0)
        XCTAssertEqual(Fuzzy.titleAffinity(of: "Anything", against: ""), 0)
        XCTAssertEqual(Fuzzy.titleAffinity(of: "", against: ""), 0)
    }

    /// Case is not a difference worth ranking on: the same window can report
    /// its title either way across a relaunch.
    func testExactIsCaseInsensitive() {
        XCTAssertEqual(Fuzzy.titleAffinity(of: "slack — xonar", against: "Slack — Xonar"),
                       Fuzzy.titleAffinity(of: "Slack — Xonar", against: "Slack — Xonar"))
    }

    /// Window titles come from other applications, so their length is not
    /// ours to assume. The tier ordering has to hold arithmetically rather
    /// than because a title "would never" be that long.
    func testTierOrderingSurvivesAPathologicalTitle() {
        // Comfortably past the cap, which is all the invariant turns on —
        // fifty thousand characters proved the same thing and cost the suite
        // nine seconds.
        let huge = String(repeating: "x", count: 3_000)
        let contained = Fuzzy.titleAffinity(of: huge, against: huge + "!")
        let exact = Fuzzy.titleAffinity(of: "same", against: "same")
        let prefixed = Fuzzy.titleAffinity(of: huge, against: String(repeating: "x", count: 2_000) + "zz")
        XCTAssertGreaterThan(exact, contained)
        XCTAssertGreaterThan(contained, prefixed)
        XCTAssertGreaterThan(prefixed, 0)
    }

    /// The property the caller depends on: equal titles score equal, so a tie
    /// is a real tie and gets broken by `mostCurrent` rather than by chance.
    func testTheOrderIsTotalAndRepeatable() {
        let target = "Brave Browser"
        let scores = (0..<50).map { _ in Fuzzy.titleAffinity(of: "Brave Browser", against: target) }
        XCTAssertEqual(Set(scores).count, 1)
    }
}
