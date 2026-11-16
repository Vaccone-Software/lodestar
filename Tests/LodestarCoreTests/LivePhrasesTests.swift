import XCTest
@testable import LodestarCore

/// A streaming recognizer's pieces become the draft's open phrase and its
/// settled phrases, ended at a pause the way Apple's recognizer ends them.
final class LivePhrasesTests: XCTestCase {
    private typealias Piece = LivePhrases.Piece

    func testPiecesJoinIntoWordsWithTheirTimes() {
        let heard = LivePhrases.heard([Piece("▁Ope", start: 0.1, end: 0.2), Piece("n", start: 0.2, end: 0.3),
                                       Piece("▁the", start: 0.4, end: 0.5), Piece("▁file", start: 0.5, end: 0.7),
                                       Piece(".", start: 0.7, end: 0.8)])
        XCTAssertEqual(heard.text, "Open the file.")
        XCTAssertEqual(heard.words.map(\.text), ["Open", " the", " file."])
        XCTAssertEqual(heard.words.map(\.text).joined(), heard.text, "the words joined are the text")
        XCTAssertEqual(heard.start, 0.1)
        XCTAssertEqual(heard.end, 0.8)
    }

    func testTheOpenPhraseGrowsAndASentenceSettlesAtTheFirstQuietChunk() {
        var phrases = LivePhrases()
        XCTAssertEqual(phrases.take([Piece("▁Ship", start: 0, end: 0.3)]), [.volatile("Ship")])
        XCTAssertEqual(phrases.take([Piece("▁it", start: 0.4, end: 0.5), Piece(".", start: 0.5, end: 0.6)]),
                       [.volatile("Ship it.")])
        let events = phrases.take([])
        guard case .settled(let heard)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(heard.text, "Ship it.")
        XCTAssertEqual(phrases.take([]), [], "nothing open, nothing to settle")
    }

    func testAPauseMidSentenceSettlesAtTheSecondQuietChunk() {
        var phrases = LivePhrases()
        _ = phrases.take([Piece("▁look", start: 0, end: 0.3), Piece("▁at", start: 0.3, end: 0.4)])
        XCTAssertEqual(phrases.take([]), [], "one quiet chunk is a breath")
        let events = phrases.take([])
        guard case .settled(let heard)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(heard.text, "look at")
    }

    func testSpeechAfterAQuietChunkKeepsThePhraseOpen() {
        var phrases = LivePhrases()
        _ = phrases.take([Piece("▁look", start: 0, end: 0.3)])
        _ = phrases.take([])
        XCTAssertEqual(phrases.take([Piece("▁here", start: 1.2, end: 1.4)]), [.volatile("look here")])
        XCTAssertEqual(phrases.take([]), [], "the quiet count began again")
    }

    func testTheEndSettlesWhatIsOpen() {
        var phrases = LivePhrases()
        _ = phrases.take([Piece("▁last", start: 0, end: 0.3)])
        let events = phrases.finish([Piece("▁words", start: 0.3, end: 0.6)])
        guard case .settled(let heard)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(heard.text, "last words")
        XCTAssertEqual(phrases.finish(), [])
    }
}
