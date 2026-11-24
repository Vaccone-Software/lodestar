import XCTest
@testable import LodestarCore

/// Bring: `=` in Keep, its own search over every other window, and what a
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

    /// Bring opens from Keep, by `=`; it has no shortcut of its own.
    private func openBring() {
        _ = core.openPaste(world: world)
        _ = press("=")
    }

    func testEqualsInKeepOpensBring() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(press("="), [.exitPaste])
        XCTAssertEqual(core.state, .bring(listing: false))
        XCTAssertTrue(world.calls.contains("enterBring:false"))
        XCTAssertEqual(press("=", held: true), [.exitBring, .passThrough], "lode = is no gesture: it leaves and passes on, as in any mode")
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(press("=", held: true), [.passThrough], "and at idle it passes through")
    }

    func testNothingInFrontKeepsKeep() {
        world.bringSucceeds = false
        _ = core.openPaste(world: world)
        XCTAssertEqual(press("="), [])
        XCTAssertEqual(core.state, .paste(searching: false))
    }

    /// One escape per thing opened: Bring steps back to Keep, then Keep
    /// closes.
    func testEscapeStepsBackToKeep() {
        openBring()
        XCTAssertEqual(press("escape"), [.exitBring, .enterPaste])
        XCTAssertEqual(core.state, .paste(searching: false))
        XCTAssertEqual(press("escape"), [.exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    /// Every character is the query; ⌥ names a card, ⏎ takes the best,
    /// ⇧ asks for the whole line.
    func testTheGrammarIsKeepsSearch() {
        openBring()
        XCTAssertEqual(press("b"), [.bringType("b")])
        XCTAssertEqual(press("u"), [.bringType("u")])
        XCTAssertEqual(press("delete"), [.bringDelete(.character)])
        XCTAssertEqual(press("v", command: true), [.bringPaste])
        XCTAssertEqual(press("x", option: true), [], "⌥ with no card types nothing")
        XCTAssertEqual(press("k", option: true), [.bringPick(label: "k", line: false), .exitBring])
        XCTAssertEqual(core.state, .idle)
        openBring()
        XCTAssertEqual(press("l", shift: true, option: true), [.bringPick(label: "l", line: true), .exitBring])
        openBring()
        XCTAssertEqual(press("return", shift: true), [.bringCommit(line: true), .exitBring])
        openBring()
        XCTAssertEqual(press("return"), [.bringCommit(line: false), .exitBring])
    }

    func testTabListsTheApps() {
        openBring()
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

    /// Bring lives inside Keep: ⇧⌘V closes both.
    func testKeepsChordClosesBring() {
        openBring()
        XCTAssertEqual(core.openPaste(world: world), [.exitBring])
        XCTAssertEqual(core.state, .idle)
    }

    func testAClickElsewhereEndsBring() {
        openBring()
        XCTAssertEqual(core.leavePaste(), [.exitBring])
        XCTAssertEqual(core.state, .idle)
    }

    /// `=` turns an empty search to Bring; with words typed it is a
    /// character, so `FOO=` and `?id=` can be searched for.
    func testEqualsTypesOnceASearchHasWords() {
        _ = core.openPaste(world: world)
        _ = press("/")
        world.queryEmpty = false
        XCTAssertEqual(press("="), [.pasteSearchType("=")])
        XCTAssertEqual(core.state, .paste(searching: true))
        world.queryEmpty = true
        XCTAssertEqual(press("="), [.exitPaste])
        XCTAssertEqual(core.state, .bring(listing: false))
    }

    /// A miss never closes Bring or loses the words typed.
    func testAMissStaysInBring() {
        openBring()
        world.bringCards = []
        _ = press("b")
        XCTAssertEqual(press("return"), [.flash("⌂ nothing to bring yet")])
        XCTAssertEqual(core.state, .bring(listing: false))
        world.bringCards = ["j"]
        XCTAssertEqual(press("k", option: true), [], "no card on K")
        XCTAssertEqual(core.state, .bring(listing: false))
        XCTAssertEqual(press("j", option: true), [.bringPick(label: "j", line: false), .exitBring])
    }

    /// ⌃ on a card with no reading does nothing, in Keep and its search.
    func testControlWithoutAReadingStaysInKeep() {
        world.readings = ["s"]
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "a", held: false, shift: false, control: true, world: world), [])
        XCTAssertEqual(core.state, .paste(searching: false))
        XCTAssertEqual(core.keyDown(key: "s", held: false, shift: false, control: true, world: world),
                       [.pasteRecent(label: "s", action: .reading), .exitPaste])
        _ = core.openPaste(world: world)
        _ = press("/")
        XCTAssertEqual(core.keyDown(key: "return", held: false, shift: false, control: true, world: world), [],
                       "the best match has none")
        XCTAssertEqual(core.state, .paste(searching: true))
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

    /// A closer stays when its opener is inside; a pair around the whole
    /// token goes.
    func testTrimmingKeepsBalancedBrackets() {
        XCTAssertEqual(taken("call getUser(id) now", "getUser"), "getUser(id)")
        XCTAssertEqual(taken("read a[0] first", "a[0"), "a[0]")
        XCTAssertEqual(taken("at (web/src/bar.ts:42:17)", "bar"), "web/src/bar.ts:42:17")
        XCTAssertEqual(taken("see (getUser(id)).", "getUser"), "getUser(id)")
    }

    func testTheTokenIsTrimmedOfWhatEnclosesIt() {
        XCTAssertEqual(taken("the host is \"build-02.internal\", today", "build"), "build-02.internal")
        XCTAssertEqual(taken("version 1.2.3.", "1.2"), "1.2.3")
        XCTAssertEqual(taken("(x)", "x"), "x")
    }
}
