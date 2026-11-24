import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// ⌥ characters and dead keys, typed through the keyboard layout as any Mac
/// field takes them: ⌥e waits for the letter it accents, ⌥⇧- is the em
/// dash, ⌥8 a bullet. The layouts are named, so what is typed does not
/// depend on the keyboard of the Mac the tests run on.
final class DraftOptionTypingTests: XCTestCase {
    private static let us = "com.apple.keylayout.US"
    private static let international = "com.apple.keylayout.USInternational-PC"

    private func typer(_ id: String = us) throws -> LayoutTyper {
        let data = try XCTUnwrap(LayoutTyper.layout(id: id), "\(id) is installed")
        return LayoutTyper(source: { data })
    }

    private func standardStage(_ id: String = us) throws -> Stage {
        let stage = Stage()
        stage.draft.editingStyle = .standard
        stage.draft.layoutTyper = try typer(id)
        stage.lode(".", shift: true)
        return stage
    }

    // MARK: - The layout

    func testOptionTypesWhatTheLayoutTypes() throws {
        let t = try typer()
        XCTAssertEqual(t.type(keycode: 28, shift: false, option: true), "•", "⌥8")
        XCTAssertEqual(t.type(keycode: 27, shift: true, option: true), "—", "⌥⇧-")
        XCTAssertEqual(t.type(keycode: 27, shift: false, option: true), "–", "⌥-")
        XCTAssertEqual(t.type(keycode: 0, shift: false, option: true), "å", "⌥a")
        XCTAssertEqual(t.type(keycode: 33, shift: false, option: true), "“", "⌥[")
        XCTAssertFalse(t.pending)
    }

    func testAnOrdinaryKeyIsLeftToTheKeyTables() throws {
        let t = try typer()
        XCTAssertNil(t.type(keycode: 14, shift: false, option: false))
        XCTAssertNil(t.type(keycode: 14, shift: true, option: false))
        XCTAssertNil(t.type(keycode: 49, shift: false, option: false))
    }

    func testADeadKeyTypesNothingAndTheNextKeyCompletesIt() throws {
        let t = try typer()
        XCTAssertEqual(t.type(keycode: 14, shift: false, option: true), "", "⌥e is waiting")
        XCTAssertTrue(t.pending)
        XCTAssertEqual(t.type(keycode: 14, shift: false, option: false), "é", "and an e under it is é")
        XCTAssertFalse(t.pending, "the state is spent")
        XCTAssertNil(t.type(keycode: 14, shift: false, option: false), "and the next e is a plain one")
    }

    func testAShiftedLetterTakesTheAccentAsWellAndSpaceTypesTheAccentAlone() throws {
        let t = try typer()
        _ = t.type(keycode: 14, shift: false, option: true)
        XCTAssertEqual(t.type(keycode: 0, shift: true, option: false), "Á")
        _ = t.type(keycode: 14, shift: false, option: true)
        XCTAssertEqual(t.type(keycode: 49, shift: false, option: false), "´", "a dead key then space is the accent")
    }

    func testAKeyThatDoesNotComposeTypesTheAccentAndItself() throws {
        let t = try typer()
        _ = t.type(keycode: 14, shift: false, option: true)
        XCTAssertEqual(t.type(keycode: 7, shift: false, option: false), "´x")
        XCTAssertFalse(t.pending)
    }

    func testResetLetsADeadKeyGo() throws {
        let t = try typer()
        _ = t.type(keycode: 14, shift: false, option: true)
        t.reset()
        XCTAssertNil(t.type(keycode: 14, shift: false, option: false))
    }

    func testAKeyTheLayoutMakesDeadIsDeadWithoutOption() throws {
        let t = try typer(Self.international)
        XCTAssertEqual(t.type(keycode: 39, shift: false, option: false), "", "' is dead on this layout")
        XCTAssertEqual(t.type(keycode: 0, shift: false, option: false), "á")
        XCTAssertEqual(t.type(keycode: 39, shift: false, option: false), "")
        XCTAssertEqual(t.type(keycode: 49, shift: false, option: false), "'", "and ' then space is the apostrophe")
    }

    func testNoLayoutAtAllLeavesEveryKeyToTheTables() {
        let t = LayoutTyper(source: { nil })
        XCTAssertNil(t.type(keycode: 14, shift: false, option: true))
    }

    // MARK: - In the draft

    func testOptionECompletedByEIsEAcute() throws {
        let stage = try standardStage()
        stage.press("c"); stage.press("a"); stage.press("f")
        stage.press("e", option: true)
        XCTAssertEqual(stage.draft.buffer.text, "caf", "nothing is typed by the dead key")
        stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "café")
        stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "cafée", "and the next e is a plain one")
    }

    func testADeadKeyThenSpaceTypesTheAccent() throws {
        let stage = try standardStage()
        stage.press("e", option: true)
        stage.press("space")
        XCTAssertEqual(stage.draft.buffer.text, "´")
    }

    func testDashesBulletsAndCurlyQuotesAreTyped() throws {
        let stage = try standardStage()
        stage.press("8", option: true)
        stage.press("space")
        stage.press("-", shift: true, option: true)
        stage.press("space")
        stage.press("-", option: true)
        XCTAssertEqual(stage.draft.buffer.text, "• — –")
    }

    func testAMoveOrADeleteLetsTheDeadKeyGo() throws {
        let stage = try standardStage()
        stage.press("e", option: true)
        stage.press("left")
        stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "e", "the accent was dropped by the arrow")
        stage.press("e", option: true)
        stage.press("delete")
        stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "e", "the first e went with the delete, and this one is plain")
    }

    func testOptionArrowsAndOptionDeleteStillMoveAndDeleteByWord() throws {
        let stage = try standardStage()
        for c in "one two" { stage.press(c == " " ? "space" : String(c)) }
        stage.press("delete", option: true)
        XCTAssertEqual(stage.draft.buffer.text, "one ")
        stage.press("left", option: true)
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
        stage.press("right", option: true)
        XCTAssertEqual(stage.draft.buffer.cursor, 3)
    }

    func testTheInternationalLayoutsDeadApostropheWorksInTheDraft() throws {
        let stage = try standardStage(Self.international)
        stage.press("'")
        XCTAssertEqual(stage.draft.buffer.text, "")
        stage.press("a")
        XCTAssertEqual(stage.draft.buffer.text, "á")
    }

    func testOptionCharactersTypeUnderVimInsertToo() throws {
        let stage = Stage()
        stage.draft.layoutTyper = try typer()
        stage.lode(".", shift: true)
        stage.press("e", option: true)
        stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "é")
    }

    func testNormalModeIsUntouched() throws {
        let stage = Stage()
        stage.draft.layoutTyper = try typer()
        stage.lode(".", shift: true)
        stage.press("a"); stage.press("b")
        stage.press("escape")
        XCTAssertEqual(stage.draft.mode, .normal)
        stage.press("e", option: true)
        XCTAssertFalse(stage.draft.layoutTyper.pending, "a normal-mode key never starts a dead key")
        XCTAssertEqual(stage.draft.buffer.text, "ab")
    }

    func testATypedAccentIsOneUndoStepWithTheRest() throws {
        let stage = try standardStage()
        stage.press("c"); stage.press("a"); stage.press("f")
        stage.press("e", option: true); stage.press("e")
        XCTAssertEqual(stage.draft.buffer.text, "café")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "", "typed accents are part of the typed run")
    }
}
