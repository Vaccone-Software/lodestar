import XCTest
@testable import LodestarCore

/// ⇧⌘V from a lens or a chain: the one in flight ends first, with the
/// effects its own exits use, and only once Keep has said it can open.
final class EngineKeepEndsLensTests: XCTestCase {
    var core = EngineCore()
    var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
        world.graph = ["e": .deeper]
    }

    private func press(_ key: String, held: Bool = true) {
        _ = core.keyDown(key: key, held: held, shift: false, world: world)
    }

    private let opening: [EngineEffect] = [.hideBars, .enterPaste]

    func testFromIdleThereIsNothingToEnd() {
        XCTAssertEqual(core.openPaste(world: world), opening)
    }

    func testFromScrollTheLensEndsFirst() {
        press("`")
        XCTAssertEqual(core.state, .scroll)
        XCTAssertEqual(core.openPaste(world: world), [.scrollExit(reason: .verb), .hideGuide] + opening)
        XCTAssertEqual(core.state, .paste(searching: false))
    }

    func testFromTheAimBandBothEnd() {
        press("`")
        press("/", held: false)
        XCTAssertEqual(core.state, .scrollAim)
        XCTAssertEqual(core.openPaste(world: world),
                       [.scrollAimEnd, .scrollExit(reason: .verb), .hideGuide] + opening)
    }

    func testFromHintsTheLensEnds() {
        press(";")
        XCTAssertEqual(core.state, .hints(sticky: false))
        XCTAssertEqual(core.openPaste(world: world), [.exitHints] + opening)
    }

    func testFromSelectTheSessionEnds() {
        press("/")
        XCTAssertEqual(core.state, .select)
        XCTAssertEqual(core.openPaste(world: world), [.exitSelect] + opening)
    }

    func testFromAChainTheGuideGoes() {
        press("e")
        XCTAssertTrue(core.isChain)
        XCTAssertEqual(core.openPaste(world: world), [.hideGuide] + opening)
    }

    func testWithNothingToPasteWhatStoodStaysExactlyAsItWas() {
        world.pasteAvailable = false
        let gestures: [(String, () -> Void)] = [
            ("scroll", { self.press("`") }),
            ("aim", { self.press("`"); self.press("/", held: false) }),
            ("hints", { self.press(";") }),
            ("select", { self.press("/") }),
            ("chain", { self.press("e") }),
        ]
        for (name, enter) in gestures {
            core = EngineCore()
            enter()
            let before = core.state
            XCTAssertEqual(core.openPaste(world: world), [.flash("⌂ nothing copied yet")], name)
            XCTAssertEqual(core.state, before, name)
        }
    }
}
