import XCTest
@testable import LodestarCore

/// The confidence gate's arithmetic, apart from any model: which marks an
/// answer offers to be weighed, and the answer rebuilt with only the fixes
/// that won by enough.
final class EditorConfidenceTests: XCTestCase {
    private func marks(_ sentence: String, _ answer: String) -> [String] {
        let text = sentence as NSString
        return EditorDiff.issues(text: text, sentence: NSRange(location: 0, length: text.length), corrected: answer,
                                 guards: EditorGuards(), protected: []).map { "\($0.original) → \($0.replacement)" }
    }

    func testAGrammarFixThatWinsByLittleIsTakenOutAndTheWritersSentenceStands() throws {
        let sentence = "Their going to the store."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: "They're going to the store.",
                                                             language: "en_US"))
        XCTAssertEqual(found.grammar.count, 1)
        XCTAssertEqual(EditorConfidence.fixed(sentence, by: found.issues[found.grammar[0]]), "They're going to the store.")
        let gated = EditorConfidence.gated(sentence: sentence, corrected: "They're going to the store.",
                                           issues: found.issues, grammar: found.grammar, margins: [1.5], threshold: 4)
        XCTAssertEqual(gated.dropped, 1)
        XCTAssertEqual(gated.answer, sentence)
        XCTAssertTrue(marks(sentence, gated.answer).isEmpty)
    }

    func testAFixThatWinsByEnoughLeavesTheModelsAnswerAsItCame() throws {
        let sentence = "Their going to the store."
        let answer = "They're going to the store."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: answer, language: "en_US"))
        let gated = EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                           grammar: found.grammar, margins: [EditorConfidence.standard], threshold: EditorConfidence.standard)
        XCTAssertEqual(gated.dropped, 0)
        XCTAssertEqual(gated.answer, answer)
    }

    func testOnlyTheWeakFixGoesAndTheSpellingFixBesideItStays() throws {
        let sentence = "I recieve the files and their going out today."
        let answer = "I receive the files and they're going out today."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: answer, language: "en_US"))
        XCTAssertEqual(found.issues.count, 2)
        XCTAssertEqual(found.grammar.count, 1, "the misspelled word is spelling, not weighed")
        let gated = EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                           grammar: found.grammar, margins: [-3], threshold: 4)
        XCTAssertEqual(gated.answer, "I receive the files and their going out today.")
        XCTAssertEqual(marks(sentence, gated.answer), ["recieve → receive"])
    }

    func testOfTwoGrammarFixesTheStrongOneStays() throws {
        let sentence = "Their going to the store and its closing soon."
        let answer = "They're going to the store and it's closing soon."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: answer, language: "en_US"))
        XCTAssertEqual(found.grammar.count, 2)
        let order = found.grammar.map { found.issues[$0].original }
        let margins = order.map { $0 == "Their" ? 12.0 : 0.5 }
        let gated = EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                           grammar: found.grammar, margins: margins, threshold: 4)
        XCTAssertEqual(gated.dropped, 1)
        XCTAssertEqual(marks(sentence, gated.answer), ["Their → They're"])
    }

    func testFullKeepsAnyFixItPrefersAtAll() throws {
        let sentence = "Their going to the store."
        let answer = "They're going to the store."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: answer, language: "en_US"))
        XCTAssertEqual(EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                              grammar: found.grammar, margins: [0.4], threshold: EditorConfidence.full).answer,
                       answer)
        XCTAssertEqual(EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                              grammar: found.grammar, margins: [-0.4], threshold: EditorConfidence.full).answer,
                       sentence)
    }

    func testNothingIsWeighedWithoutGrammarOrWithoutAReading() {
        XCTAssertNil(EditorConfidence.weighable(sentence: "I recieve them.", corrected: "I receive them.", language: "en_US"),
                     "spelling alone is not weighed")
        XCTAssertNil(EditorConfidence.weighable(sentence: "Fine as it is.", corrected: "Fine as it is.", language: "en_US"))
        XCTAssertNil(EditorConfidence.weighable(sentence: "Can you summarize this?",
                                                corrected: "Sure! Here is a short summary of the text you sent me today.",
                                                language: "en_US"), "an answer that did not read the sentence")
    }

    func testMarginsThatDoNotMatchTheMarksLeaveTheAnswerAlone() throws {
        let sentence = "Their going to the store."
        let answer = "They're going to the store."
        let found = try XCTUnwrap(EditorConfidence.weighable(sentence: sentence, corrected: answer, language: "en_US"))
        XCTAssertEqual(EditorConfidence.gated(sentence: sentence, corrected: answer, issues: found.issues,
                                              grammar: found.grammar, margins: [], threshold: 4).answer, answer)
    }

    func testAGrammarMarkIsSortedByWhatItChanges() {
        func sort(_ a: String, _ b: String) -> String? { EditorIssue.sort(kind: .grammar, original: a, replacement: b) }
        XCTAssertEqual(sort("metrics,", "metrics"), "punctuation")
        XCTAssertEqual(sort("We", "we"), "capital")
        XCTAssertEqual(sort("user?", "the user?"), "added")
        XCTAssertEqual(sort("the the", "the"), "removed")
        XCTAssertEqual(sort("easy", "easily"), "word")
        XCTAssertEqual(sort("their", "they're"), "word")
        XCTAssertNil(EditorIssue.sort(kind: .spelling, original: "recieve", replacement: "receive"))
    }
}
