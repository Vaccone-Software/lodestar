import XCTest
@testable import LodestarCore

/// The ⌘K card's decisions, exercised without an app: which options a row
/// offers, what every key does in every state, and which write a return
/// commits.
final class WebMenuTests: XCTestCase {
    private let brave = { (name: String) in BrowserProfile(browser: .brave, display: name) }

    private func context(links: [Config.WebLink] = [],
                         routes: [String: String] = [:],
                         fallback: String = "most-recent",
                         mostRecent: BrowserProfile? = nil) -> WebContext {
        WebContext(links: links, routes: routes,
                   profiles: ["google": brave("Google"), "work": brave("Work"),
                              "personal": brave("Personal")],
                   fallback: fallback, mostRecent: mostRecent)
    }

    private let domain = WebMenu.Row(kind: .domain, raw: "youtube.com")
    private let search = WebMenu.Row(kind: .search, raw: "acme deploy runbook")
    private let link = WebMenu.Row(kind: .link, raw: "youtube.com", name: "yt")

    private func keys(_ menu: WebMenu, _ row: WebMenu.Row, _ context: WebContext) -> [String] {
        menu.options(for: row, in: context).items.map(\.key)
    }

    // MARK: - What each row offers

    func testOptionsPerRowKind() {
        let menu = WebMenu()
        let context = context()
        XCTAssertEqual(keys(menu, domain, context), ["a", "r"])
        XCTAssertEqual(keys(menu, link, context), ["r", "d"])
        // A search has no site to name, so it offers the pattern only — and
        // says why the other one is missing.
        XCTAssertEqual(keys(menu, search, context), ["r"])
        XCTAssertNotNil(menu.options(for: search, in: context).note)
        XCTAssertNil(menu.options(for: domain, in: context).note)
    }

    func testARowRoutedByARuleCanUndoThatRule() {
        // The card knows *why* the row goes where it goes, so the reason it
        // shows you is the thing it offers to remove.
        let menu = WebMenu()
        let routed = context(routes: ["youtube": "google"])
        XCTAssertEqual(keys(menu, domain, routed), ["a", "r", "x"])
        let remove = menu.options(for: domain, in: routed).items.last
        XCTAssertEqual(remove?.role, .removeRoute)
        XCTAssertEqual(remove?.detail, "youtube") // the pattern that matched
        // A pinned link never got there by a rule, so there is nothing to undo.
        let pinned = WebMenu.Row(kind: .link, raw: "youtube.com", name: "yt",
                                 pinnedProfileKey: "work")
        XCTAssertEqual(keys(menu, pinned, routed), ["r", "d"])
    }

    func testRemovesAreAlwaysLastSoReturnNeverFiresOne() {
        let menu = WebMenu()
        let routed = context(routes: ["youtube": "google"])
        for row in [domain, link, search] {
            let items = menu.options(for: row, in: routed).items
            let firstDestructive = items.firstIndex { $0.role.isDestructive }
            let lastBenign = items.lastIndex { !$0.role.isDestructive }
            if let firstDestructive, let lastBenign {
                XCTAssertLessThan(lastBenign, firstDestructive)
            }
            XCTAssertEqual(items.first?.role.isDestructive, false)
        }
    }

    // MARK: - Opening and closing

    func testToggleOpensAndCloses() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        XCTAssertEqual(menu.state, .options(domain))
        menu.toggle(on: domain, in: context)
        XCTAssertEqual(menu.state, .closed)
        // Nothing selected: nothing opens.
        menu.toggle(on: nil, in: context)
        XCTAssertFalse(menu.isOpen)
    }

    func testEscapeWalksBackOneLevelAtATime() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        guard case .compose = menu.state else { return XCTFail("expected compose") }
        _ = menu.handle(.tab, in: context)
        guard case .profiles = menu.state else { return XCTFail("expected profiles") }
        _ = menu.handle(.escape, in: context)
        guard case .compose = menu.state else { return XCTFail("expected compose") }
        _ = menu.handle(.escape, in: context)
        XCTAssertEqual(menu.state, .options(domain))
        XCTAssertEqual(menu.handle(.escape, in: context), .dismissed)
        XCTAssertEqual(menu.state, .closed)
    }

    // MARK: - Composing a link

    func testAddALinkEndToEnd() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        // The name arrives prefilled from the host, so ⏎ alone is the whole
        // gesture.
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "youtube")
        XCTAssertEqual(menu.handle(.enter, in: context),
                       .addLink(name: "youtube", url: "youtube.com", profileKey: nil))
    }

    func testTheFirstKeystrokeReplacesThePrefillWhole() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.enter, in: context) // ⏎ takes the primary option
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "youtube")
        _ = menu.handle(.character("y"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "y")
        _ = menu.handle(.character("t"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "yt")
        _ = menu.handle(.delete, in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "y")
        XCTAssertEqual(menu.handle(.enter, in: context),
                       .addLink(name: "y", url: "youtube.com", profileKey: nil))
    }

    func testDeleteClearsAnUntouchedPrefillWhole() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        _ = menu.handle(.delete, in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "")
        // Nothing to commit, and the card says so rather than writing.
        XCTAssertEqual(menu.handle(.enter, in: context), .nothing)
        XCTAssertEqual(menu.rendering(in: context).compose?.problem, true)
    }

    func testATakenNameBlocksTheWrite() {
        var menu = WebMenu()
        let taken = context(links: [Config.WebLink(name: "youtube", url: "youtu.be",
                                                  profileKey: nil)])
        menu.toggle(on: domain, in: taken)
        _ = menu.handle(.character("a"), in: taken)
        let compose = menu.rendering(in: taken).compose
        XCTAssertEqual(compose?.problem, true)
        XCTAssertEqual(compose?.verdict, "youtube is already youtu.be")
        XCTAssertEqual(menu.handle(.enter, in: taken), .nothing)
    }

    func testCharactersThatCannotBeInANameAreIgnored() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        _ = menu.handle(.character("y"), in: context)
        for illegal in [" ", ".", "/"] {
            _ = menu.handle(.character(Character(illegal)), in: context)
        }
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "y")
    }

    // MARK: - The profile control

    func testProfileDigitsPinAndZeroInherits() {
        var menu = WebMenu()
        let context = context(mostRecent: brave("Google"))
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.control?.detail, "Inherit")
        _ = menu.handle(.tab, in: context)
        // Sorted registry: google, personal, work.
        _ = menu.handle(.character("3"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.control?.detail, "Work")
        XCTAssertEqual(menu.handle(.enter, in: context),
                       .addLink(name: "youtube", url: "youtube.com", profileKey: "work"))
        _ = menu.handle(.tab, in: context)
        _ = menu.handle(.character("0"), in: context)
        XCTAssertEqual(menu.handle(.enter, in: context),
                       .addLink(name: "youtube", url: "youtube.com", profileKey: nil))
    }

    func testAnOutOfRangeDigitChangesNothing() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        _ = menu.handle(.tab, in: context)
        _ = menu.handle(.character("7"), in: context)
        guard case .profiles = menu.state else { return XCTFail("stays on the list") }
        XCTAssertEqual(menu.rendering(in: context).compose?.control?.detail, "Inherit")
    }

    func testTabTogglesTheProfileListBothWays() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        _ = menu.handle(.tab, in: context)
        XCTAssertNotNil(menu.rendering(in: context).profiles)
        _ = menu.handle(.tab, in: context)
        XCTAssertNil(menu.rendering(in: context).profiles)
        // The compose card never leaves while the list is open beside it.
        _ = menu.handle(.tab, in: context)
        XCTAssertNotNil(menu.rendering(in: context).compose)
    }

    func testWithNoRegistryThereIsNoProfileControlAtAll() {
        var menu = WebMenu()
        let bare = WebContext()
        menu.toggle(on: domain, in: bare)
        _ = menu.handle(.character("a"), in: bare)
        XCTAssertNil(menu.rendering(in: bare).compose?.control)
        _ = menu.handle(.tab, in: bare)
        XCTAssertNil(menu.rendering(in: bare).profiles) // ⇥ opens nothing
    }

    func testTheInheritRowNamesWhatItWouldResolveTo() {
        var menu = WebMenu()
        let routed = context(routes: ["youtube": "google"])
        menu.toggle(on: domain, in: routed)
        _ = menu.handle(.character("a"), in: routed)
        XCTAssertEqual(menu.rendering(in: routed).compose?.detail,
                       "opens in Google · matched youtube")
        _ = menu.handle(.tab, in: routed)
        let inherit = menu.rendering(in: routed).profiles?.items.first
        XCTAssertEqual(inherit?.title, "Inherit")
        XCTAssertEqual(inherit?.detail, "Google · route")
        XCTAssertEqual(inherit?.role, .choice(selected: true))
    }

    // MARK: - Composing a route

    func testARouteSeedsTheProfileItAlreadyResolvesTo() {
        var menu = WebMenu()
        let routed = context(routes: ["youtube": "personal"])
        menu.toggle(on: domain, in: routed)
        _ = menu.handle(.character("r"), in: routed)
        let compose = menu.rendering(in: routed).compose
        XCTAssertEqual(compose?.header, "Route by pattern")
        XCTAssertEqual(compose?.text, "youtube.com") // the whole host
        XCTAssertEqual(compose?.control?.detail, "Personal")
    }

    func testARouteFromASearchPrefillsTheFirstWord() {
        var menu = WebMenu()
        let context = context(mostRecent: brave("Work"))
        menu.toggle(on: search, in: context)
        XCTAssertEqual(menu.handle(.enter, in: context), .nothing) // begins the compose
        XCTAssertEqual(menu.rendering(in: context).compose?.text, "acme")
    }

    func testARouteRefusesWithoutAProfile() {
        var menu = WebMenu()
        let bare = WebContext() // no registry, so nothing to seed with
        menu.toggle(on: domain, in: bare)
        _ = menu.handle(.character("r"), in: bare)
        let compose = menu.rendering(in: bare).compose
        XCTAssertEqual(compose?.problem, true)
        XCTAssertEqual(compose?.verdict, "pick a profile — a route has to name one")
        XCTAssertEqual(menu.handle(.enter, in: bare), .nothing)
    }

    func testARouteHasNoInheritRowAndZeroDoesNothing() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("r"), in: context)
        _ = menu.handle(.tab, in: context)
        let items = menu.rendering(in: context).profiles?.items ?? []
        XCTAssertEqual(items.first?.title, "Google") // no Inherit ahead of it
        XCTAssertFalse(items.contains { $0.key == "0" })
        _ = menu.handle(.character("0"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.control?.detail, "Google")
    }

    func testARouteCommitsPatternAndProfile() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: search, in: context)
        _ = menu.handle(.character("r"), in: context)
        _ = menu.handle(.tab, in: context)
        _ = menu.handle(.character("2"), in: context) // personal
        XCTAssertEqual(menu.handle(.enter, in: context),
                       .addRoute(pattern: "acme", profileKey: "personal"))
    }

    // MARK: - Removing

    func testRemoveLinkAndRemoveRouteReportTheirTargets() {
        var menu = WebMenu()
        let routed = context(routes: ["youtube": "google"])
        menu.toggle(on: link, in: routed)
        XCTAssertEqual(menu.handle(.character("d"), in: routed), .removeLink(name: "yt"))
        menu.close()
        menu.toggle(on: link, in: routed)
        XCTAssertEqual(menu.handle(.character("x"), in: routed),
                       .removeRoute(pattern: "youtube"))
    }

    func testAFailedWriteKeepsTheCardOpenWithTheReason() {
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: domain, in: context)
        _ = menu.handle(.character("a"), in: context)
        _ = menu.handle(.enter, in: context)
        menu.failed("could not write the config")
        let compose = menu.rendering(in: context).compose
        XCTAssertEqual(compose?.problem, true)
        XCTAssertEqual(compose?.verdict, "could not write the config")
        // And it does not keep trying to write while the reason stands.
        XCTAssertEqual(menu.handle(.enter, in: context), .nothing)
        // Typing clears it — the next attempt is a fresh one.
        _ = menu.handle(.character("z"), in: context)
        XCTAssertEqual(menu.rendering(in: context).compose?.problem, false)
    }

    func testAFailedRemoveSaysWhyRatherThanSwallowingIt() {
        // A refusal has to land somewhere. The compose card has a verdict
        // line to take one; the options card needs its own place, or a remove
        // that could not be written just sits there looking ignored.
        var menu = WebMenu()
        let context = context()
        menu.toggle(on: link, in: context)
        XCTAssertEqual(menu.handle(.character("d"), in: context), .removeLink(name: "yt"))
        menu.failed("could not write the config")
        XCTAssertEqual(menu.rendering(in: context).options?.error,
                       "could not write the config")
        // A stray key leaves the reason up; going somewhere clears it.
        _ = menu.handle(.character("q"), in: context)
        XCTAssertNotNil(menu.rendering(in: context).options?.error)
        _ = menu.handle(.character("r"), in: context)
        XCTAssertNil(menu.rendering(in: context).options?.error)
        _ = menu.handle(.escape, in: context)
        XCTAssertNil(menu.rendering(in: context).options?.error)
    }

    func testKeysThatMeanNothingAreHarmless() {
        var menu = WebMenu()
        let context = context()
        XCTAssertEqual(menu.handle(.enter, in: context), .nothing) // closed
        menu.toggle(on: domain, in: context)
        XCTAssertEqual(menu.handle(.character("q"), in: context), .nothing)
        XCTAssertEqual(menu.handle(.tab, in: context), .nothing)
        XCTAssertEqual(menu.handle(.delete, in: context), .nothing)
        XCTAssertEqual(menu.state, .options(domain))
    }
}
