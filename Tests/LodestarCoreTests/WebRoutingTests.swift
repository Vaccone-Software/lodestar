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

    func testNormalize() {
        XCTAssertEqual(WebRouting.normalize("youtube.com"), "https://youtube.com")
        XCTAssertEqual(WebRouting.normalize("http://a.b"), "http://a.b")
        XCTAssertEqual(WebRouting.normalize("  x.dev  "), "https://x.dev")
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
