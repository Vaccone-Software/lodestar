import XCTest
@testable import LodestarCore

/// Bring: `lode =`, select's machine at its own door, and what each size
/// of the chosen text takes.
final class BringTests: XCTestCase {
    func testLodeEqualsEntersBring() {
        var core = EngineCore()
        let world = WorldStub()
        let effects = core.keyDown(key: "=", held: true, shift: false, world: world)
        XCTAssertEqual(effects, [.hideBars])
        XCTAssertEqual(core.state, .select)
        XCTAssertTrue(world.calls.contains("enterBring:false"))
    }

    func testNoWindowSaysSo() {
        var core = EngineCore()
        let world = WorldStub()
        world.bringSucceeds = false
        XCTAssertEqual(core.keyDown(key: "=", held: true, shift: false, world: world),
                       [.hideBars, .flash("✕ no window to bring from")])
        XCTAssertEqual(core.state, .idle)
    }

    private func taken(_ line: String, _ word: String, size: Int) -> String {
        let text = line as NSString
        let range = SelectCore.bringRange(text.range(of: word), in: text, size: size)
        return text.substring(with: range)
    }

    /// The token comes without what encloses it: a path in a stack trace
    /// without its parenthesis, a word without its comma or its quotes.
    func testTheTokenIsTrimmedOfWhatEnclosesIt() {
        XCTAssertEqual(taken("at Bar.render (web/src/bar.ts:42:17)", "bar", size: 0), "web/src/bar.ts:42:17")
        XCTAssertEqual(taken("the host is \"build-02.internal\", today", "build", size: 0), "build-02.internal")
        XCTAssertEqual(taken("ssh build-02.internal", "build", size: 0), "build-02.internal")
        XCTAssertEqual(taken("version 1.2.3.", "1.2", size: 0), "1.2.3")
        XCTAssertEqual(taken("(x)", "x", size: 0), "x")
    }

    /// The next size is the whole line, without its edges' whitespace.
    func testTheNextSizeIsTheLine() {
        XCTAssertEqual(taken("   npm run build -- --watch  ", "build", size: 1), "npm run build -- --watch")
    }
}
