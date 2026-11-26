import XCTest
@testable import LodestarCore

final class WebRoutingTests: XCTestCase {
    func testDomainDetection() {
        XCTAssertTrue(WebRouting.isDomainLike("youtube.com"))
        XCTAssertTrue(WebRouting.isDomainLike("linear.app/acme/board"))
        XCTAssertTrue(WebRouting.isDomainLike("https://anything"))
        XCTAssertFalse(WebRouting.isDomainLike("how to tile windows"))
        XCTAssertFalse(WebRouting.isDomainLike("youtube"))
        XCTAssertFalse(WebRouting.isDomainLike(".com"))
        XCTAssertFalse(WebRouting.isDomainLike(""))
    }

    func testDevServersAreDestinationsNotSearches() {
        XCTAssertTrue(WebRouting.isDomainLike("localhost:3000"))
        XCTAssertTrue(WebRouting.isDomainLike("localhost"))
        XCTAssertTrue(WebRouting.isDomainLike("localhost:5173/login"))
        XCTAssertTrue(WebRouting.isDomainLike("box.local"))
        XCTAssertTrue(WebRouting.isDomainLike("192.168.1.5:8080"))
        XCTAssertTrue(WebRouting.isDomainLike("api:8000"))
        // Still a search: no port, no dot, not a local name.
        XCTAssertFalse(WebRouting.isDomainLike("localhosts"))
        XCTAssertFalse(WebRouting.isDomainLike("time:now"))
    }

    func testNormalize() {
        XCTAssertEqual(WebRouting.normalize("youtube.com"), "https://youtube.com")
        XCTAssertEqual(WebRouting.normalize("http://a.b"), "http://a.b")
        XCTAssertEqual(WebRouting.normalize("  x.dev  "), "https://x.dev")
    }

    func testNormalizeKeepsDevServersOnHTTP() {
        // A dev server has no certificate, so https is the one guess that
        // could never work.
        XCTAssertEqual(WebRouting.normalize("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(WebRouting.normalize("127.0.0.1:8000/x"), "http://127.0.0.1:8000/x")
        XCTAssertEqual(WebRouting.normalize("box.local"), "http://box.local")
        XCTAssertEqual(WebRouting.normalize("app.test/login"), "http://app.test/login")
        XCTAssertEqual(WebRouting.normalize("192.168.1.5"), "http://192.168.1.5")
        XCTAssertEqual(WebRouting.normalize("10.0.0.9:3000"), "http://10.0.0.9:3000")
        // No dot means no TLD, so it cannot be a public host.
        XCTAssertEqual(WebRouting.normalize("api:8000"), "http://api:8000")
        // Everything else is https, including hosts that merely sound
        // internal — a corporate .internal is usually served over TLS.
        XCTAssertEqual(WebRouting.normalize("8.8.8.8"), "https://8.8.8.8")
        XCTAssertEqual(WebRouting.normalize("acme.dev:8443"), "https://acme.dev:8443")
        XCTAssertEqual(WebRouting.normalize("db.internal"), "https://db.internal")
        XCTAssertEqual(WebRouting.normalize("172.32.0.1"), "https://172.32.0.1") // outside 172.16/12
        // An explicit scheme is never second-guessed.
        XCTAssertEqual(WebRouting.normalize("https://localhost:3000"), "https://localhost:3000")
    }

    func testRouteLongestMatchWins() {
        let routes = ["youtube": "google", "music.youtube": "personal", "acme": "work"]
        XCTAssertEqual(WebRouting.route("youtube.com", routes: routes), "google")
        XCTAssertEqual(WebRouting.route("music.youtube.com", routes: routes), "personal")
        XCTAssertEqual(WebRouting.route("app.acme.dev/walks", routes: routes), "work")
        XCTAssertNil(WebRouting.route("stripe.com", routes: routes))
    }

    func testRouteIsCaseInsensitive() {
        XCTAssertEqual(WebRouting.route("YouTube.com", routes: ["youtube": "google"]), "google")
        XCTAssertEqual(WebRouting.route("https://github.com/x", routes: ["GitHub.com": "work"]), "work")
    }

    /// A pattern is a run of whole labels, wherever that run sits. A
    /// substring is how `github.com` swallows `notgithub.com` and how `ai`
    /// hides inside `mail`.
    func testHostPatternsMatchWholeLabels() {
        let routes = ["github.com": "work", "youtube": "google", "ai": "personal"]
        XCTAssertEqual(WebRouting.route("music.youtube.com", routes: routes), "google")
        XCTAssertEqual(WebRouting.route("https://music.youtube.com/playlist", routes: routes), "google")
        // The site without its last label, and a subdomain of that.
        XCTAssertEqual(
            WebRouting.route("https://foo.music.youtube.com/a", routes: ["music.youtube": "personal"]),
            "personal")
        XCTAssertEqual(WebRouting.route("https://github.com/lodestar", routes: routes), "work")
        XCTAssertEqual(WebRouting.route("https://gist.github.com/vac", routes: routes), "work")
        XCTAssertEqual(WebRouting.route("https://www.github.com/", routes: routes), "work")
        // `ai` is a label of claude.ai, and only letters inside `mail`.
        XCTAssertEqual(WebRouting.route("https://claude.ai/chat", routes: routes), "personal")
        XCTAssertEqual(WebRouting.route("mail.google.com", routes: ["google": "work"]), "work")
        XCTAssertNil(WebRouting.route("mail.google.com", routes: ["ai": "personal"]))
        XCTAssertNil(WebRouting.route("https://mail.google.com/mail/u/0/", routes: ["ai": "personal"]))
        XCTAssertNil(WebRouting.route("notgithub.com", routes: routes))
        XCTAssertNil(WebRouting.route("https://notgithub.com/login", routes: routes))
        XCTAssertNil(WebRouting.route("mygithub.com.evil.test", routes: routes))
        XCTAssertNil(WebRouting.route("https://mygithub.com.evil.test/a", routes: routes))
        // A dotted pattern is a domain, not a prefix of someone else's.
        XCTAssertNil(WebRouting.route("github.com.evil.test", routes: routes))
        XCTAssertNil(WebRouting.route("https://github.com.evil.test/a", routes: routes))
        // The path, the query, and the userinfo are not the host.
        XCTAssertNil(WebRouting.route("https://evil.example/github.com", routes: routes))
        XCTAssertNil(WebRouting.route(
            "https://evil.example/login?next=https://github.com", routes: routes))
        XCTAssertNil(WebRouting.route("https://github.com@evil.example/path", routes: routes))
        XCTAssertEqual(WebRouting.route("https://user:pass@github.com/lodestar", routes: routes), "work")
    }

    /// A search has no host, so the pattern has to be a word — `acme` inside
    /// "acme deploy runbook", and not the `ai` inside "email".
    func testQueryPatternsMatchWholeWords() {
        XCTAssertEqual(WebRouting.route("acme deploy runbook", routes: ["acme": "work"]), "work")
        XCTAssertEqual(WebRouting.route("Acme deploy runbook", routes: ["acme": "work"]), "work")
        XCTAssertEqual(WebRouting.route("deploy the acme runbook", routes: ["acme": "work"]), "work")
        XCTAssertEqual(WebRouting.route("ask the ai", routes: ["ai": "personal"]), "personal")
        XCTAssertNil(WebRouting.route("notacme deploy runbook", routes: ["acme": "work"]))
        XCTAssertNil(WebRouting.route("acme_deploy runbook", routes: ["acme": "work"]))
        XCTAssertEqual(WebRouting.route("acme-deploy runbook", routes: ["acme": "work"]), "work")
        XCTAssertNil(WebRouting.route("email the team", routes: ["ai": "personal"]))
        // The longer phrase still wins when both are whole words.
        XCTAssertEqual(
            WebRouting.routePattern("acme deploy runbook",
                                    routes: ["acme": "work", "deploy runbook": "personal"]),
            "deploy runbook")
    }

    /// A URL pasted into a sentence is still a host. Its query string does
    /// not become words of the sentence, and the words around it still route.
    func testAURLInsideAQueryIsMatchedOnItsHost() {
        let routes = ["github.com": "work", "youtube": "google", "acme": "work"]
        XCTAssertEqual(
            WebRouting.route("yt https://music.youtube.com/playlist", routes: routes), "google")
        // A saved link is often "name host", with no scheme. The host's
        // labels are words; a pattern in a schemeless query string is not.
        XCTAssertEqual(WebRouting.route("yt youtube.com", routes: routes), "google")
        XCTAssertNil(WebRouting.route(
            "login https://evil.example/login?next=https://github.com", routes: routes))
        XCTAssertNil(WebRouting.route(
            "open evil.example/login?next=https://github.com", routes: routes))
        XCTAssertEqual(
            WebRouting.route("acme https://evil.example/login?next=https://github.com",
                             routes: routes),
            "work")
    }

    func testSearchURL() {
        XCTAssertEqual(
            WebRouting.searchURL(template: "https://g.co/search?q=%s", query: "hello world"),
            "https://g.co/search?q=hello%20world"
        )
        XCTAssertEqual(
            WebRouting.searchURL(template: "https://g.co/s?q=", query: "a"),
            "https://g.co/s?q=a"
        )
    }

    func testSearchURLEncodesFormMeaningfulCharacters() {
        // `&` would split the query; a literal `+` decodes as a space on
        // every form-reading engine, so "c++" searched as typed came back
        // as "c  ".
        XCTAssertEqual(
            WebRouting.searchURL(template: "https://g.co/s?q=%s", query: "c++"),
            "https://g.co/s?q=c%2B%2B"
        )
        XCTAssertEqual(
            WebRouting.searchURL(template: "https://g.co/s?q=%s", query: "a&b"),
            "https://g.co/s?q=a%26b"
        )
    }
}
