import XCTest
@testable import LodestarCore

/// The gestures: toggles at the engine boundary — a disabled key behaves
/// as unbound at idle, and only at idle: lenses and chains keep their own
/// grammar.
final class EngineDisabledGesturesTests: XCTestCase {
    var core = EngineCore()
    var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func press(_ key: String, held: Bool = true, shift: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, world: world)
    }

    func testDisabledVerbPassesThroughOthersStillFire() {
        core.disabledGestures = ["space", "0"]
        XCTAssertEqual(press("space"), [.passThrough])
        XCTAssertEqual(press("0"), [.passThrough])
        XCTAssertEqual(press("\\"), [.flipOrientation], "undisabled verbs are untouched")
        XCTAssertEqual(press("1"), [.indexJump(1)])
    }

    func testDisabledLetterNeverReachesTheGraph() {
        core.disabledGestures = ["s"]
        world.graph = ["s": .leaf]
        XCTAssertEqual(press("s"), [.passThrough])
        XCTAssertTrue(world.calls.isEmpty, "the trie is never consulted")
    }

    func testDisabledKeyStillDismissesTheCheat() {
        core.disabledGestures = ["\\"]
        world.cheatVisible = true
        XCTAssertEqual(press("\\"), [.dismissCheat, .passThrough],
                       "help closes; the key still passes to the app")
    }

    func testDisabledKeyOnScrollExitPassesThrough() {
        _ = press("`")
        XCTAssertEqual(core.state, .scroll)
        core.disabledGestures = ["s"]
        XCTAssertEqual(press("s"), [.scrollExit, .hideGuide, .passThrough],
                       "the lens exits; the disabled verb does not fire")
        XCTAssertEqual(core.state, .idle)
    }

    func testDisabledKeyOnHintsExitPassesThrough() {
        _ = press(";")
        XCTAssertEqual(core.state, .hints(sticky: false))
        core.disabledGestures = ["\\"]
        XCTAssertEqual(press("\\"), [.exitHints, .passThrough])
        XCTAssertEqual(core.state, .idle)
    }

    func testMidChainLettersIgnoreTheToggles() {
        // Disabling graph blocks chain STARTS; letters inside a running
        // chain are chain grammar, not idle verbs, and stay swallowed.
        world.graph = ["e": .deeper, "ep": .leaf]
        _ = press("e")
        XCTAssertEqual(core.state, .chain(kind: .graph, letters: ["e"], deleting: false))
        core.disabledGestures = ["p"]
        XCTAssertEqual(press("p"), [.hideGuide, .summonGraph(letters: ["e", "p"], beside: false)])
    }

    func testScrollLensKeysIgnoreTheToggles() {
        _ = press("`")
        core.disabledGestures = ["j"]
        XCTAssertEqual(press("j", held: false), [.scrollCancelPendingG, .scrollDirectionDown("j")],
                       "inside the lens, j is scroll grammar, not a verb")
    }
}
