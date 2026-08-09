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
}
