import XCTest
@testable import LodestarCore

/// The stable channel's rule, held two ways: the shared fixture the site's
/// download button is also tested against (Fixtures/promotion.json), so
/// the two languages can never disagree about what stable is, and named
/// cases here for what the fixture cannot say.
final class PromotionTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/promotion.json")

    private struct Fixture: Decodable {
        struct Policy: Decodable { let minorSoakDays, patchSoakDays, settleDays: Double }
        struct Release: Decodable {
            let tag, published, title: String
            let zip, draft: Bool
        }
        struct Check: Decodable {
            let now: String
            let stable: String?
        }
        struct Case: Decodable {
            let name: String
            let releases: [Release]
            let checks: [Check]
        }
        let policy: Policy
        let cases: [Case]
    }

    private let iso = ISO8601DateFormatter()
    private let start = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    private func day(_ days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

    private func build(_ tag: String, _ days: Double, title: String = "") -> Promotion.Build {
        Promotion.Build(tag: tag, version: Updater.parseVersion(tag)!, published: day(days), title: title)
    }

    // MARK: - The shared fixture

    func testFixturePolicyIsTheStandardOne() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        XCTAssertEqual(fixture.policy.minorSoakDays * 86_400, Promotion.Policy.standard.minorSoak)
        XCTAssertEqual(fixture.policy.patchSoakDays * 86_400, Promotion.Policy.standard.patchSoak)
        XCTAssertEqual(fixture.policy.settleDays * 86_400, Promotion.Policy.standard.settle)
    }

    func testEveryFixtureCase() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        for item in fixture.cases {
            let builds = item.releases.map {
                Promotion.Build(tag: $0.tag, version: Updater.parseVersion($0.tag)!,
                                published: iso.date(from: $0.published)!, title: $0.title,
                                hasZip: $0.zip, draft: $0.draft)
            }
            for check in item.checks {
                let stable = Promotion.stable(builds, now: iso.date(from: check.now)!)
                XCTAssertEqual(stable?.tag, check.stable, "\(item.name) at \(check.now)")
            }
        }
    }

    // MARK: - Named cases

    func testEmptyAndSingleLists() {
        XCTAssertNil(Promotion.stable([], now: day(10)))
        XCTAssertEqual(Promotion.stable([build("v0.1.0", 0)], now: day(0))?.tag, "v0.1.0")
    }

    func testAPatchStartsTheTimer() {
        let builds = [build("v0.47.0", 0), build("v0.47.1", 10)]
        XCTAssertEqual(Promotion.stable(builds, now: day(12.9))?.tag, "v0.47.0")
        XCTAssertEqual(Promotion.stable(builds, now: day(13))?.tag, "v0.47.1")
    }

    func testPatchesNeverResetAMinorsClock() {
        // A patch a day after the minor, and another just before its week
        // is up: the week still ends on the minor's day, with the newest
        // build that has settled.
        let builds = [build("v0.47.0", 0), build("v0.48.0", 1), build("v0.48.1", 2), build("v0.48.2", 7.5)]
        XCTAssertEqual(Promotion.stable(builds, now: day(7.9))?.tag, "v0.47.0")
        XCTAssertEqual(Promotion.stable(builds, now: day(8))?.tag, "v0.48.1")
        XCTAssertEqual(Promotion.stable(builds, now: day(10.5))?.tag, "v0.48.2")
    }

    func testDailyPatchesNeverStall() {
        // A month of a patch every day. Stable keeps moving the whole time,
        // never more than a soak and a settle behind the head.
        var builds = [build("v0.47.0", 0), build("v0.48.0", 1)]
        for k in 1...30 { builds.append(build("v0.48.\(k)", 1 + Double(k))) }
        var last = [0, 47, 0]
        for now in stride(from: 8.0, through: 31, by: 1) {
            let stable = Promotion.stable(builds, now: day(now))!
            XCTAssertFalse(Updater.isNewer(last, than: stable.version), "stable stepped back at day \(now)")
            XCTAssertLessThanOrEqual(day(now).timeIntervalSince(stable.published), 5 * 86_400,
                                     "stable fell more than a patch soak and a settle behind at day \(now)")
            last = stable.version
        }
    }

    func testTheSettleFloorPassesOverABuildTooYoung() {
        let builds = [build("v0.47.0", 0), build("v0.48.0", 1), build("v0.48.1", 7.9)]
        XCTAssertEqual(Promotion.stable(builds, now: day(8))?.tag, "v0.48.0")
    }

    func testAHoldRestartsTheClock() {
        let builds = [build("v0.47.0", 0), build("v0.48.0", 1, title: "Lodestar 0.48.0 [held]"),
                      build("v0.48.1", 4)]
        XCTAssertEqual(Promotion.stable(builds, now: day(8))?.tag, "v0.47.0")
        XCTAssertEqual(Promotion.stable(builds, now: day(10.9))?.tag, "v0.47.0")
        XCTAssertEqual(Promotion.stable(builds, now: day(11))?.tag, "v0.48.1")
    }

    func testAHoldOnlyStopsItsOwnLine() {
        let builds = [build("v0.47.0", 0), build("v0.47.1", 1), build("v0.48.0", 2, title: "[Held] bad audio")]
        XCTAssertEqual(Promotion.stable(builds, now: day(30))?.tag, "v0.47.1")
    }

    func testTwoLinesRunIndependently() {
        let builds = [build("v0.47.0", 0), build("v0.47.1", 1), build("v0.48.0", 2)]
        XCTAssertEqual(Promotion.stable(builds, now: day(4))?.tag, "v0.47.1")
        XCTAssertEqual(Promotion.stable(builds, now: day(9))?.tag, "v0.48.0")
    }

    func testZiplessDraftAndFutureReleasesAreSkipped() {
        let builds = [
            build("v0.47.0", 0),
            Promotion.Build(tag: "v0.48.0", version: [0, 48, 0], published: day(1), hasZip: false),
            Promotion.Build(tag: "v0.49.0", version: [0, 49, 0], published: day(1), draft: true),
            build("v0.50.0", 40),
        ]
        XCTAssertEqual(Promotion.stable(builds, now: day(30))?.tag, "v0.47.0")
    }

    func testOrderOfTheListDoesNotMatter() {
        let builds = [build("v0.48.0", 1), build("v0.47.0", 0), build("v0.47.1", 1.5)]
        XCTAssertEqual(Promotion.stable(builds, now: day(9))?.tag,
                       Promotion.stable(builds.reversed(), now: day(9))?.tag)
    }

    // MARK: - Pending lines

    func testPendingNamesEachLineAndWhenItLands() {
        let builds = [build("v0.47.0", 0), build("v0.47.1", 1), build("v0.48.0", 2), build("v0.48.1", 3)]
        let pending = Promotion.pending(builds, now: day(3.5))
        XCTAssertEqual(pending.map(\.line), [[0, 47], [0, 48]])
        XCTAssertEqual(pending[0].isPatch, true)
        XCTAssertEqual(pending[0].promotes, day(4))
        XCTAssertEqual(pending[0].build.tag, "v0.47.1")
        XCTAssertEqual(pending[1].isPatch, false)
        XCTAssertEqual(pending[1].since, day(2))
        XCTAssertEqual(pending[1].promotes, day(9))
        XCTAssertEqual(pending[1].build.tag, "v0.48.1")
        XCTAssertTrue(Promotion.pending(builds, now: day(30)).isEmpty)
    }

    // MARK: - The feed

    func testParsesGitHubsReleaseList() {
        let feed = """
        [{"tag_name": "v0.47.0", "name": "Lodestar 0.47.0 [held]", "draft": false,
          "published_at": "2026-10-09T23:00:01Z",
          "assets": [{"name": "lodestar-0.47.0.zip"}, {"name": "lodestar-0.47.0.dmg"}]},
         {"tag_name": "v0.46.0", "name": null, "draft": true, "published_at": null, "assets": []},
         {"tag_name": "nightly", "name": "x", "published_at": "2026-10-01T00:00:00Z", "assets": []},
         {"tag_name": "v0.45.0", "name": "Lodestar 0.45.0", "published_at": "2026-10-06T23:22:17Z",
          "assets": [{"name": "lodestar-0.45.0.dmg"}]}]
        """
        let builds = Promotion.parseFeed(Data(feed.utf8))!
        XCTAssertEqual(builds.map(\.tag), ["v0.47.0", "v0.45.0"])
        XCTAssertTrue(builds[0].isHeld)
        XCTAssertTrue(builds[0].hasZip)
        XCTAssertEqual(builds[0].published, iso.date(from: "2026-10-09T23:00:01Z"))
        XCTAssertFalse(builds[1].hasZip)
        XCTAssertNil(Promotion.parseFeed(Data("{\"message\": \"rate limited\"}".utf8)))
    }
}
