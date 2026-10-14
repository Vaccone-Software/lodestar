import XCTest
@testable import LodestarCore

final class UpdaterResilienceTests: XCTestCase {
    /// Just launched, no key yet, a hand on the trackpad a minute ago: not
    /// quiet. Away for two hours: quiet, whatever the process knows.
    func testTheSystemIdleClockCountsTheHandTheTapDoesNotSee() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let never = Date.distantPast
        let justMoved = Updater.lastSignOfLife(engineActivity: never, humanInput: never,
                                               systemIdleSeconds: 60, now: now)
        XCTAssertFalse(Updater.mayApply(engineQuiet: true, secondsSinceActivity: now.timeIntervalSince(justMoved)))
        let away = Updater.lastSignOfLife(engineActivity: never, humanInput: never,
                                          systemIdleSeconds: 7200, now: now)
        XCTAssertTrue(Updater.mayApply(engineQuiet: true, secondsSinceActivity: now.timeIntervalSince(away)))
        let typed = Updater.lastSignOfLife(engineActivity: never, humanInput: now.addingTimeInterval(-30),
                                           systemIdleSeconds: 7200, now: now)
        XCTAssertEqual(typed, now.addingTimeInterval(-30), "the latest sign wins")
        XCTAssertEqual(Updater.lastSignOfLife(engineActivity: never, humanInput: never,
                                              systemIdleSeconds: nil, now: now), never)
    }

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

/// The retry wait and the markers, now through Stoic.
final class UpdaterStoicTests: XCTestCase {
    /// The schedule keeps its shape — a quarter of an hour, then an hour,
    /// then nothing — and the jitter only ever shortens a wait, by at most
    /// half, so no Mac waits longer than before and a fleet spreads out.
    func testTheRetryDelayIsJitteredWithinTheScheduleShape() {
        for seed in UInt64(0)..<40 {
            let first = Updater.jitteredRetryDelay(afterFailures: 1, random: .seeded(seed))
            let second = Updater.jitteredRetryDelay(afterFailures: 2, random: .seeded(seed))
            XCTAssertNotNil(first)
            XCTAssertTrue((7.5 * 60)...(15 * 60) ~= first ?? 0, "\(String(describing: first))")
            XCTAssertTrue((30 * 60)...(60 * 60) ~= second ?? 0, "\(String(describing: second))")
        }
        let spread = Set((0..<40).compactMap { Updater.jitteredRetryDelay(afterFailures: 1, random: .seeded($0)) })
        XCTAssertGreaterThan(spread.count, 10, "the waits differ from Mac to Mac")
        XCTAssertNil(Updater.jitteredRetryDelay(afterFailures: 3), "then the daily check again")
        XCTAssertNil(Updater.jitteredRetryDelay(afterFailures: 0))
    }

    func testAMarkerIsExactlyItsBytesAndReplacesTheLast() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("updater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("refused")   // the directory does not exist yet
        try Updater.writeMarker("v0.40.1", to: marker)
        XCTAssertEqual(try Data(contentsOf: marker), Data("v0.40.1".utf8), "no envelope: scripts read these with cat")
        try Updater.writeMarker("v0.40.2", to: marker)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "v0.40.2")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, ["refused"], "no temporary left behind")
    }

    func testAMarkerThatCannotBeWrittenSaysSo() {
        // A file where the directory should be.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        XCTAssertThrowsError(try Updater.writeMarker("v1", to: blocker.appendingPathComponent("refused")))
    }
}
