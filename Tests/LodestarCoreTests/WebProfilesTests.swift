import XCTest
@testable import LodestarCore

/// Which profile a destination opens in, and what decided it. The precedence
/// is the whole contract: a pin beats a rule, a rule beats the fallback, the
/// fallback beats the browser you were last in.
final class WebProfilesTests: XCTestCase {
    private let google = BrowserProfile(browser: .brave, display: "Google")
    private let work = BrowserProfile(browser: .chrome, display: "Work")
    private let personal = BrowserProfile(browser: .brave, display: "Personal")

    private func context(routes: [String: String] = [:], fallback: String = "most-recent",
                         mostRecent: BrowserProfile? = nil) -> WebContext {
        WebContext(routes: routes,
                   profiles: ["google": google, "work": work, "personal": personal],
                   fallback: fallback, mostRecent: mostRecent)
    }

    func testPinBeatsEverything() {
        let resolved = context(routes: ["youtube": "google"], fallback: "personal",
                              mostRecent: work)
            .resolve(pinned: "work", routedOn: "youtube.com")
        XCTAssertEqual(resolved.profile, work)
        XCTAssertEqual(resolved.source, .pinned)
    }

    func testARuleBeatsTheFallbackAndNamesItsPattern() {
        let resolved = context(routes: ["youtube": "google"], fallback: "personal")
            .resolve(pinned: nil, routedOn: "music.youtube.com/playlist")
        XCTAssertEqual(resolved.profile, google)
        XCTAssertEqual(resolved.source, .route("youtube"))
        XCTAssertEqual(resolved.source.routePattern, "youtube")
        XCTAssertEqual(resolved.source.phrase, "matched youtube")
        XCTAssertEqual(resolved.source.label, "route")
    }

    func testRulesMatchQueriesNotJustHosts() {
        // The reason a search row is worth routing at all.
        let resolved = context(routes: ["acme": "work"])
            .resolve(pinned: nil, routedOn: "acme deploy runbook")
        XCTAssertEqual(resolved.profile, work)
        XCTAssertEqual(resolved.source, .route("acme"))
    }

    func testTheFallbackBeatsMostRecent() {
        let resolved = context(fallback: "personal", mostRecent: work)
            .resolve(pinned: nil, routedOn: "unrouted.com")
        XCTAssertEqual(resolved.profile, personal)
        XCTAssertEqual(resolved.source, .fallback)
    }

    func testMostRecentWhenTheFallbackDefersToIt() {
        let resolved = context(fallback: "most-recent", mostRecent: work)
            .resolve(pinned: nil, routedOn: "unrouted.com")
        XCTAssertEqual(resolved.profile, work)
        XCTAssertEqual(resolved.source, .recent)
        XCTAssertEqual(resolved.source.phrase, "most recent browser")
    }

    func testWithNothingToGoOnItStillNamesSomewhere() {
        // A destination always has somewhere to go, even with no browser open.
        let resolved = context().resolve(pinned: nil, routedOn: "unrouted.com")
        XCTAssertEqual(resolved.source, .none)
        XCTAssertEqual(resolved.profile, google) // alphabetically first display
        // And with no registry at all, something openable rather than nil.
        let bare = WebContext().resolve(pinned: nil, routedOn: "x.com")
        XCTAssertEqual(bare.source, .none)
        XCTAssertEqual(bare.profile.browser, .brave)
    }

    func testAPinToAnUnknownKeyFallsThroughRatherThanFailing() {
        // A renamed profile is flagged at reload; resolution must not die on it.
        let resolved = context(routes: ["youtube": "google"])
            .resolve(pinned: "deleted-profile", routedOn: "youtube.com")
        XCTAssertEqual(resolved.source, .route("youtube"))
    }

    func testProfileKeysAreSortedSoDigitsNeverShuffle() {
        XCTAssertEqual(context().profileKeys, ["google", "personal", "work"])
    }
}
