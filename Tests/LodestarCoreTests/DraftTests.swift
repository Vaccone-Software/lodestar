import XCTest
@testable import LodestarCore

final class DraftTests: XCTestCase {
    // MARK: - The buffer

    func testTypedCharactersLandAtTheCursor() {
        var buffer = Draft.Buffer()
        buffer.type("hello")
        buffer.moveLeft()
        buffer.type("X")
        XCTAssertEqual(buffer.text, "hellXo")
        XCTAssertEqual(buffer.cursor, 5)
        XCTAssertEqual(buffer.lastGrain, .typed)
    }

    func testSpokenTextJoinsWithASpaceAfterAWord() {
        var buffer = Draft.Buffer()
        buffer.settle("Open Ghostty and Lodestar,")
        buffer.settle(" then move the card.")
        XCTAssertEqual(buffer.text, "Open Ghostty and Lodestar, then move the card.")
        XCTAssertEqual(buffer.lastGrain, .spoken)
    }

    func testSpokenTextJoinsWithoutASpaceAtStartAfterNewlineOrBeforePunctuation() {
        var buffer = Draft.Buffer()
        buffer.settle("first")
        buffer.newline()
        buffer.settle("second")
        buffer.settle(".")
        XCTAssertEqual(buffer.text, "first\nsecond.")
    }

    func testTypedIdentifierMidSpeechJoinsAsProse() {
        var buffer = Draft.Buffer()
        buffer.settle("Run the migration for")
        buffer.type(" user_sessions")
        buffer.settle("and tail the log.")
        XCTAssertEqual(buffer.text, "Run the migration for user_sessions and tail the log.")
    }

    func testGhostIsDrawnAfterTheCursorAndTypedTextLandsBeforeIt() {
        var buffer = Draft.Buffer()
        buffer.settle("Open")
        buffer.showGhost("the door")
        XCTAssertEqual(buffer.display, "Openthe door")
        buffer.type(" now")
        XCTAssertEqual(buffer.text, "Open now")
        XCTAssertEqual(buffer.display, "Open nowthe door")
        buffer.settle("the door")
        XCTAssertEqual(buffer.text, "Open now the door")
        XCTAssertEqual(buffer.ghost, "")
    }

    // MARK: - The grain rule

    func testBackspaceAfterSpeechTakesAWordAndKeepsTakingWords() {
        var buffer = Draft.Buffer()
        buffer.settle("one two three")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "one two")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "one")
    }

    func testBackspaceAfterTypingTakesACharacter() {
        var buffer = Draft.Buffer()
        buffer.settle("one two")
        buffer.type("!")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "one two")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "one tw", "typing reset the grain to the character")
    }

    func testBackspaceLeavesTheGhostAlone() {
        var buffer = Draft.Buffer()
        buffer.settle("one two")
        buffer.showGhost("three")
        buffer.backspace()
        XCTAssertEqual(buffer.text, "one")
        XCTAssertEqual(buffer.ghost, "three")
    }

    func testWordDeleteTakesTrailingSpaceThenTheWord() {
        var buffer = Draft.Buffer(text: "alpha beta  ")
        buffer.deleteWordBackward()
        XCTAssertEqual(buffer.text, "alpha ")
        buffer.deleteWordBackward()
        XCTAssertEqual(buffer.text, "")
        buffer.deleteWordBackward()
        XCTAssertEqual(buffer.text, "")
    }

    // MARK: - Moving

    func testLineMovesKeepTheColumn() {
        var buffer = Draft.Buffer(text: "abcdef\nxy\nlonger line", cursor: 4)
        buffer.moveDown()
        XCTAssertEqual(buffer.cursor, 9, "the short line clamps to its end")
        buffer.moveDown()
        XCTAssertEqual(buffer.cursor, 12, "column 2 on the third line")
        buffer.moveUp()
        buffer.moveUp()
        XCTAssertEqual(buffer.cursor, 2)
        buffer.moveLineEnd()
        XCTAssertEqual(buffer.cursor, 6)
        buffer.moveLineStart()
        XCTAssertEqual(buffer.cursor, 0)
    }

    func testWordMoves() {
        var buffer = Draft.Buffer(text: "alpha beta gamma", cursor: 0)
        buffer.moveWordRight()
        XCTAssertEqual(buffer.cursor, 5)
        buffer.moveWordRight()
        XCTAssertEqual(buffer.cursor, 10)
        buffer.moveWordLeft()
        XCTAssertEqual(buffer.cursor, 6)
    }

    // MARK: - Ending

    func testEndingIsLive() {
        XCTAssertEqual(Draft.ending(hasDestination: false, destinationIsOrigin: false, pulledFromOrigin: true), .clipboard)
        XCTAssertEqual(Draft.ending(hasDestination: true, destinationIsOrigin: true, pulledFromOrigin: true), .replace)
        XCTAssertEqual(Draft.ending(hasDestination: true, destinationIsOrigin: false, pulledFromOrigin: true), .paste,
                       "moved to another app: a paste, never a replacement of something there")
        XCTAssertEqual(Draft.ending(hasDestination: true, destinationIsOrigin: true, pulledFromOrigin: false), .paste,
                       "nothing was pulled, so nothing is replaced")
    }

    func testMovingTheCursorResetsTheBackspaceGrain() {
        var buffer = Draft.Buffer()
        buffer.settle("hello world")
        buffer.moveLeft(); buffer.moveLeft(); buffer.moveLeft()
        buffer.backspace()
        XCTAssertEqual(buffer.text, "hello wrld", "one character, not a word chunk, after the cursor moved")
    }

    // MARK: - Capitalization

    func testSpokenCapitalIsLoweredMidSentence() {
        var buffer = Draft.Buffer()
        buffer.type("hi ")
        buffer.settle("There you are")
        XCTAssertEqual(buffer.text, "hi there you are")
        buffer.settle("How are you")
        XCTAssertEqual(buffer.text, "hi there you are how are you")
    }

    func testSpokenCapitalStaysAtASentenceStart() {
        var buffer = Draft.Buffer()
        buffer.settle("Hello.")
        buffer.settle("How are you")
        XCTAssertEqual(buffer.text, "Hello. How are you")
        buffer.newline()
        buffer.settle("New line")
        XCTAssertEqual(buffer.text, "Hello. How are you\nNew line")
        XCTAssertEqual(Draft.cased("First", after: Array("")), "First", "the start of the text")
        XCTAssertEqual(Draft.cased("After", after: Array("Sure! ")), "After")
        XCTAssertEqual(Draft.cased("Why", after: Array("Really? ")), "Why")
    }

    func testNamesAndTheWordIKeepTheirCase() {
        XCTAssertEqual(Draft.cased("I think so", after: Array("and ")), "I think so")
        XCTAssertEqual(Draft.cased("McDonald is here", after: Array("with ")), "McDonald is here")
        XCTAssertEqual(Draft.cased("NASA launched", after: Array("then ")), "NASA launched")
        XCTAssertEqual(Draft.cased("Ghostty opens", after: Array("then ")), "ghostty opens",
                       "a plain capitalized word is lowered; the vocabulary restores names it knows")
    }

    func testTheGhostLeadsWithASpaceAfterTypedText() {
        var buffer = Draft.Buffer()
        buffer.type("hi")
        XCTAssertEqual(Draft.separator(after: buffer.characters[..<buffer.cursor], before: "there"), " ")
        buffer.settle("There")
        XCTAssertEqual(buffer.text, "hi there")
    }

}
