import XCTest
@testable import LodestarCore

/// ⌘V into the inputs that read their keys off the tap — the strip's
/// band, select, the click door — where no field editor exists to hear
/// it. The launcher, the commands bar and Ask are real text fields; the
/// Edit menu the app installs is what makes ⌘V land there, and its test
/// lives with the app.
final class PasteIntoInputsTests: XCTestCase {
    private var world = WorldStub()
    private var core = EngineCore()

    override func setUp() {
        world = WorldStub()
        core = EngineCore()
    }

    private func command(_ key: String, shift: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: false, shift: shift, command: true, world: world)
    }

    func testCommandVInTheStripsSearchJoinsTheQuery() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        XCTAssertEqual(core.state, .paste(searching: true))
        XCTAssertEqual(command("v"), [.pasteSearchPaste])
        XCTAssertEqual(core.state, .paste(searching: true), "still searching")
    }

    func testCommandVWithTheStripIdleOpensASearchWithTheText() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(command("v"), [.pasteSearchBegin, .pasteSearchPaste])
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    func testAShiftedCommandVInTheStripIsNotAPaste() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(command("v", shift: true), [.exitPaste],
                       "⇧⌘V is the strip's own toggle at the shell; here it is a ⌘ chord with no card")
        XCTAssertEqual(core.state, .idle)
    }

    func testCommandVInSelectFeedsTheSearch() {
        _ = core.keyDown(key: "/", held: true, shift: false, world: world)
        XCTAssertEqual(core.state, .select)
        XCTAssertEqual(command("v"), [.selectPaste])
        XCTAssertEqual(core.state, .select)
        XCTAssertFalse(world.calls.contains("selectKey:v"), "never reaches the search as a letter")
    }

    func testPlainVInSelectIsStillALetter() {
        _ = core.keyDown(key: "/", held: true, shift: false, world: world)
        _ = core.keyDown(key: "v", held: false, shift: false, world: world)
        XCTAssertTrue(world.calls.contains("selectKey:v"))
    }

    func testCommandVInHintsFeedsTheSearch() {
        _ = core.keyDown(key: ";", held: true, shift: false, world: world)
        XCTAssertEqual(core.state, .hints(sticky: false))
        XCTAssertEqual(command("v"), [.selectPaste])
        XCTAssertEqual(core.state, .hints(sticky: false))
    }
}
