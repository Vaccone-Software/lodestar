import XCTest
@testable import LodestarCore

/// Which thirty of the speaker's words the models are told.
final class DraftVocabularyTests: XCTestCase {
    private func words(_ count: Int) -> [String] {
        (0..<count).map { String(format: "word%02d", $0) }
    }

    func testAShortListIsToldAsItIs() {
        let list = ["Ghostty", "Kindora", "Lodestar"]
        XCTAssertEqual(DraftVocabulary.told(list, recent: ["Lodestar"]), list,
                       "every word fits, so recency changes nothing and the prompt stays the same")
        XCTAssertEqual(DraftVocabulary.told(words(30), recent: ["word29"]), words(30), "thirty fit exactly")
    }

    func testPastTheCapTheWordsInUseComeFirst() {
        let list = words(40)
        let told = DraftVocabulary.told(list, recent: ["word35", "word02", "word39"])
        XCTAssertEqual(told.count, DraftVocabulary.cap)
        XCTAssertEqual(Array(told.prefix(3)), ["word35", "word02", "word39"], "most recent first")
        XCTAssertEqual(Array(told.dropFirst(3)), Array(list.filter { !["word35", "word02", "word39"].contains($0) }.prefix(27)),
                       "then the rest, alphabetical")
        XCTAssertTrue(told.contains("word35"), "a word past the old cut-off is now told")
        XCTAssertFalse(told.contains("word29"), "and the one it displaced is not")
    }

    func testAWordNoLongerInTheListIsNotTold() {
        let list = words(40)
        let told = DraftVocabulary.told(list, recent: ["gone", "word36"])
        XCTAssertFalse(told.contains("gone"))
        XCTAssertEqual(told.first, "word36")
        XCTAssertEqual(told.count, 30)
        XCTAssertEqual(Set(told).count, 30, "no word twice")
    }

    func testMoreRecentWordsThanTheCapKeepTheMostRecent() {
        let list = words(60)
        let recent = (0..<45).map { "word\(String(format: "%02d", 59 - $0))" }
        let told = DraftVocabulary.told(list, recent: recent)
        XCTAssertEqual(told, Array(recent.prefix(30)))
    }

    func testRecentWordsKeepTheLatestFirstAndEachOnce() {
        var recent = RecentWords()
        recent.touch(["a", "b"])
        XCTAssertEqual(recent.order, ["b", "a"], "said in that order: b is the latest")
        recent.touch(["c", "a"])
        XCTAssertEqual(recent.order, ["a", "c", "b"])
        recent.touch(["a", "a"])
        XCTAssertEqual(recent.order, ["a", "c", "b"])
        recent.touch([])
        XCTAssertEqual(recent.order, ["a", "c", "b"])
    }

    func testRecentWordsAreBounded() {
        var recent = RecentWords()
        for index in 0..<(RecentWords.kept + 50) { recent.touch(["w\(index)"]) }
        XCTAssertEqual(recent.order.count, RecentWords.kept)
        XCTAssertEqual(recent.order.first, "w\(RecentWords.kept + 49)")
    }
}
