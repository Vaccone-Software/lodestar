import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Ask bar names the inferred profile once, at the end of its field,
/// and a row names its own profile only when a pin or a rule sends it
/// somewhere else: the exceptions, and nothing that repeats.
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

    func testTheFieldNamesTheInferredProfileAndOnlyAPinnedLinkNamesItsOwn() {
        let bar = WebBarController.preview(query: "", config: config())
        defer { bar.hide() }
        XCTAssertEqual(bar.shownInferred, "Personal", "web.fallback, said once")
        XCTAssertEqual(bar.shownSources, ["pinned", "fallback"])
        XCTAssertEqual(bar.shownExceptions, [true, false], "the pinned link goes to Work; the other goes where the field says")
    }

    func testARuleIsAnExceptionAndAGuessIsNot() {
        let routed = WebBarController.preview(query: "github.com/vaccone-software", config: config())
        XCTAssertEqual(routed.shownSources, ["route", "route"], "the pattern matches the domain and the search alike")
        XCTAssertEqual(routed.shownExceptions, [true, true])
        routed.hide()
        let guessed = WebBarController.preview(query: "example.com", config: config())
        defer { guessed.hide() }
        XCTAssertEqual(guessed.shownSources, ["fallback", "fallback"])
        XCTAssertEqual(guessed.shownExceptions, [false, false], "both go where the field says, so neither repeats it")
    }

    func testAPinToTheInferredProfileIsNotAnException() {
        let json = """
        { "web": { "links": { "home": { "url": "example.com", "profile": "brave:Personal" } }, "fallback": "brave:Personal" } }
        """
        var problems: [String] = []
        let config = Config.build(from: (try? Json.parse(json)) ?? [:], problems: &problems)
        let bar = WebBarController.preview(query: "", config: config)
        defer { bar.hide() }
        XCTAssertEqual(bar.shownSources, ["pinned"])
        XCTAssertEqual(bar.shownExceptions, [false], "it goes where the field already says")
    }

    func testNothingDecidedSaysInferredNotDefault() {
        XCTAssertEqual(ProfileResolution.Source.none.label, "inferred", "a profile can be named Default; a guess must not be")
        XCTAssertTrue(ProfileResolution.Source.recent.isInferred)
        XCTAssertFalse(ProfileResolution.Source.route("x").isInferred)
    }
}
