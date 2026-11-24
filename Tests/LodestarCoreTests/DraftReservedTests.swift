import XCTest
@testable import LodestarCore

/// What a final carries past the words the draft had already put on the
/// page, and where those words end once the hand has edited them.
final class DraftReservedTests: XCTestCase {
    func testTheWordsPastTheReservedOnesAreTheRemainder() throws {
        let rest = try XCTUnwrap(Draft.Reserved.remainder(of: Heard("Send the report today and call Sam."),
                                                          after: "send the report"))
        XCTAssertEqual(rest.text, "today and call Sam.")
    }

    func testCaseAndPunctuationAreIgnoredInTheMatch() throws {
        let rest = try XCTUnwrap(Draft.Reserved.remainder(of: Heard("Hello, world. And then some."),
                                                          after: "hello world"))
        XCTAssertEqual(rest.text, "And then some.")
    }

    func testAFinalThatDoesNotBeginWithTheReservedWordsPlacesNothing() {
        XCTAssertNil(Draft.Reserved.remainder(of: Heard("Something else entirely."), after: "send the report"))
        XCTAssertNil(Draft.Reserved.remainder(of: Heard("Send a report today"), after: "send the report"))
        XCTAssertNil(Draft.Reserved.remainder(of: Heard("Send the"), after: "send the report"),
                     "shorter than the reservation")
    }

    func testNothingBeyondTheReservedWordsIsNothing() {
        XCTAssertNil(Draft.Reserved.remainder(of: Heard("Send the report."), after: "send the report"))
        XCTAssertNil(Draft.Reserved.remainder(of: Heard("Send the report"), after: "   "),
                     "an empty reservation places nothing")
    }

    func testTheRemainderKeepsTheTimesOfItsWords() throws {
        let heard = Heard("Send the report today", words: [
            Heard.Word("Send", start: 0, end: 0.3), Heard.Word(" the", start: 0.3, end: 0.5),
            Heard.Word(" report", start: 0.5, end: 1.0), Heard.Word(" today", start: 1.2, end: 1.6),
        ])
        let rest = try XCTUnwrap(Draft.Reserved.remainder(of: heard, after: "send the report"))
        XCTAssertEqual(rest.text, "today")
        XCTAssertEqual(rest.words.map(\.text), [" today"])
        XCTAssertEqual(rest.start, 1.2)
    }

    // MARK: - The end

    private func chars(_ text: String) -> [Character] { Array(text) }

    func testAnEditAfterTheReservationLeavesItsEndWhereItWas() {
        let end = Draft.Reserved.end(of: 0..<11, was: chars("hello world"), now: chars("hello world, ok"))
        XCTAssertEqual(end, 11)
    }

    func testAnEditBeforeItMovesTheEnd() {
        let end = Draft.Reserved.end(of: 4..<15, was: chars("ok: hello world"), now: chars("hello world"))
        XCTAssertEqual(end, 11)
    }

    func testDeletingTheLastWordsPutsTheEndWhereTheyWere() {
        let end = Draft.Reserved.end(of: 0..<11, was: chars("hello world"), now: chars("hello "))
        XCTAssertEqual(end, 6)
    }

    func testAnEditInsideTheReservationMovesItsEndByTheChange() {
        let end = Draft.Reserved.end(of: 0..<11, was: chars("hello world"), now: chars("hello there world"))
        XCTAssertEqual(end, 17)
    }

    func testAnEditThatSpansTheEndEndsWhereTheEditEnds() {
        // The hand typed past the reservation and also changed its tail.
        let end = Draft.Reserved.end(of: 0..<11, was: chars("hello world abc"), now: chars("hello wor, xyz abc"))
        XCTAssertEqual(end, 14)
    }
}
