import XCTest
@testable import LodestarCore

/// Bring: `lode =`, its own search over every other window, and what a
/// match brings.
final class BringTests: XCTestCase {
    private var core = EngineCore()
    private var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func press(_ key: String, held: Bool = false, shift: Bool = false, command: Bool = false,
                       option: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, command: command, option: option, world: world)
    }

    func testLodeEqualsOpensBring() {
        XCTAssertEqual(press("=", held: true), [.hideBars])
        XCTAssertEqual(core.state, .bring(listing: false))
        XCTAssertTrue(world.calls.contains("enterBring:false"))
        XCTAssertEqual(press("=", held: true), [.exitBring], "lode = again closes it")
        XCTAssertEqual(core.state, .idle)
    }

    func testNothingInFrontSaysSo() {
        world.bringSucceeds = false
        XCTAssertEqual(press("=", held: true), [.hideBars, .flash("✕ nothing in front to bring into")])
        XCTAssertEqual(core.state, .idle)
    }

    /// Every character is the query; ⌥ names a card, ⏎ takes the best,
    /// ⇧ asks for the whole line.
    func testTheGrammarIsKeepsSearch() {
        _ = press("=", held: true)
        XCTAssertEqual(press("b"), [.bringType("b")])
        XCTAssertEqual(press("u"), [.bringType("u")])
        XCTAssertEqual(press("delete"), [.bringDelete(.character)])
        XCTAssertEqual(press("v", command: true), [.bringPaste])
        XCTAssertEqual(press("x", option: true), [], "⌥ with no card types nothing")
        XCTAssertEqual(press("k", option: true), [.bringPick(label: "k", line: false), .exitBring])
        XCTAssertEqual(core.state, .idle)
        _ = press("=", held: true)
        XCTAssertEqual(press("l", shift: true, option: true), [.bringPick(label: "l", line: true), .exitBring])
        _ = press("=", held: true)
        XCTAssertEqual(press("return", shift: true), [.bringCommit(line: true), .exitBring])
        _ = press("=", held: true)
        XCTAssertEqual(press("return"), [.bringCommit(line: false), .exitBring])
        _ = press("=", held: true)
        XCTAssertEqual(press("escape"), [.exitBring])
        XCTAssertEqual(core.state, .idle)
    }

    func testTabListsTheApps() {
        _ = press("=", held: true)
        XCTAssertEqual(press("tab"), [.bringSourceShow])
        XCTAssertEqual(core.state, .bring(listing: true))
        XCTAssertEqual(press("s"), [.bringSourceType("s")])
        XCTAssertEqual(press("down"), [.bringSourceMove(delta: 1)])
        XCTAssertEqual(press("return"), [.bringSourcePick])
        XCTAssertEqual(core.state, .bring(listing: false))
        _ = press("tab")
        XCTAssertEqual(press("escape"), [.bringSourceClose])
        XCTAssertEqual(core.state, .bring(listing: false), "the list closes, Bring stays")
    }

    /// ⇧⌘V over Bring: Bring goes and Keep opens in its place.
    func testKeepsChordMovesFromBringToKeep() {
        _ = press("=", held: true)
        XCTAssertEqual(core.openPaste(world: world), [.exitBring, .hideBars, .enterPaste])
        XCTAssertEqual(core.state, .paste(searching: false))
    }

    func testAClickElsewhereEndsBring() {
        _ = press("=", held: true)
        XCTAssertEqual(core.leavePaste(), [.exitBring])
        XCTAssertEqual(core.state, .idle)
    }

    // MARK: - The search

    private func lines(_ texts: [(Int, String)]) -> [Bring.Line] { texts.map { Bring.Line(source: $0.0, text: $0.1) } }
    private let sources = [Bring.Source(app: "Brave", window: "Runbook", rank: 0),
                           Bring.Source(app: "Slack", window: "#release", rank: 1)]

    /// The most recently used app first, then a hit at a word's start
    /// before one inside a word, then reading order; one line once.
    func testTheMostRecentAppAnswersFirst() {
        let found = Bring.search(lines([(1, "deploy is on build-03 today"),
                                        (0, "rebuild the cache"),
                                        (0, "Connect to the build host first: build-02.internal"),
                                        (1, "Connect to the build host first: build-02.internal")]),
                                 sources: sources, query: "build")
        XCTAssertEqual(found.matches.map(\.line), ["Connect to the build host first: build-02.internal",
                                                    "rebuild the cache",
                                                    "deploy is on build-03 today"])
        XCTAssertEqual(found.total, 3)
        XCTAssertEqual(found.matches.first?.source, 0, "the duplicate answers from the more recent app")
    }

    /// A pick brings the token around the hit, trimmed; ⇧ the line.
    func testAMatchBringsItsTokenOrItsLine() throws {
        let found = Bring.search(lines([(0, "  at Bar.render (web/src/bar.ts:42:17)  ")]),
                                 sources: sources, query: "src/bar")
        let match = try XCTUnwrap(found.matches.first)
        XCTAssertEqual(match.tokenText, "web/src/bar.ts:42:17")
        XCTAssertEqual(match.lineText, "at Bar.render (web/src/bar.ts:42:17)")
    }

    func testAOneLetterQueryAnswersNothingYet() {
        XCTAssertEqual(Bring.search(lines([(0, "a b c")]), sources: sources, query: "a").total, 0)
        XCTAssertEqual(Bring.search(lines([(0, "Café open")]), sources: sources, query: "cafe").total, 1,
                       "accents fold")
    }

    func testAWindowsTextBecomesLines() {
        XCTAssertEqual(Bring.lines(of: "one\n\n  two  \none\r\nthree"), ["one", "two", "three"])
        XCTAssertEqual(Bring.lines(of: String(repeating: "x", count: 900)).first?.count, Bring.longestLine)
    }

    private func taken(_ line: String, _ word: String) -> String {
        let text = line as NSString
        return text.substring(with: SelectCore.bringRange(text.range(of: word), in: text, size: 0))
    }

    func testTheTokenIsTrimmedOfWhatEnclosesIt() {
        XCTAssertEqual(taken("the host is \"build-02.internal\", today", "build"), "build-02.internal")
        XCTAssertEqual(taken("version 1.2.3.", "1.2"), "1.2.3")
        XCTAssertEqual(taken("(x)", "x"), "x")
    }
}
