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

    func testCredentialsNormalizeToTheRealHost() {
        // The colon belongs to the password. Cutting the host there made
        // `user` look like a machine on the desk, and the password left on
        // the first request, before any redirect to https.
        XCTAssertEqual(WebRouting.normalize("user:pass@github.com"), "https://user:pass@github.com")
        XCTAssertEqual(WebRouting.normalize("user:pass@github.com/acme"), "https://user:pass@github.com/acme")
        XCTAssertEqual(WebRouting.normalize("user:pass@github.com:443"), "https://user:pass@github.com:443")
        XCTAssertEqual(WebRouting.normalize("user:pass@github.com?q=1"), "https://user:pass@github.com?q=1")
        XCTAssertEqual(WebRouting.normalize("user@github.com"), "https://user@github.com")
        XCTAssertEqual(WebRouting.normalize("  user:pass@github.com  "), "https://user:pass@github.com")
        // The last `@` ends userinfo, even when the password holds one.
        XCTAssertEqual(WebRouting.normalize("user:p@ss@github.com"), "https://user:p@ss@github.com")
        // A dot in the password is not a dot in the host.
        XCTAssertEqual(WebRouting.normalize("user:p.ass@github.com"), "https://user:p.ass@github.com")
        XCTAssertEqual(WebRouting.normalize("user:p.ass@localhost"), "http://user:p.ass@localhost")
        // A public address stays https; a name that merely sounds internal does too.
        XCTAssertEqual(WebRouting.normalize("user:pass@8.8.8.8"), "https://user:pass@8.8.8.8")
        XCTAssertEqual(WebRouting.normalize("user:pass@db.internal"), "https://user:pass@db.internal")
        XCTAssertEqual(WebRouting.normalize("user:pass@172.32.0.1"), "https://user:pass@172.32.0.1")
        // The same credentials aimed at a machine on the desk stay http.
        XCTAssertEqual(WebRouting.normalize("user:pass@localhost"), "http://user:pass@localhost")
        XCTAssertEqual(WebRouting.normalize("user:pass@localhost:3000"), "http://user:pass@localhost:3000")
        XCTAssertEqual(WebRouting.normalize("user:pass@127.0.0.1:8000/x"), "http://user:pass@127.0.0.1:8000/x")
        XCTAssertEqual(WebRouting.normalize("user:pass@box.local"), "http://user:pass@box.local")
        XCTAssertEqual(WebRouting.normalize("user:pass@192.168.1.5"), "http://user:pass@192.168.1.5")
        XCTAssertEqual(WebRouting.normalize("user:pass@10.0.0.9:3000"), "http://user:pass@10.0.0.9:3000")
        XCTAssertEqual(WebRouting.normalize("user:pass@app.test/login"), "http://user:pass@app.test/login")
        XCTAssertEqual(WebRouting.normalize("user:pass@0.0.0.0:5000"), "http://user:pass@0.0.0.0:5000")
        XCTAssertTrue(WebRouting.isDomainLike("user:pass@github.com"))
        XCTAssertTrue(WebRouting.isDomainLike("user:pass@localhost"))
        XCTAssertTrue(WebRouting.isDomainLike("user:pass@localhost:3000"))
        // A scheme you typed is still left alone.
        XCTAssertEqual(WebRouting.normalize("https://user:pass@github.com"), "https://user:pass@github.com")
        XCTAssertEqual(WebRouting.normalize("http://user:pass@github.com"), "http://user:pass@github.com")
        XCTAssertEqual(WebRouting.host(of: "user:pass@github.com"), "github.com")
        XCTAssertEqual(WebRouting.host(of: "user:pass@localhost:3000"), "localhost")
    }

    func testIPv6LoopbackIsLocal() {
        // `::1` and `[::1]` are on the allowlist. Cutting at the first colon
        // left `1` and `[`, so both were searches instead of a dev server.
        XCTAssertTrue(WebRouting.isLocal(host: "::1"))
        XCTAssertTrue(WebRouting.isLocal(host: "[::1]"))
        XCTAssertTrue(WebRouting.isLocal(host: "[::1]:8080"))
        XCTAssertTrue(WebRouting.isLocal(host: "[::1]:8080/login"))
        XCTAssertTrue(WebRouting.isLocal(host: "user:pass@[::1]:8080"))
        XCTAssertTrue(WebRouting.isDomainLike("::1"))
        XCTAssertTrue(WebRouting.isDomainLike("[::1]"))
        XCTAssertTrue(WebRouting.isDomainLike("[::1]:8080"))
        XCTAssertTrue(WebRouting.isDomainLike("[::1]:8080/login"))
        XCTAssertEqual(WebRouting.normalize("::1"), "http://::1")
        XCTAssertEqual(WebRouting.normalize("[::1]"), "http://[::1]")
        XCTAssertEqual(WebRouting.normalize("[::1]:8080"), "http://[::1]:8080")
        XCTAssertEqual(WebRouting.normalize("[::1]:8080/login"), "http://[::1]:8080/login")
        XCTAssertEqual(WebRouting.normalize("user:pass@[::1]:8080"), "http://user:pass@[::1]:8080")
        XCTAssertEqual(WebRouting.host(of: "::1"), "::1")
        XCTAssertEqual(WebRouting.host(of: "[::1]:8080"), "::1")
        // A port on IPv6 is `[::1]:8080`. Without brackets, `::1:8080` is a
        // different address, not loopback.
        XCTAssertFalse(WebRouting.isLocal(host: "::1:8080"))
        // A public literal is not loopback. It has no dot, so it stays http,
        // and it is still not a destination the way `::1` now is.
        XCTAssertFalse(WebRouting.isLocal(host: "2001:db8::1"))
        XCTAssertFalse(WebRouting.isDomainLike("2001:db8::1"))
        XCTAssertEqual(WebRouting.normalize("2001:db8::1"), "http://2001:db8::1")
        XCTAssertEqual(WebRouting.normalize("[2001:db8::1]"), "http://[2001:db8::1]")
        // The query and the fragment are not the host, so a dev server keeps http.
        XCTAssertEqual(WebRouting.normalize("localhost:3000?x=1"), "http://localhost:3000?x=1")
        XCTAssertTrue(WebRouting.isDomainLike("localhost:3000?x=1"))
        XCTAssertEqual(WebRouting.normalize("box.local?x=1"), "http://box.local?x=1")
        XCTAssertEqual(WebRouting.normalize("box.local#top"), "http://box.local#top")
        XCTAssertEqual(WebRouting.normalize("acme.dev:8443?x=1"), "https://acme.dev:8443?x=1")
        XCTAssertEqual(WebRouting.normalize("github.com?q=1"), "https://github.com?q=1")
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
