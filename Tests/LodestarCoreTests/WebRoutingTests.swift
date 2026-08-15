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
}
