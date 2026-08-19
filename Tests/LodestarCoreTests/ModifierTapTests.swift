import XCTest
@testable import LodestarCore

final class ModifierTapTests: XCTestCase {
    private var detector = ModifierTapDetector()
    private let cmd = CGEventFlags.maskCommand
    private let none = CGEventFlags()

    override func setUp() {
        detector = ModifierTapDetector()
        detector.bindings = [.cmd: .scroll]
    }

    /// One press-release of a solo modifier.
    private func tap(_ flags: CGEventFlags, at time: TimeInterval) -> TapVerb? {
        _ = detector.flagsChanged(flags, at: time)
        return detector.flagsChanged(none, at: time + 0.05)
    }

    func testDoubleTapFires() {
        XCTAssertNil(tap(cmd, at: 0))
        XCTAssertEqual(tap(cmd, at: 0.2), .scroll)
    }

    func testSingleTapIsSilent() {
        XCTAssertNil(tap(cmd, at: 0))
    }

    func testSlowSecondTapStartsOver() {
        XCTAssertNil(tap(cmd, at: 0))
        XCTAssertNil(tap(cmd, at: 1.0), "outside the window — becomes a fresh first tap")
        XCTAssertEqual(tap(cmd, at: 1.2), .scroll)
    }

    func testHeldModifierIsNotATap() {
        _ = detector.flagsChanged(cmd, at: 0)
        XCTAssertNil(detector.flagsChanged(none, at: 0.8), "held too long")
        XCTAssertNil(tap(cmd, at: 1.0), "and it never counted as a first tap")
    }

    func testKeystrokePoisonsTheGesture() {
        _ = detector.flagsChanged(cmd, at: 0)
        detector.keyDown() // ⌘C
        XCTAssertNil(detector.flagsChanged(none, at: 0.1))
        XCTAssertNil(tap(cmd, at: 0.2), "the poisoned press is not a first tap")
        XCTAssertEqual(tap(cmd, at: 0.4), .scroll, "but the next pair fires")
    }

    func testChordIsNotATap() {
        _ = detector.flagsChanged(cmd, at: 0)
        _ = detector.flagsChanged([.maskCommand, .maskShift], at: 0.05)
        _ = detector.flagsChanged(cmd, at: 0.1)
        XCTAssertNil(detector.flagsChanged(none, at: 0.15))
        XCTAssertNil(tap(cmd, at: 0.3))
    }

    func testUnboundModifierDoesNothing() {
        XCTAssertNil(tap(.maskShift, at: 0))
        XCTAssertNil(tap(.maskShift, at: 0.2))
    }

    func testSidedBindingIgnoresOtherSide() {
        detector.bindings = [.rightCmd: .searcher]
        let rightCmd = CGEventFlags(rawValue: cmd.rawValue | 0x0010)
        let leftCmd = CGEventFlags(rawValue: cmd.rawValue | 0x0008)
        XCTAssertNil(tap(leftCmd, at: 0))
        XCTAssertNil(tap(leftCmd, at: 0.2), "left cmd is not bound")
        XCTAssertNil(tap(rightCmd, at: 1.0))
        XCTAssertEqual(tap(rightCmd, at: 1.2), .searcher)
    }

    func testGenericBindingMatchesEitherSide() {
        let rightCmd = CGEventFlags(rawValue: cmd.rawValue | 0x0010)
        XCTAssertNil(tap(rightCmd, at: 0))
        XCTAssertEqual(tap(rightCmd, at: 0.2), .scroll, "generic cmd binding, sided taps")
    }

    func testMixedSidesAreNotADoubleTap() {
        let rightCmd = CGEventFlags(rawValue: cmd.rawValue | 0x0010)
        let leftCmd = CGEventFlags(rawValue: cmd.rawValue | 0x0008)
        XCTAssertNil(tap(rightCmd, at: 0))
        XCTAssertNil(tap(leftCmd, at: 0.2), "two different physical keys")
    }

    func testVerbKeypressTable() {
        XCTAssertEqual(TapVerb.scroll.keypress.key, ",")
        XCTAssertEqual(TapVerb.stickyHints.keypress.key, ";")
        XCTAssertTrue(TapVerb.stickyHints.keypress.shift)
        XCTAssertEqual(TapVerb.cheat.keypress.key, "/")
        XCTAssertTrue(TapVerb.cheat.keypress.shift)
    }
}

final class GraphSugarTests: XCTestCase {
    private func build(_ table: [String: ConfigValue]) -> (GraphNode, [String]) {
        var problems: [String] = []
        let node = GraphNode.build(from: table, path: "", registry: [:], problems: &problems)
        return (node, problems)
    }

    func testMultiLetterKeyExpandsToNestedPath() {
        let (node, problems) = build(["eo": .string("Outlook")])
        XCTAssertTrue(problems.isEmpty)
        guard case .leaf(let target) = node.resolve(["e", "o"]) else {
            return XCTFail("eo should resolve")
        }
        XCTAssertEqual(target, .app("Outlook"))
        guard case .deeper = node.resolve(["e"]) else {
            return XCTFail("e alone subdivides")
        }
    }

    func testSugarMergesWithExplicitNesting() {
        let (node, problems) = build([
            "e": .table(["p": .string("Proton Mail")]),
            "eo": .string("Outlook"),
        ])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        guard case .leaf = node.resolve(["e", "o"]),
              case .leaf = node.resolve(["e", "p"]) else {
            return XCTFail("both children live under e")
        }
    }

    func testSugarShadowedByLeafIsRefused() {
        let (node, problems) = build([
            "e": .string("Mail"),
            "eo": .string("Outlook"),
        ])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("shadowed"))
        guard case .leaf(let target) = node.resolve(["e"]) else {
            return XCTFail("the leaf survives")
        }
        XCTAssertEqual(target, .app("Mail"))
    }

    func testTripleLetterPathsWork() {
        let (node, problems) = build(["wgg": .string("Deep")])
        XCTAssertTrue(problems.isEmpty)
        guard case .leaf = node.resolve(["w", "g", "g"]) else {
            return XCTFail("www-depth paths expand")
        }
    }

    func testDoubledLetterIsJustAPath() {
        let (node, problems) = build(["ww": .string("Brave")])
        XCTAssertTrue(problems.isEmpty)
        guard case .leaf = node.resolve(["w", "w"]) else {
            return XCTFail("lode W W")
        }
    }
}

final class DisabledGestureTests: XCTestCase {
    func testDisabledVerbPassesThrough() {
        var core = EngineCore()
        core.disabledGestures = ["o", "["]
        let world = WorldStub()
        XCTAssertEqual(core.keyDown(key: "o", held: true, shift: false, world: world), [.passThrough])
        XCTAssertEqual(core.keyDown(key: "[", held: true, shift: true, world: world), [.passThrough],
                       "shift variants ride along")
        XCTAssertEqual(core.keyDown(key: "left", held: true, shift: false, world: world),
                       [.undoLayout], "everything else untouched")
        XCTAssertEqual(core.state, .idle)
    }

    func testDisabledKeyStillDismissesCheat() {
        var core = EngineCore()
        core.disabledGestures = ["o"]
        let world = WorldStub()
        world.cheatVisible = true
        XCTAssertEqual(core.keyDown(key: "o", held: true, shift: false, world: world),
                       [.dismissCheat, .passThrough])
    }
}
