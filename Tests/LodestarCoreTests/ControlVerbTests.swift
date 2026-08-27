import XCTest
@testable import LodestarCore

final class ControlVerbTests: XCTestCase {
    private func parse(_ args: String...) -> Result<ControlVerb, ControlError> {
        ControlParse.parse(args)
    }

    private func verb(_ args: String...) -> ControlVerb? {
        try? ControlParse.parse(args).get()
    }

    private func failure(_ args: String...) -> String? {
        if case .failure(let error) = ControlParse.parse(args) { return error.message }
        return nil
    }

    func testGoCarriesBothReadings() {
        XCTAssertEqual(verb("go", "g"), .go(query: ["g"], beside: false))
        XCTAssertEqual(verb("go", "e", "p"), .go(query: ["e", "p"], beside: false))
        XCTAssertEqual(verb("go", "Proton", "Mail"),
                       .go(query: ["Proton", "Mail"], beside: false))
    }

    /// A shell does not enforce flag order and neither should this.
    func testBesideIsPositionIndependent() {
        XCTAssertEqual(verb("go", "g", "--beside"), .go(query: ["g"], beside: true))
        XCTAssertEqual(verb("go", "--beside", "g"), .go(query: ["g"], beside: true))
        XCTAssertEqual(verb("layout", "fill", "--beside"), .layout(.fill(beside: true)))
    }

    func testGoNeedsATarget() {
        XCTAssertNotNil(failure("go"))
        XCTAssertNotNil(failure("go", "--beside"))
    }

    func testUnknownOptionIsRefusedRatherThanIgnored() {
        XCTAssertNotNil(failure("go", "g", "--besides"))
    }

    func testWeb() {
        XCTAssertEqual(verb("web", "https://example.com"),
                       .web(url: "https://example.com", profile: nil))
        XCTAssertEqual(verb("web", "https://example.com", "--profile", "brave:Xonar"),
                       .web(url: "https://example.com", profile: "brave:Xonar"))
        XCTAssertEqual(verb("web", "--profile", "brave:Xonar", "https://example.com"),
                       .web(url: "https://example.com", profile: "brave:Xonar"))
    }

    func testWebEdges() {
        XCTAssertNotNil(failure("web"))
        XCTAssertNotNil(failure("web", "--profile"))
        XCTAssertNotNil(failure("web", "--profile", "brave:Xonar"))
    }

    func testLayout() {
        XCTAssertEqual(verb("layout", "undo"), .layout(.undo))
        XCTAssertEqual(verb("layout", "redo"), .layout(.redo))
        XCTAssertEqual(verb("layout", "flip"), .layout(.flip))
        XCTAssertEqual(verb("layout", "fill"), .layout(.fill(beside: false)))
        XCTAssertEqual(verb("layout", "index", "3"), .layout(.index(3)))
    }

    /// The socket may name exactly the addresses a hand may name.
    func testIndexIsBoundedToTheKeysThatExist() {
        XCTAssertNotNil(failure("layout", "index", "0"))
        XCTAssertNotNil(failure("layout", "index", "10"))
        XCTAssertNotNil(failure("layout", "index", "-1"))
        XCTAssertNotNil(failure("layout", "index", "three"))
        XCTAssertNotNil(failure("layout", "index"))
        XCTAssertEqual(verb("layout", "index", "9"), .layout(.index(9)))
    }

    func testLayoutEdges() {
        XCTAssertNotNil(failure("layout"))
        XCTAssertNotNil(failure("layout", "sideways"))
    }

    func testBreath() {
        XCTAssertEqual(verb("breath", "gb"), .breath(.go(["g", "b"])))
        XCTAssertEqual(verb("breath", "g", "b"), .breath(.go(["g", "b"])))
        XCTAssertEqual(verb("breath", "save", "gb"), .breath(.save(["g", "b"])))
        XCTAssertEqual(verb("breath", "delete", "g", "b"), .breath(.delete(["g", "b"])))
    }

    func testBreathEdges() {
        XCTAssertNotNil(failure("breath"))
        XCTAssertNotNil(failure("breath", "save"))
        XCTAssertNotNil(failure("breath", "delete"))
    }

    func testAddressSpellingsAgree() {
        XCTAssertEqual(ControlParse.address(["ep"]), ["e", "p"])
        XCTAssertEqual(ControlParse.address(["e", "p"]), ["e", "p"])
        XCTAssertEqual(ControlParse.address(["EP"]), ["e", "p"])
        XCTAssertNil(ControlParse.address([]))
        XCTAssertNil(ControlParse.address(["--beside"]))
    }

    func testStateAndUnknown() {
        XCTAssertEqual(verb("state"), .state)
        XCTAssertNotNil(failure("summon", "g"))
        if case .failure = parse() {} else { XCTFail("an empty argument list is not a verb") }
    }
}
