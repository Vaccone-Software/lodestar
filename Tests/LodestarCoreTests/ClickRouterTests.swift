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

    // MARK: - The hand-off target

    /// The whole bug in one assertion. A `web.clicks.browser` naming us was
    /// obeyed literally: macOS handed the link to Lodestar because Lodestar
    /// held the http role, `handOff` handed it back to Lodestar, and each lap
    /// arrived with `activates: true`. Nil is the answer that sends the click
    /// path on to discovery and then Safari.
    func testTheHandOffRefusesLodestarItself() {
        XCTAssertNil(ClickRouter.handoffBrowser(Lodestar.bundleID))
    }

    func testTheHandOffRefusesNothingRecorded() {
        XCTAssertNil(ClickRouter.handoffBrowser(""))
    }

    func testTheHandOffKeepsARealBrowser() {
        XCTAssertEqual(ClickRouter.handoffBrowser("com.brave.Browser"), "com.brave.Browser")
        XCTAssertEqual(ClickRouter.handoffBrowser("com.apple.Safari"), "com.apple.Safari")
    }

    /// The boot check gates a self-update rollback, so the refusal has to be
    /// part of what a build proves about itself before it is blessed.
    func testTheSelfCheckCoversTheRefusal() {
        XCTAssertTrue(ClickRouter.selfCheck())
    }
}

/// The backstop that does not depend on knowing the cause: whatever puts a
/// link back in front of us, it may only happen a few times before the
/// circuit is cut.
final class ClickLoopGuardTests: XCTestCase {
    private let link = "https://claude.ai/chat"

    func testOrdinaryClickingIsNeverRefused() {
        var guard1 = ClickLoopGuard()
        // Different links, and the same link revisited across the day.
        for second in stride(from: 0.0, to: 600.0, by: 30.0) {
            XCTAssertTrue(guard1.admit(link, at: second), "at \(second)s")
            XCTAssertTrue(guard1.admit("https://example.com/\(second)", at: second))
        }
    }

    /// A double click, and an impatient run of them, all still open. Twenty
    /// deliberate opens of one URL at human speed is already implausible;
    /// this asserts the ceiling is above it and not at it.
    func testAHumanBeingImpatientIsNeverRefused() {
        var loop = ClickLoopGuard()
        for lap in 0..<ClickLoopGuard.limit {
            XCTAssertTrue(loop.admit(link, at: Double(lap) * 0.25), "lap \(lap)")
        }
    }

    /// The measured shape of the real failure: the same URL, back in eight
    /// milliseconds, for as long as the process lives. The budget is spent
    /// once and never restored, because the laps never stop arriving — which
    /// is the whole point of ageing on quiet rather than on elapsed time.
    func testACircuitIsCutOnceAndStaysCut() {
        var loop = ClickLoopGuard()
        var admitted = 0
        // Forty seconds of circuit — four times the window, which the
        // first draft of this guard let through as four fresh budgets.
        for lap in 0..<5_000 where loop.admit(link, at: Double(lap) * 0.008) {
            admitted += 1
        }
        XCTAssertEqual(admitted, ClickLoopGuard.limit)
    }

    /// A refusal is a fuse, not a ban. Once the laps stop — and they stop
    /// because refusing is what stops them — the entry ages out, and the
    /// user who clicks that link again later gets their browser.
    func testTheRefusalAgesOut() {
        var loop = ClickLoopGuard()
        var last = 0.0
        for lap in 0...ClickLoopGuard.limit {
            last = Double(lap) * 0.008
            _ = loop.admit(link, at: last)
        }
        XCTAssertFalse(loop.admit(link, at: last + 0.008))
        XCTAssertFalse(loop.admit(link, at: last + ClickLoopGuard.window - 0.5))
        XCTAssertTrue(loop.admit(link, at: last + ClickLoopGuard.window * 2))
    }

    /// One link looping must not close the door on every other link.
    func testOneLoopingLinkDoesNotBlockTheRest() {
        var loop = ClickLoopGuard()
        for lap in 0...(ClickLoopGuard.limit * 3) { _ = loop.admit(link, at: Double(lap) * 0.008) }
        XCTAssertFalse(loop.admit(link, at: 0.5))
        XCTAssertTrue(loop.admit("https://insight.xonar.com", at: 0.5))
    }

    /// The table is pruned by the same quiet rule it judges by, so a long
    /// session of ordinary browsing does not accumulate.
    func testTheTableDoesNotGrowWithOrdinaryBrowsing() {
        var loop = ClickLoopGuard()
        for lap in 0..<2_000 {
            XCTAssertTrue(loop.admit("https://example.com/\(lap)", at: Double(lap) * 30))
        }
        XCTAssertEqual(loop.tracked, 1)
    }
}
