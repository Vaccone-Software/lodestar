import XCTest
@testable import LodestarCore

final class UpdaterResilienceTests: XCTestCase {
    func testAFailedCheckIsTriedAgainSoonThenDaily() {
        XCTAssertEqual(Updater.retryDelay(afterFailures: 1), 15 * 60)
        XCTAssertEqual(Updater.retryDelay(afterFailures: 2), 60 * 60)
        XCTAssertNil(Updater.retryDelay(afterFailures: 3), "then the daily check again")
        XCTAssertNil(Updater.retryDelay(afterFailures: 0))
    }

    func testAnErrorPageIsNotReadAsARelease() {
        XCTAssertNil(Updater.httpProblem(status: 200))
        XCTAssertNil(Updater.httpProblem(status: nil), "a file URL has no status")
        XCTAssertEqual(Updater.httpProblem(status: 403), "HTTP 403, GitHub's rate limit")
        XCTAssertEqual(Updater.httpProblem(status: 404), "HTTP 404")
        XCTAssertEqual(Updater.httpProblem(status: 502), "HTTP 502")
    }

    func testOnlyTheAppInAnApplicationsFolderIsInstalled() {
        let home = "/Users/someone"
        XCTAssertTrue(Updater.isInstalled(bundlePath: "/Applications/lodestar.app", home: home))
        XCTAssertTrue(Updater.isInstalled(bundlePath: "/Users/someone/Applications/lodestar.app", home: home))
        XCTAssertFalse(Updater.isInstalled(bundlePath: "/Users/someone/Developer/lodestar/dist/lodestar.app", home: home))
        XCTAssertFalse(Updater.isInstalled(bundlePath: "/Users/someone/Downloads/lodestar.app", home: home))
        XCTAssertFalse(Updater.isInstalled(bundlePath: "/private/var/folders/x/AppTranslocation/y/d/lodestar.app", home: home))
    }

    /// The newest entry without a zip no longer stops updates: the one
    /// before it is offered.
    func testANewestReleaseWithoutAZipFallsThroughToTheOneBefore() throws {
        let feed = """
        [{"tag_name": "v0.40.0-rc1", "draft": false, "assets": [{"name": "lodestar-0.40.0.zip", "browser_download_url": "u1"}]},
         {"tag_name": "v0.39.9", "draft": false, "assets": []},
         {"tag_name": "v0.39.8", "draft": false, "assets": [{"name": "lodestar-0.39.8.zip", "browser_download_url": "u2"}]}]
        """
        let release = try XCTUnwrap(Updater.parseFeed(Data(feed.utf8)))
        XCTAssertEqual(release.tag, "v0.39.8")
    }
}
