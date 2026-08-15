import XCTest
@testable import LodestarCore

final class WebJsonEditorTests: XCTestCase {
    private let base: [String: ConfigValue] = [
        "version": .string("0.9.17"),
        "web": .table([
            "fallback": .string("work"),
            "links": .table(["yt": .table(["url": .string("youtube.com"),
                                           "profile": .string("google")])]),
        ]),
    ]

    func testAddsALinkAndLeavesTheRestOfTheTree() throws {
        let out = try WebJsonEditor.addingLink(name: "linear", url: "linear.app",
                                               profileKey: nil, in: base)
        let links = out["web"]?.table?["links"]?.table
        XCTAssertEqual(links?["linear"]?.table?["url"], .string("linear.app"))
        // Unpinned means no key at all — the link inherits routes and fallback.
        XCTAssertNil(links?["linear"]?.table?["profile"])
        XCTAssertEqual(links?["yt"]?.table?["url"], .string("youtube.com"))
        XCTAssertEqual(out["web"]?.table?["fallback"], .string("work"))
        XCTAssertEqual(out["version"], .string("0.9.17"))
    }

    func testPinsAProfileWhenGivenOne() throws {
        let out = try WebJsonEditor.addingLink(name: "Acme", url: "app.acme.dev",
                                               profileKey: "work", in: base)
        let link = out["web"]?.table?["links"]?.table?["acme"]?.table
        XCTAssertEqual(link?["profile"], .string("work"))
        XCTAssertEqual(link?["url"], .string("app.acme.dev"))
    }

    func testStoresTheURLAsTyped() throws {
        // https is added when the link is opened, not when it is saved, so a
        // UI-added link and a hand-added one are the same two lines.
        let bare = try WebJsonEditor.addingLink(name: "a", url: "  youtube.com ",
                                                profileKey: nil, in: base)
        XCTAssertEqual(bare["web"]?.table?["links"]?.table?["a"]?.table?["url"],
                       .string("youtube.com"))
        let explicit = try WebJsonEditor.addingLink(name: "b", url: "http://box.local",
                                                    profileKey: nil, in: base)
        XCTAssertEqual(explicit["web"]?.table?["links"]?.table?["b"]?.table?["url"],
                       .string("http://box.local"))
    }

    func testRefusesTakenNamesRatherThanOverwriting() {
        XCTAssertThrowsError(try WebJsonEditor.addingLink(name: "YT", url: "youtu.be",
                                                          profileKey: nil, in: base)) {
            XCTAssertEqual($0 as? WebJsonEditor.EditError,
                           .taken(name: "yt", target: "youtube.com"))
        }
    }

    func testRemovesALinkAndPrunesTheEmptiedTable() throws {
        let out = try WebJsonEditor.removingLink(name: "YT", in: base)
        XCTAssertNil(out["web"]?.table?["links"])
        XCTAssertEqual(out["web"]?.table?["fallback"], .string("work")) // the rest rides
        let two = try WebJsonEditor.addingLink(name: "linear", url: "linear.app",
                                               profileKey: nil, in: base)
        let one = try WebJsonEditor.removingLink(name: "linear", in: two)
        XCTAssertEqual(one["web"]?.table?["links"]?.table?.count, 1)
        XCTAssertThrowsError(try WebJsonEditor.removingLink(name: "nope", in: base)) {
            XCTAssertEqual($0 as? WebJsonEditor.EditError, .missing("nope"))
        }
    }

    func testAddsAndRemovesARoute() throws {
        let out = try WebJsonEditor.addingRoute(pattern: "X.com", profileKey: "personal",
                                                in: base)
        XCTAssertEqual(out["web"]?.table?["routes"]?.table?["x.com"], .string("personal"))
        XCTAssertEqual(ConfigSchema.validate(out, against: Config.schema), [])
        XCTAssertThrowsError(try WebJsonEditor.addingRoute(pattern: "x.com",
                                                           profileKey: "work", in: out)) {
            XCTAssertEqual($0 as? WebJsonEditor.EditError,
                           .taken(name: "x.com", target: "personal"))
        }
        let back = try WebJsonEditor.removingRoute(pattern: "x.com", in: out)
        XCTAssertNil(back["web"]?.table?["routes"])
    }

    func testARouteMustNameAProfile() {
        XCTAssertThrowsError(try WebJsonEditor.addingRoute(pattern: "x.com", profileKey: "",
                                                           in: base)) {
            XCTAssertEqual($0 as? WebJsonEditor.EditError, .noProfile)
        }
        XCTAssertEqual(WebJsonEditor.patternProblem("x.com", profileKey: nil, existing: [:]),
                       "pick a profile — a route has to name one")
        XCTAssertEqual(WebJsonEditor.patternProblem("", profileKey: "work", existing: [:]),
                       "a route needs a pattern")
        XCTAssertNil(WebJsonEditor.patternProblem("x.com", profileKey: "work", existing: [:]))
        XCTAssertEqual(WebJsonEditor.patternProblem("x.com", profileKey: "work",
                                                    existing: ["x.com": "work"]),
                       "x.com already goes to work")
        XCTAssertEqual(WebJsonEditor.patternProblem("x.com", profileKey: "work",
                                                    existing: ["x.com": "personal"]),
                       "x.com is already personal")
    }

    func testAPatternKeepsItsSpacesButNotItsSlop() {
        // A pattern is matched as a substring, so a phrase is legitimate —
        // only case and stray whitespace are normalized away.
        XCTAssertEqual(WebJsonEditor.normalizePattern("  Google   Docs "), "google docs")
        XCTAssertEqual(WebJsonEditor.normalizePattern("X.com"), "x.com")
    }

    func testSuggestsTheFirstWordOfASearch() {
        // The whole phrase as a pattern would match almost nothing; the
        // first word is the thing you want routed from now on.
        XCTAssertEqual(WebJsonEditor.suggestedPattern(forSearch: "acme deploy runbook"), "acme")
        XCTAssertEqual(WebJsonEditor.suggestedPattern(forSearch: "  Linear  "), "linear")
        XCTAssertEqual(WebJsonEditor.suggestedPattern(forSearch: ""), "")
    }

    func testSuggestsTheWholeHostAsARoutePattern() {
        // A route is about which site a link is, and the path changes every
        // time you paste one.
        XCTAssertEqual(WebJsonEditor.suggestedPattern(for: "https://x.com/friend/status/1"),
                       "x.com")
        XCTAssertEqual(WebJsonEditor.suggestedPattern(for: "www.docs.google.com/d/abc"),
                       "docs.google.com")
        XCTAssertEqual(WebJsonEditor.suggestedPattern(for: "localhost:3000/x"), "localhost")
    }

    func testRefusesAnEmptyName() {
        XCTAssertThrowsError(try WebJsonEditor.addingLink(name: "  ", url: "youtube.com",
                                                          profileKey: nil, in: base)) {
            XCTAssertEqual($0 as? WebJsonEditor.EditError, .emptyName)
        }
    }

    func testWorksFromNoWebSectionAtAll() throws {
        let out = try WebJsonEditor.addingLink(name: "yt", url: "youtube.com",
                                               profileKey: "google",
                                               in: ["version": .string("0.9.17")])
        XCTAssertEqual(out["web"]?.table?["links"]?.table?["yt"]?.table?["profile"],
                       .string("google"))
    }

    func testTheWrittenShapeIsOneTheSchemaAccepts() throws {
        // ⌘K writes into the same file a hand edit does, so what it emits has
        // to survive the validation every reload runs.
        let out = try WebJsonEditor.addingLink(name: "acme", url: "app.acme.dev",
                                               profileKey: "work", in: base)
        XCTAssertEqual(ConfigSchema.validate(out, against: Config.schema), [])
    }

    func testNormalizesNamesToTheGrammarTheyAreTypedIn() {
        XCTAssertEqual(WebJsonEditor.normalizeName("Proton Mail"), "protonmail")
        XCTAssertEqual(WebJsonEditor.normalizeName("web-3"), "web-3")
        XCTAssertEqual(WebJsonEditor.normalizeName("a.b/c?d"), "abcd")
        XCTAssertEqual(WebJsonEditor.normalizeName(" "), "")
    }

    func testSuggestsTheHostsFirstDistinguishingLabel() {
        XCTAssertEqual(WebJsonEditor.suggestedName(for: "youtube.com"), "youtube")
        XCTAssertEqual(WebJsonEditor.suggestedName(for: "https://www.youtube.com"), "youtube")
        XCTAssertEqual(WebJsonEditor.suggestedName(for: "docs.google.com/document"), "docs")
        XCTAssertEqual(WebJsonEditor.suggestedName(for: "linear.app/team/ENG"), "linear")
        XCTAssertEqual(WebJsonEditor.suggestedName(for: "http://box.local:3000/x"), "box")
    }

    func testNameProblemTellsTheTwoKindsOfCollisionApart() {
        let existing = [Config.WebLink(name: "yt", url: "youtube.com", profileKey: nil)]
        XCTAssertNil(WebJsonEditor.nameProblem("linear", url: "linear.app", existing: existing))
        XCTAssertEqual(WebJsonEditor.nameProblem("yt", url: "https://youtube.com",
                                                 existing: existing),
                       "yt already points here")
        XCTAssertEqual(WebJsonEditor.nameProblem("YT", url: "youtu.be", existing: existing),
                       "yt is already youtube.com")
        XCTAssertEqual(WebJsonEditor.nameProblem("", url: "youtube.com", existing: existing),
                       "a link needs a name")
    }
}
