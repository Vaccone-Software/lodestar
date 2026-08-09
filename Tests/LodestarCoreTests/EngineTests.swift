import XCTest
@testable import LodestarCore

/// The grammar, exercised without a window server: a scripted world answers
/// the core's questions, and every test asserts (state, effects) exactly.
final class WorldStub: EngineWorld {
    /// joined letters → resolution ("sg" for [s, g]).
    var graph: [String: GraphResolution] = [:]
    /// scripted outcomes per operation, keyed "op:path" (e.g. "markGo:q").
    var outcomes: [String: ChainStep] = [:]
    /// every world call, in order.
    var calls: [String] = []

    var searcherVisible = false
    var webBarVisible = false
    var menuSearchVisible = false
    var cheatVisible = false
    var hasFocusedApp = true
    var scrollEnterSucceeds = true
    var hintsEnterSucceeds = true
    var hintOutcomes: [String: HintStep] = [:]

    func resolveGraph(_ letters: [String]) -> GraphResolution {
        calls.append("resolve:\(letters.joined())")
        return graph[letters.joined()] ?? .miss
    }

    private func step(_ op: String, _ letters: [String]) -> ChainStep {
        let key = "\(op):\(letters.joined())"
        calls.append(key)
        return outcomes[key] ?? .continuing(hint: nil)
    }

    func markGo(_ letters: [String]) -> ChainStep { step("markGo", letters) }
    func markBind(_ letters: [String]) -> ChainStep { step("markBind", letters) }
    func markDelete(_ letters: [String]) -> ChainStep { step("markDelete", letters) }
    func breathGo(_ letters: [String]) -> ChainStep { step("breathGo", letters) }
    func breathBind(_ letters: [String]) -> ChainStep { step("breathBind", letters) }
    func breathDelete(_ letters: [String]) -> ChainStep { step("breathDelete", letters) }
    func breathUpdateLatest() -> ChainStep {
        calls.append("breathUpdateLatest")
        return outcomes["breathUpdateLatest"] ?? .done(flash: "updated")
    }

    func enterScroll() -> Bool {
        calls.append("enterScroll")
        return scrollEnterSucceeds
    }

    func enterHints(sticky: Bool) -> Bool {
        calls.append("enterHints\(sticky ? ":sticky" : "")")
        return hintsEnterSucceeds
    }

    func hintType(_ letter: String, shift: Bool) -> HintStep {
        calls.append("hintType:\(letter)\(shift ? ":shift" : "")")
        return hintOutcomes[letter] ?? .ignored
    }
}

final class EngineTests: XCTestCase {
    var core = EngineCore()
    var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func press(_ key: String, held: Bool = true, shift: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, world: world)
    }

    // MARK: - Trigger classification

    func testRightCommandDeviceBitTriggers() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | EngineCore.rightCommandBit)
        let (held, shift) = EngineCore.classify(flags, trigger: .rightCommand)
        XCTAssertTrue(held)
        XCTAssertFalse(shift)
    }

    func testPlainCommandWithoutDeviceBitDoesNotTrigger() {
        let (held, _) = EngineCore.classify(.maskCommand, trigger: .rightCommand)
        XCTAssertFalse(held)
    }

    func testMehChordTriggers() {
        let (held, shift) = EngineCore.classify(EngineCore.meh, trigger: .rightCommand)
        XCTAssertTrue(held)
        XCTAssertFalse(shift)
    }

    func testMehWithShiftKeepsShiftMeaning() {
        let flags = CGEventFlags(rawValue: EngineCore.meh.rawValue | CGEventFlags.maskShift.rawValue)
        let (held, shift) = EngineCore.classify(flags, trigger: .rightCommand)
        XCTAssertTrue(held)
        XCTAssertTrue(shift)
    }

    func testRawHyperNeedsAllFourAndConsumesShift() {
        let full = CGEventFlags(rawValue: EngineCore.meh.rawValue | CGEventFlags.maskShift.rawValue)
        let (heldFull, shiftFull) = EngineCore.classify(full, trigger: .rawHyper)
        XCTAssertTrue(heldFull)
        XCTAssertFalse(shiftFull, "shift is part of the chord, not a modifier")
        let (heldMeh, _) = EngineCore.classify(EngineCore.meh, trigger: .rawHyper)
        XCTAssertFalse(heldMeh)
    }

    func testChainShiftReadsBareShiftWhenHyperReleased() {
        XCTAssertTrue(EngineCore.chainShift(.maskShift, trigger: .rightCommand))
        XCTAssertFalse(EngineCore.chainShift([], trigger: .rightCommand))
    }

    // MARK: - Idle dispatch

    func testUnheldKeysPassThrough() {
        XCTAssertEqual(press("s", held: false), [.passThrough])
        XCTAssertEqual(core.state, .idle)
    }

    func testUnboundPunctuationPassesThrough() {
        XCTAssertEqual(press("-"), [.passThrough])
        XCTAssertEqual(press("/"), [.passThrough], "plain / is reserved, not bound")
    }

    func testQuestionMarkTogglesCheat() {
        XCTAssertEqual(press("/", shift: true), [.toggleCheat])
    }

    func testAnyVerbDismissesVisibleCheatFirst() {
        world.cheatVisible = true
        XCTAssertEqual(press("o"), [.dismissCheat, .flipOrientation])
        world.cheatVisible = true
        XCTAssertEqual(press("/", shift: true), [.toggleCheat],
                       "? itself toggles rather than dismiss-then-reopen")
    }

    func testSearcherTogglesOnSpace() {
        XCTAssertEqual(press("space"), [.hideBars, .showSearcher])
        world.searcherVisible = true
        XCTAssertEqual(press("space"), [.hideBars], "visible searcher hides, not reopens")
    }

    func testWebBarAndMenuSearchToggle() {
        XCTAssertEqual(press("return"), [.hideBars, .showWebBar])
        XCTAssertEqual(press("."), [.hideBars, .showMenuSearch])
        world.webBarVisible = true
        XCTAssertEqual(press("return"), [.hideBars])
        world.webBarVisible = false
        world.menuSearchVisible = true
        XCTAssertEqual(press("."), [.hideBars])
    }

    func testCommaEntersScroll() {
        XCTAssertEqual(press(","), [.hideBars, .enterScroll, .scrollGuide])
        XCTAssertEqual(core.state, .scroll)
    }

    func testCommaWithNothingToScrollStaysIdle() {
        world.scrollEnterSucceeds = false
        XCTAssertEqual(press(","), [.hideBars, .flash("✕ no focused window to scroll")])
        XCTAssertEqual(core.state, .idle)
    }

    func testTabOpensWindowChooser() {
        XCTAssertEqual(press("tab"), [.openWindowChooser])
        world.hasFocusedApp = false
        XCTAssertEqual(press("tab"), [.flash("✕ no focused window")])
    }

    func testTabInsideSearcherIsSwallowed() {
        world.searcherVisible = true
        XCTAssertEqual(press("tab"), [], "the searcher owns its tab")
    }

    func testClaimFocused() {
        XCTAssertEqual(press("="), [.claimFocused(beside: false)])
        XCTAssertEqual(press("=", shift: true), [.claimFocused(beside: true)])
        world.hasFocusedApp = false
        XCTAssertEqual(press("="), [.flash("✕ no focused window to claim")])
        XCTAssertEqual(core.state, .idle)
    }

    func testLayoutVerbs() {
        XCTAssertEqual(press("o"), [.flipOrientation])
        XCTAssertEqual(press("0"), [.sweep])
        XCTAssertEqual(press("z"), [.undoLayout])
        XCTAssertEqual(press("z", shift: true), [.redoLayout])
        XCTAssertEqual(press("x"), [.goBack])
        XCTAssertEqual(press("x", shift: true), [.goForward])
    }

    func testDisplayMoves() {
        XCTAssertEqual(press("["), [.moveDisplay(direction: -1, beside: false)])
        XCTAssertEqual(press("]", shift: true), [.moveDisplay(direction: 1, beside: true)])
    }

    func testDigitsJumpAndShiftedDigitsReorder() {
        XCTAssertEqual(press("3"), [.indexJump(3)])
        XCTAssertEqual(press("3", shift: true), [.reorder(3)])
    }

    func testBacktickAndQuoteStartChains() {
        XCTAssertEqual(press("`"), [.showGuide(kind: .mark, letters: [], deleting: false, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .mark, letters: [], deleting: false))

        core = EngineCore()
        XCTAssertEqual(press("'"), [.showGuide(kind: .breath, letters: [], deleting: false, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .breath, letters: [], deleting: false))
    }

    // MARK: - Graph chains

    func testGraphLeafSummonsImmediately() {
        world.graph = ["s": .leaf]
        XCTAssertEqual(press("s"), [.hideGuide, .summonGraph(letters: ["s"], beside: false)])
        XCTAssertEqual(core.state, .idle)
    }

    func testGraphShiftMeansBeside() {
        world.graph = ["s": .leaf]
        XCTAssertEqual(press("s", shift: true), [.hideGuide, .summonGraph(letters: ["s"], beside: true)])
    }

    func testGraphWalksDeeperThenResolves() {
        world.graph = ["e": .deeper, "eo": .leaf]
        XCTAssertEqual(press("e"), [.showGuide(kind: .graph, letters: ["e"], deleting: false, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .graph, letters: ["e"], deleting: false))
        XCTAssertEqual(press("o"), [.hideGuide, .summonGraph(letters: ["e", "o"], beside: false)])
        XCTAssertEqual(core.state, .idle)
    }

    func testFirstLetterMissExitsWithFlash() {
        XCTAssertEqual(press("q"), [.hideGuide, .flash("✕ Q is not on the graph")])
        XCTAssertEqual(core.state, .idle, "a stray hyper+letter must not trap the user in a mode")
    }

    func testMidChainMissKeepsValidPrefix() {
        world.graph = ["e": .deeper]
        _ = press("e")
        XCTAssertEqual(press("q"), [.showGuide(kind: .graph, letters: ["e"], deleting: false,
                                               note: "✕ E Q is not on the graph")])
        XCTAssertEqual(core.state, .chain(kind: .graph, letters: ["e"], deleting: false))
    }

    func testEscapeClearsChain() {
        world.graph = ["e": .deeper]
        _ = press("e")
        XCTAssertEqual(press("escape"), [.hideGuide])
        XCTAssertEqual(core.state, .idle)
    }

    func testChainSwallowsStrayKeys() {
        world.graph = ["e": .deeper]
        _ = press("e")
        XCTAssertEqual(press("space"), [], "half-finished chains never leak keystrokes")
        XCTAssertEqual(press("3"), [])
        XCTAssertEqual(core.state, .chain(kind: .graph, letters: ["e"], deleting: false))
    }

    // MARK: - Marks

    func testMarkGoContinuesThenLands() {
        world.outcomes["markGo:q"] = .continuing(hint: nil)
        world.outcomes["markGo:qa"] = .done(flash: nil)
        _ = press("`")
        XCTAssertEqual(press("q"), [.showGuide(kind: .mark, letters: ["q"], deleting: false, note: nil)])
        XCTAssertEqual(press("a"), [.hideGuide])
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(world.calls, ["markGo:q", "markGo:qa"])
    }

    func testMarkBindOnShift() {
        world.outcomes["markBind:q"] = .done(flash: "◆ Q bound")
        _ = press("`")
        XCTAssertEqual(press("q", shift: true), [.hideGuide, .flash("◆ Q bound")])
        XCTAssertEqual(core.state, .idle)
    }

    func testRefusedBindStaysInChainWithNote() {
        world.outcomes["markBind:q"] = .failed(flash: "✕ Q would shadow QA")
        _ = press("`")
        XCTAssertEqual(press("q", shift: true),
                       [.showGuide(kind: .mark, letters: [], deleting: false, note: "✕ Q would shadow QA")])
        XCTAssertEqual(core.state, .chain(kind: .mark, letters: [], deleting: false),
                       "a refused bind is information, not an exit")
    }

    func testDeleteArmsThenDeletes() {
        world.outcomes["markDelete:q"] = .done(flash: "◆ Q deleted")
        _ = press("`")
        XCTAssertEqual(press("delete"), [.showGuide(kind: .mark, letters: [], deleting: true, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .mark, letters: [], deleting: true))
        XCTAssertEqual(press("q"), [.hideGuide, .flash("◆ Q deleted")])
        XCTAssertEqual(core.state, .idle)
    }

    func testDeleteDisarmsOnSecondPress() {
        _ = press("`")
        _ = press("delete")
        XCTAssertEqual(press("delete"), [.showGuide(kind: .mark, letters: [], deleting: false, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .mark, letters: [], deleting: false))
    }

    func testDeleteCollectsMultiLetterPaths() {
        world.outcomes["markDelete:q"] = .continuing(hint: nil)
        world.outcomes["markDelete:qa"] = .done(flash: nil)
        _ = press("`")
        _ = press("delete")
        XCTAssertEqual(press("q"), [.showGuide(kind: .mark, letters: ["q"], deleting: true, note: nil)])
        XCTAssertEqual(core.state, .chain(kind: .mark, letters: ["q"], deleting: true), "still armed")
        XCTAssertEqual(press("a"), [.hideGuide])
    }

    func testGraphChainIgnoresDelete() {
        world.graph = ["e": .deeper]
        _ = press("e")
        XCTAssertEqual(press("delete"), [], "nothing to delete on the graph")
        XCTAssertEqual(core.state, .chain(kind: .graph, letters: ["e"], deleting: false))
    }

    // MARK: - Breaths

    func testBreathDoubleTapUpdatesLatest() {
        world.outcomes["breathUpdateLatest"] = .done(flash: "◎ updated")
        _ = press("'")
        XCTAssertEqual(press("'"), [.hideGuide, .flash("◎ updated")])
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(world.calls, ["breathUpdateLatest"])
    }

    func testQuoteMidPathIsSwallowed() {
        world.outcomes["breathGo:a"] = .continuing(hint: nil)
        _ = press("'")
        _ = press("a")
        XCTAssertEqual(press("'"), [], "the double-tap only means update from the chain's root")
        XCTAssertEqual(core.state, .chain(kind: .breath, letters: ["a"], deleting: false))
    }

    func testQuoteWhileDeletingIsSwallowed() {
        _ = press("'")
        _ = press("delete")
        XCTAssertEqual(press("'"), [])
        XCTAssertEqual(core.state, .chain(kind: .breath, letters: [], deleting: true))
    }

    func testBreathBindAndGo() {
        world.outcomes["breathBind:w"] = .done(flash: "◎ breath W saved · 2 windows")
        _ = press("'")
        XCTAssertEqual(press("w", shift: true), [.hideGuide, .flash("◎ breath W saved · 2 windows")])

        world.outcomes["breathGo:w"] = .done(flash: nil)
        _ = press("'")
        XCTAssertEqual(press("w"), [.hideGuide])
        XCTAssertEqual(world.calls, ["breathBind:w", "breathGo:w"])
    }

    // MARK: - Scroll mode

    private func enterScrollMode() {
        _ = press(",")
        XCTAssertEqual(core.state, .scroll)
        world.calls = []
    }

    func testScrollDirectionKeys() {
        enterScrollMode()
        XCTAssertEqual(press("j", held: false), [.scrollCancelPendingG, .scrollDirectionDown("j")])
        XCTAssertEqual(press("k", held: false), [.scrollCancelPendingG, .scrollDirectionDown("k")])
        XCTAssertEqual(press("h", held: false), [.scrollCancelPendingG, .scrollDirectionDown("h")])
        XCTAssertEqual(press("l", held: false), [.scrollCancelPendingG, .scrollDirectionDown("l")])
    }

    func testScrollKeyUpsSwallowedOnlyForDirections() {
        enterScrollMode()
        XCTAssertEqual(core.keyUp(key: "j"), [.scrollDirectionUp("j")])
        XCTAssertEqual(core.keyUp(key: "s"), [.passThrough])
    }

    func testKeyUpsPassThroughOutsideScroll() {
        XCTAssertEqual(core.keyUp(key: "j"), [.passThrough])
    }

    func testScrollHalfPagesAndEnds() {
        enterScrollMode()
        XCTAssertEqual(press("d", held: false), [.scrollCancelPendingG, .scrollHalfPage(down: true)])
        XCTAssertEqual(press("u", held: false), [.scrollCancelPendingG, .scrollHalfPage(down: false)])
        XCTAssertEqual(press("g", held: false), [.scrollTapG], "gg is the scroller's two-tap")
        XCTAssertEqual(press("g", held: false, shift: true), [.scrollCancelPendingG, .scrollToBottom])
    }

    func testScrollTabCyclesPanes() {
        enterScrollMode()
        XCTAssertEqual(press("tab", held: false), [.scrollCancelPendingG, .scrollCyclePane, .scrollGuide])
    }

    func testScrollSwallowsPlainTyping() {
        enterScrollMode()
        XCTAssertEqual(press("s", held: false), [.scrollCancelPendingG], "mode discipline")
        XCTAssertEqual(core.state, .scroll)
    }

    func testScrollEscapeExits() {
        enterScrollMode()
        XCTAssertEqual(press("escape", held: false), [.scrollCancelPendingG, .scrollExit, .hideGuide])
        XCTAssertEqual(core.state, .idle)
    }

    func testScrollHyperJAndEscapeExitQuietly() {
        enterScrollMode()
        XCTAssertEqual(press("j"), [.scrollExit, .hideGuide])
        XCTAssertEqual(core.state, .idle)

        enterScrollMode()
        XCTAssertEqual(press("escape"), [.scrollExit, .hideGuide])
        XCTAssertEqual(core.state, .idle)
    }

    func testScrollExitAndExecute() {
        world.graph = ["s": .leaf]
        enterScrollMode()
        XCTAssertEqual(press("s"),
                       [.scrollExit, .hideGuide, .hideGuide, .summonGraph(letters: ["s"], beside: false)],
                       "any other hyper verb exits and executes immediately")
        XCTAssertEqual(core.state, .idle)
    }

    func testScrollExitAndExecutePassesUnboundKeys() {
        enterScrollMode()
        XCTAssertEqual(press("-"), [.scrollExit, .hideGuide, .passThrough])
        XCTAssertEqual(core.state, .idle)
    }

    func testScrollCommaTogglesBackIn() {
        enterScrollMode()
        let effects = press(",")
        XCTAssertEqual(effects, [.scrollExit, .hideGuide, .hideBars, .enterScroll, .scrollGuide])
        XCTAssertEqual(core.state, .scroll, "comma exits and immediately re-enters — a toggle")
    }
}
