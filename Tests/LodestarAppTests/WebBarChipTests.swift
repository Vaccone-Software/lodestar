import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Ask bar's chip: the profile's name always, and a pin before it
/// only when a pin or a rule decided the profile — never for a guess.
final class WebBarChipTests: XCTestCase {
    private func config() -> Config {
        let json = """
        {
          "web": {
            "links": {
              "docs": { "url": "developer.apple.com/documentation", "profile": "brave:Work" },
              "hn": { "url": "news.ycombinator.com" }
            },
            "routes": { "github.com": "brave:Work" },
            "fallback": "brave:Personal"
          }
        }
        """
        var problems: [String] = []
        let config = Config.build(from: (try? Json.parse(json)) ?? [:], problems: &problems)
        XCTAssertEqual(problems, [])
        return config
    }

    func testAPinnedLinkWearsThePinAndAnUnpinnedOneDoesNot() {
        let bar = WebBarController.preview(query: "", config: config())
        defer { bar.hide() }
        XCTAssertEqual(bar.shownSources, ["pinned", "fallback"])
        XCTAssertEqual(bar.shownMarks, [true, false], "chosen wears the pin; inferred is bare")
    }

    func testARuleIsAChoiceTooAndAGuessIsNot() {
        let routed = WebBarController.preview(query: "github.com/vaccone-software", config: config())
        XCTAssertEqual(routed.shownSources, ["route", "route"], "the pattern matches the domain and the search alike")
        XCTAssertEqual(routed.shownMarks, [true, true])
        routed.hide()
        let guessed = WebBarController.preview(query: "example.com", config: config())
        defer { guessed.hide() }
        XCTAssertEqual(guessed.shownSources, ["fallback", "fallback"])
        XCTAssertEqual(guessed.shownMarks, [false, false])
    }

    func testNothingDecidedSaysInferredNotDefault() {
        XCTAssertEqual(ProfileResolution.Source.none.label, "inferred", "a profile can be named Default; a guess must not be")
        XCTAssertTrue(ProfileResolution.Source.recent.isInferred)
        XCTAssertFalse(ProfileResolution.Source.route("x").isInferred)
    }
}
