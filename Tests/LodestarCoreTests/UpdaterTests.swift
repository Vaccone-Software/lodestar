import XCTest
@testable import LodestarCore

final class UpdaterTests: XCTestCase {
    // MARK: - Version parsing

    func testParsesPlainAndTaggedVersions() {
        XCTAssertEqual(Updater.parseVersion("0.9.9"), [0, 9, 9])
        XCTAssertEqual(Updater.parseVersion("v0.9.10"), [0, 9, 10])
        XCTAssertEqual(Updater.parseVersion("1.0"), [1, 0])
    }

    func testRejectsNonVersions() {
        XCTAssertNil(Updater.parseVersion("latest"))
        XCTAssertNil(Updater.parseVersion("0.9.x"))
        XCTAssertNil(Updater.parseVersion(""))
        XCTAssertNil(Updater.parseVersion("0..9"))
    }

    // MARK: - Ordering

    func testTenthPatchBeatsNinth() {
        // The trap the whole comparison exists for: numeric, never
        // lexicographic — "0.9.10" < "0.9.9" as strings.
        XCTAssertTrue(Updater.isNewer([0, 9, 10], than: [0, 9, 9]))
        XCTAssertFalse(Updater.isNewer([0, 9, 9], than: [0, 9, 10]))
    }

    func testMinorAndMajorCarry() {
        XCTAssertTrue(Updater.isNewer([0, 10, 0], than: [0, 9, 9]))
        XCTAssertTrue(Updater.isNewer([1, 0, 0], than: [0, 9, 9]))
    }

    func testEqualAndOlderAreNotNewer() {
        XCTAssertFalse(Updater.isNewer([0, 9, 9], than: [0, 9, 9]))
        XCTAssertFalse(Updater.isNewer([0, 9, 8], than: [0, 9, 9]))
    }

    func testMissingPlacesReadAsZero() {
        XCTAssertFalse(Updater.isNewer([0, 10], than: [0, 10, 0]))
        XCTAssertTrue(Updater.isNewer([0, 10, 1], than: [0, 10]))
    }

    // MARK: - Feed parsing

    private func feed(_ json: String) -> Data { Data(json.utf8) }

    func testPicksTheZipAmongAssets() {
        let release = Updater.parseFeed(feed("""
        [{"tag_name": "v0.9.9", "draft": false, "prerelease": true, "assets": [
            {"name": "lodestar-0.9.9.dmg", "browser_download_url": "https://example.com/lodestar-0.9.9.dmg"},
            {"name": "lodestar-0.9.9.zip", "browser_download_url": "https://example.com/lodestar-0.9.9.zip"}
        ]}]
        """))
        XCTAssertEqual(release?.tag, "v0.9.9")
        XCTAssertEqual(release?.version, [0, 9, 9])
        XCTAssertEqual(release?.zipName, "lodestar-0.9.9.zip")
        XCTAssertEqual(release?.zipURL, "https://example.com/lodestar-0.9.9.zip")
    }

    func testSkipsDraftsAndZiplessReleases() {
        XCTAssertNil(Updater.parseFeed(feed("""
        [{"tag_name": "v0.9.9", "draft": true, "assets": [
            {"name": "lodestar-0.9.9.zip", "browser_download_url": "https://example.com/z.zip"}
        ]}]
        """)))
        XCTAssertNil(Updater.parseFeed(feed("""
        [{"tag_name": "v0.9.9", "draft": false, "assets": [
            {"name": "lodestar-0.9.9.dmg", "browser_download_url": "https://example.com/d.dmg"}
        ]}]
        """)))
    }

    func testIgnoresForeignAssetNames() {
        // Only lodestar-<version>.zip is the update artifact; anything
        // else zipped on the release is not.
        XCTAssertNil(Updater.parseFeed(feed("""
        [{"tag_name": "v0.9.9", "draft": false, "assets": [
            {"name": "symbols.zip", "browser_download_url": "https://example.com/s.zip"}
        ]}]
        """)))
    }

    func testSurvivesMalformedFeed() {
        XCTAssertNil(Updater.parseFeed(feed("not json")))
        XCTAssertNil(Updater.parseFeed(feed("[]")))
        XCTAssertNil(Updater.parseFeed(feed("{\"message\": \"rate limited\"}")))
        XCTAssertNil(Updater.parseFeed(feed("[{\"tag_name\": \"nightly\", \"assets\": []}]")))
    }

    // MARK: - The quiet gate

    func testGateNeedsBothQuietAndSilence() {
        XCTAssertTrue(Updater.mayApply(engineQuiet: true, secondsSinceActivity: 600))
        XCTAssertFalse(Updater.mayApply(engineQuiet: false, secondsSinceActivity: 3600))
        XCTAssertFalse(Updater.mayApply(engineQuiet: true, secondsSinceActivity: 599))
    }

    func testGateHonorsACustomMinimum() {
        XCTAssertTrue(Updater.mayApply(engineQuiet: true, secondsSinceActivity: 5, minimumQuiet: 5))
        XCTAssertFalse(Updater.mayApply(engineQuiet: true, secondsSinceActivity: 4, minimumQuiet: 5))
    }

    // MARK: - Single flight

    func testCheckStartsOnlyFromIdle() {
        XCTAssertEqual(Updater.checkDecision(in: .idle), .startCheck)
    }

    func testRepeatedCheckJoinsTheRunInFlight() {
        XCTAssertEqual(Updater.checkDecision(in: .checking),
                       .refuse(note: "⌖ already checking for updates…"))
        XCTAssertEqual(Updater.checkDecision(in: .ready(version: "0.9.12")), .applyStaged)
    }

    func testCheckDuringApplyRefusesAndNamesTheVersion() {
        guard case .refuse(let note) = Updater.checkDecision(in: .applying(version: "0.9.12")) else {
            return XCTFail("a check mid-apply must refuse — a second pipeline once destroyed the install")
        }
        XCTAssertTrue(note.contains("0.9.12"))
    }

    func testApplyBeginsOnlyFromReady() {
        XCTAssertTrue(Updater.canBeginApply(in: .ready(version: "0.9.12")))
        XCTAssertFalse(Updater.canBeginApply(in: .idle))
        XCTAssertFalse(Updater.canBeginApply(in: .checking))
        XCTAssertFalse(Updater.canBeginApply(in: .applying(version: "0.9.12")))
    }

    /// The version travels with the phase, so no edit can set one without
    /// the other — the split that used to need two fields kept in step.
    func testPhaseCarriesItsOwnVersion() {
        XCTAssertNil(Updater.Phase.idle.version)
        XCTAssertNil(Updater.Phase.checking.version)
        XCTAssertEqual(Updater.Phase.ready(version: "0.9.12").version, "0.9.12")
        XCTAssertEqual(Updater.Phase.applying(version: "0.9.12").version, "0.9.12")
    }

    // MARK: - The rollback tombstone

    func testARolledBackReleaseIsNotOfferedAgain() {
        let release = Updater.Release(tag: "v0.9.12", version: [0, 9, 12],
                                      zipName: "lodestar-0.9.12.zip", zipURL: "https://example/z.zip")
        XCTAssertTrue(Updater.shouldOffer(release, refusedTag: nil))
        XCTAssertFalse(Updater.shouldOffer(release, refusedTag: "v0.9.12"),
                       "a build that never took the pid file must not be re-applied on a loop")
    }

    func testANewerReleaseClearsTheRefusal() {
        let next = Updater.Release(tag: "v0.9.13", version: [0, 9, 13],
                                   zipName: "lodestar-0.9.13.zip", zipURL: "https://example/z.zip")
        XCTAssertTrue(Updater.shouldOffer(next, refusedTag: "v0.9.12"),
                      "the fix ships as a new tag and must be offered")
    }
}
