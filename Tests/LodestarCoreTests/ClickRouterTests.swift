import XCTest
@testable import LodestarCore

/// The decision for a link clicked in another app. The contract is mostly
/// about what it refuses to do: pass through unless a rule says otherwise,
/// and never answer a question nobody asked.
final class ClickRouterTests: XCTestCase {
    private let personal = BrowserProfile(browser: .brave, display: "Personal")
    private let work = BrowserProfile(browser: .chrome, display: "Work")

    private func context(routes: [String: String] = ["x.com": "personal", "acme": "work"],
                         enabled: Bool = true,
                         links: [Config.WebLink] = [],
                         fallback: String = "most-recent",
                         mostRecent: BrowserProfile? = nil) -> WebContext {
        WebContext(links: links, routes: routes,
                   profiles: ["personal": personal, "work": work],
                   fallback: fallback, mostRecent: mostRecent, handlesClicks: enabled)
    }

    func testARuleDiverts() {
        XCTAssertEqual(ClickRouter.route("https://x.com/friend/status/1", in: context()),
                       .profile(personal, pattern: "x.com"))
        XCTAssertEqual(ClickRouter.route("https://app.acme.dev/board", in: context()),
                       .profile(work, pattern: "acme"))
    }

    func testNoRuleMeansNothingHappens() {
        XCTAssertEqual(ClickRouter.route("https://stripe.com/docs", in: context()), .passThrough)
        XCTAssertEqual(ClickRouter.route("https://example.com", in: context(routes: [:])),
                       .passThrough)
    }

    func testAnUnroutedLinkIgnoresTheFallbackAndTheMostRecentBrowser() {
        // The line that keeps the feature invisible. web.fallback and
        // most-recent are answers to text typed into the bar; a clicked link
        // that matches no rule is not a question, and answering it would move
        // links that used to open where they always did.
        let opinionated = context(routes: [:], fallback: "work", mostRecent: personal)
        XCTAssertEqual(ClickRouter.route("https://stripe.com", in: opinionated), .passThrough)
    }

    func testNamedLinksDoNotParticipate() {
        // A link is an address you type. It says nothing about where a link
        // someone sent you should open.
        let withLink = context(routes: [:],
                              links: [Config.WebLink(name: "yt", url: "youtube.com",
                                                     profileKey: "work")])
        XCTAssertEqual(ClickRouter.route("https://youtube.com/watch?v=1", in: withLink),
                       .passThrough)
    }

    func testStandingDownPassesEverythingThrough() {
        // Still the registered handler, but transparent: the off switch that
        // works from a text file.
        XCTAssertEqual(ClickRouter.route("https://x.com/anything", in: context(enabled: false)),
                       .passThrough)
    }

    func testOnlyTheWebIsOurs() {
        for url in ["file:///Users/vac/notes.txt", "mailto:someone@example.com",
                    "zoommtg://zoom.us/join?confno=1", "javascript:alert(1)",
                    "data:text/html,<h1>x.com</h1>", "x.com/no-scheme"] {
            XCTAssertEqual(ClickRouter.route(url, in: context()), .passThrough, url)
        }
        // Case in the scheme is not a reason to be clever either.
        XCTAssertEqual(ClickRouter.route("HTTPS://X.COM/a", in: context()),
                       .profile(personal, pattern: "x.com"))
    }

    func testARuleNamingAMissingProfileStrandsNothing() {
        // A renamed browser profile is flagged at reload. It is not a reason
        // to lose the link.
        let stale = context(routes: ["x.com": "deleted-profile"])
        XCTAssertEqual(ClickRouter.route("https://x.com/a", in: stale), .passThrough)
    }

    func testLongestPatternWinsAsItDoesEverywhereElse() {
        let overlapping = context(routes: ["youtube": "work", "music.youtube": "personal"])
        XCTAssertEqual(ClickRouter.route("https://youtube.com/feed", in: overlapping),
                       .profile(work, pattern: "youtube"))
        XCTAssertEqual(ClickRouter.route("https://music.youtube.com/playlist", in: overlapping),
                       .profile(personal, pattern: "music.youtube"))
    }

    func testTheURLIsNeverRewritten() {
        // A clicked URL arrives complete. Normalizing it — which is for text
        // *you* typed — risks mangling a query string or a fragment, and the
        // router must not be tempted: it returns a decision, never a URL.
        let awkward = "https://x.com/search?q=a%20b&t=1#frag/../%2E%2E"
        guard case .profile(_, let pattern) = ClickRouter.route(awkward, in: context()) else {
            return XCTFail("expected a route")
        }
        XCTAssertEqual(pattern, "x.com")
    }

    func testTheSelfCheckPassesForABuildThatRoutes() {
        // What the update watchdog asks a successor while Lodestar holds the
        // browser role. If a change to the router breaks this, the build gets
        // rolled back rather than shipped to a machine where every link
        // depends on it — so this test and that gate fail together.
        XCTAssertTrue(ClickRouter.selfCheck())
    }

    /// This runs between a click and a browser, on every link the machine
    /// opens. The budget for Lodestar's own contribution is "invisible", so it
    /// is measured rather than assumed — the rest of the hop is LaunchServices
    /// and has to be measured on a real machine.
    func testTheDecisionIsFreeAtAnyPlausibleScale() {
        // Twenty rules is already a heavily-configured machine; the cost is
        // linear in the table, so this is the shape of the real thing rather
        // than a stress test that measures nothing anyone will run.
        let routes = Dictionary(uniqueKeysWithValues: (0..<19).map { ("pattern\($0).example", "work") })
            .merging(["x.com": "personal"]) { a, _ in a }
        let context = context(routes: routes)
        let urls = (0..<10_000).map { "https://sub\($0).x.com/path/\($0)?q=\($0)" }
        let started = Date()
        var diverted = 0
        for url in urls where ClickRouter.route(url, in: context) != .passThrough { diverted += 1 }
        let elapsed = Date().timeIntervalSince(started)
        let each = elapsed / 10_000
        XCTAssertEqual(diverted, 10_000)
        // Measured at ~20µs per decision, and release is no faster than
        // debug: the time goes on lowercasing and substring searches in
        // stdlib code that is already optimized in both builds, not on bounds
        // checks. So one ceiling for both, with room for a slow machine.
        //
        // Twenty microseconds is four hundredths of one percent of the 50ms
        // budget for the whole click-to-browser hop, which is why this is not
        // worth optimizing. It is worth guarding: the assertion catches
        // somebody making this quadratic or reaching for a regex, not
        // micro-regressions nobody could feel.
        XCTAssertLessThan(each, 200.0e-6,
                          "\(String(format: "%.1f", each * 1_000_000))µs per decision")
        print("click routing over 20 rules: "
            + "\(String(format: "%.1f", each * 1_000_000))µs per decision")
    }
}
