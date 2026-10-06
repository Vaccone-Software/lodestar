import XCTest
@testable import LodestarCore

/// What a hand's correction teaches: a mishearing respelled is learned on
/// the first correction; a change of mind, a formatting change, or an
/// ordinary word never is.
final class CorrectionsTests: XCTestCase {
    private static let packaging = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packaging")
    private static let pronouncer: Pronouncer = {
        CommonWords.frequentListURL = packaging.appendingPathComponent("common-words.txt")
        let text = (try? String(contentsOf: packaging.appendingPathComponent("cmudict.dict"), encoding: .utf8)) ?? ""
        return Pronouncer(cmu: text)
    }()

    private func learned(_ before: String, _ after: String, known: Set<String> = []) -> [String] {
        Corrections.learned(before: before, after: after, known: known, pronouncer: Self.pronouncer,
                            isCommon: { CommonWords.isCommon($0) }, isFrequent: { CommonWords.isFrequent($0) })
    }

    func testAMisheardNameRespelledIsLearned() {
        XCTAssertEqual(learned("Ask Claude about can Dora today.", "Ask Claude about Kindora today."), ["Kindora"])
        XCTAssertEqual(learned("Push it to the zonar repo.", "Push it to the Xonar repo."), ["Xonar"])
    }

    func testAChangeOfMindIsNotLearned() {
        XCTAssertEqual(learned("Meet on Monday at noon.", "Meet on Tuesday at noon."), [])
        XCTAssertEqual(learned("Use the red one.", "Use the blue one."), [])
    }

    func testOrdinaryWordsAndFormattingAreNotLearned() {
        XCTAssertEqual(learned("Put it over their.", "Put it over there."), [], "every word ordinary")
        XCTAssertEqual(learned("Open draft controller.", "Open DraftController."), [], "a code name joined up")
        XCTAssertEqual(learned("Ship it.", "Ship it now."), [], "an insertion is not a correction")
        XCTAssertEqual(learned("Ship it now.", "Ship it."), [], "nor is a deletion")
    }

    func testAKnownWordIsNotLearnedAgain() {
        XCTAssertEqual(learned("about can Dora today", "about Kindora today", known: ["kindora"]), [])
    }

    func testARewriteIsNotARespelling() {
        XCTAssertEqual(learned("We should probably ship the build tonight after dinner.",
                               "Ship Kindora."), [], "too many words changed to be one word misheard")
    }

    func testOnlyTheChangedWordsAreCompared() {
        let hunks = Corrections.replacements(from: Corrections.tokens("a b c d e"), to: Corrections.tokens("a x c d y"))
        XCTAssertEqual(hunks.map(\.old), [["b"], ["e"]])
        XCTAssertEqual(hunks.map(\.new), [["x"], ["y"]])
        XCTAssertTrue(Corrections.replacements(from: ["Done."], to: ["Done"]).isEmpty, "a period moved is no change")
    }
}
