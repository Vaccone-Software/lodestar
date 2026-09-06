import XCTest
@testable import LodestarCore

/// The image door and the save band as the grammar sees them: `E` on an
/// image card opens it large above the strip, `esc` and `⏎` step back,
/// `S` goes on to a name for the file, and every way out of either
/// returns to the strip or takes it down — never a paste.
final class ImageDoorGrammarTests: XCTestCase {
    private var core = EngineCore()
    private var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
        world.panelIsImage = true
    }

    private func press(_ key: String, held: Bool = false, shift: Bool = false,
                       command: Bool = false, option: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, command: command,
                     option: option, world: world)
    }

    private func openPanel(searching: Bool = false) {
        _ = core.openPaste(world: world)
        if searching {
            _ = press("/")
            _ = press("a", command: true, option: true)
        } else {
            _ = press("a", command: true)
        }
    }

    private func openDoor(searching: Bool = false) {
        openPanel(searching: searching)
        _ = press("e")
    }

    // MARK: - The door

    func testEOnAnImageOpensTheImageDoorNotTheDraft() {
        openPanel()
        XCTAssertEqual(press("e"), [.pasteImageShow, .pastePanelDismiss])
        XCTAssertEqual(core.state, .pasteImage(searching: false))
        XCTAssertTrue(world.calls.contains("pastePanelIsImage"), "the grammar asked, not guessed")
    }

    func testEOnATextCardStillOpensTheDraft() {
        world.panelIsImage = false
        openPanel()
        XCTAssertEqual(press("e"), [.pastePanelAct(.edit), .pastePanelDismiss])
        XCTAssertEqual(core.state, .pasteDoor(searching: false))
    }

    func testEscapeAndReturnStepBackToTheStrip() {
        for key in ["escape", "return"] {
            openDoor()
            XCTAssertEqual(press(key), [.pasteImageClose(reason: key)], key)
            XCTAssertEqual(core.state, .paste(searching: false), key)
            _ = core.keyDown(key: "escape", held: false, shift: false, command: false,
                             option: false, world: world)
            XCTAssertEqual(core.state, .idle)
        }
    }

    func testTheDoorRemembersTheSearchItRodeInOn() {
        openDoor(searching: true)
        XCTAssertEqual(core.state, .pasteImage(searching: true))
        _ = press("escape")
        XCTAssertEqual(core.state, .paste(searching: true), "back to the search, not out of it")
    }

    func testSInTheDoorGoesOnToTheSaveBandWithTheDoorGone() {
        openDoor()
        XCTAssertEqual(press("s"), [.pasteSaveBegin, .pasteImageClose(reason: "save")],
                       "the band reads the door's card before the door goes")
        XCTAssertEqual(core.state, .pasteSave(searching: false))
    }

    func testHJKLMoveThePictureAndShiftMovesItFaster() {
        openDoor()
        for key in ["h", "j", "k", "l"] {
            XCTAssertEqual(press(key), [.pasteImageMove(key: key, fast: false)], key)
            XCTAssertEqual(press(key, shift: true), [.pasteImageMove(key: key, fast: true)], "⇧\(key)")
        }
        XCTAssertEqual(core.state, .pasteImage(searching: false))
    }

    func testPlusAndMinusZoom() {
        openDoor()
        XCTAssertEqual(press("="), [.pasteImageZoom(in: true)], "= reads as plus without the shift")
        XCTAssertEqual(press("=", shift: true), [.pasteImageZoom(in: true)])
        XCTAssertEqual(press("-"), [.pasteImageZoom(in: false)])
        XCTAssertEqual(core.state, .pasteImage(searching: false))
    }

    func testOtherKeysAreSwallowedInsideTheDoor() {
        openDoor()
        for key in ["a", "1", "/", "space", "p", "d", "x"] {
            XCTAssertEqual(press(key), [], key)
            XCTAssertEqual(press(key, shift: true), [], "⇧\(key)")
            XCTAssertEqual(core.state, .pasteImage(searching: false), key)
        }
    }

    func testACommandChordEndsTheDoorAndTheStrip() {
        openDoor()
        XCTAssertEqual(press("w", command: true), [.pasteImageClose(reason: "command"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testALodeVerbEndsTheDoorAndExecutes() {
        openDoor()
        let effects = press("space", held: true)
        XCTAssertEqual(effects.prefix(2), [.pasteImageClose(reason: "lode"), .exitPaste])
        XCTAssertTrue(effects.contains(.showSearcher))
        XCTAssertEqual(core.state, .idle)
    }

    func testLodeEscapeEndsTheDoorWithoutExecuting() {
        openDoor()
        XCTAssertEqual(press("escape", held: true), [.pasteImageClose(reason: "lode"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testTheToggleAndAClickTakeTheDoorDownWithTheStrip() {
        openDoor()
        XCTAssertEqual(core.openPaste(world: world),
                       [.pasteImageClose(reason: "toggle"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
        openDoor()
        XCTAssertEqual(core.leavePaste(),
                       [.pasteImageClose(reason: "click"), .pastePanelDismiss, .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testDoorClosedReturnsFromTheImageDoorToo() {
        openDoor(searching: true)
        core.doorClosed()
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    // MARK: - The save band

    func testSOnTheCardOpensTheSaveBand() {
        openPanel()
        XCTAssertEqual(press("s"), [.pasteSaveBegin, .pastePanelDismiss],
                       "the band is read from the panel's card before the panel goes")
        XCTAssertEqual(core.state, .pasteSave(searching: false))
    }

    func testTypingBuildsTheName() {
        openPanel()
        _ = press("s")
        XCTAssertEqual(press("c"), [.pasteSaveType("c")])
        XCTAssertEqual(press("h", shift: true), [.pasteSaveType("H")])
        XCTAssertEqual(press("-"), [.pasteSaveType("-")])
        XCTAssertEqual(press("/"), [.pasteSaveType("/")])
        XCTAssertEqual(press("."), [.pasteSaveType(".")])
        XCTAssertEqual(press("space"), [.pasteSaveType(" ")])
        XCTAssertEqual(press("delete"), [.pasteSaveDelete(.character)])
        XCTAssertEqual(press("delete", option: true), [.pasteSaveDelete(.word)])
        XCTAssertEqual(press("delete", command: true), [.pasteSaveDelete(.all)])
        XCTAssertEqual(press("v", command: true), [.pasteSavePaste])
        XCTAssertEqual(core.state, .pasteSave(searching: false))
    }

    func testReturnWritesAndEscapeStepsBack() {
        openPanel()
        _ = press("s")
        XCTAssertEqual(press("return"), [.pasteSaveCommit])
        XCTAssertEqual(core.state, .paste(searching: false))
        _ = press("escape")
        openPanel(searching: true)
        _ = press("s")
        XCTAssertEqual(press("escape"), [.pasteSaveEnd])
        XCTAssertEqual(core.state, .paste(searching: true), "back to the search it rode in on")
    }

    func testACommandChordOrALodeVerbLeavesTheBandAndTheStrip() {
        openPanel()
        _ = press("s")
        XCTAssertEqual(press("w", command: true), [.pasteSaveEnd, .exitPaste])
        XCTAssertEqual(core.state, .idle)
        openPanel()
        _ = press("s")
        let effects = press("space", held: true)
        XCTAssertEqual(effects.prefix(2), [.pasteSaveEnd, .exitPaste])
        XCTAssertTrue(effects.contains(.showSearcher))
        XCTAssertEqual(core.state, .idle)
    }

    func testKeysThatTypeNothingAreSwallowedInTheBand() {
        openPanel()
        _ = press("s")
        for key in ["left", "right", "up", "down", "tab"] {
            XCTAssertEqual(press(key), [], key)
        }
        XCTAssertEqual(core.state, .pasteSave(searching: false))
    }

    func testTheToggleAndAClickEndTheBandWithTheStrip() {
        openPanel()
        _ = press("s")
        XCTAssertEqual(core.openPaste(world: world), [.pasteSaveEnd, .exitPaste])
        XCTAssertEqual(core.state, .idle)
        openPanel()
        _ = press("s")
        XCTAssertEqual(core.leavePaste(), [.pasteSaveEnd, .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }
}
