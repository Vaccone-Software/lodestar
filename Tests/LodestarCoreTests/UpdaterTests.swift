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

    // MARK: - Channels

    /// The site's stable answer as it serves it.
    private func stable(tag: String = "v1.47.1", version: String = "1.47.1",
                        zipName: String? = nil, zipURL: String? = nil) -> Data {
        let name = zipName ?? "lodestar-\(version).zip"
        let url = zipURL ?? "https://github.com/Vaccone-Software/lodestar/releases/download/\(tag)/\(name)"
        return feed("""
        {"tag": "\(tag)", "version": "\(version)", "published": "2026-10-02T00:00:00Z",
         "zip": {"name": "\(name)", "url": "\(url)"},
         "preview": {"tag": "v1.48.0"},
         "pending": [{"line": "1.48", "kind": "minor", "since": "2026-10-08T00:00:00Z",
                      "promotes": "2026-10-15T00:00:00Z", "tag": "v1.48.0"}],
         "policy": {"minorSoakDays": 7, "patchSoakDays": 3, "settleDays": 1}}
        """)
    }

    func testPreviewTakesTheNewestBuild() {
        let release = Updater.parse(feed("""
        [{"tag_name": "v1.48.0", "draft": false, "assets": [
            {"name": "lodestar-1.48.0.zip", "browser_download_url": "https://example.com/48.zip"}]},
         {"tag_name": "v1.47.1", "draft": false, "assets": [
            {"name": "lodestar-1.47.1.zip", "browser_download_url": "https://example.com/471.zip"}]}]
        """), channel: .preview)
        XCTAssertEqual(release?.tag, "v1.48.0")
    }

    func testStableTakesTheSitesAnswer() {
        let release = Updater.parse(stable(), channel: .stable)
        XCTAssertEqual(release?.tag, "v1.47.1")
        XCTAssertEqual(release?.version, [1, 47, 1])
        XCTAssertEqual(release?.zipName, "lodestar-1.47.1.zip")
        XCTAssertEqual(release?.zipURL,
                       "https://github.com/Vaccone-Software/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip")
    }

    func testStableRefusesAZipFromAnywhereButTheTagsDownloads() {
        // The site names a build; it never gets to say where a binary
        // comes from. Another host, another repository, another tag's
        // folder, or plain http are all a failed check.
        for url in [
            "https://example.com/lodestar-1.47.1.zip",
            "https://github.com/someone/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip",
            "https://github.com/Vaccone-Software/lodestar/releases/download/v1.48.0/lodestar-1.47.1.zip",
            "http://github.com/Vaccone-Software/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip",
            "https://github.com/Vaccone-Software/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip?x=1",
        ] {
            XCTAssertNil(Updater.parse(stable(zipURL: url), channel: .stable), url)
        }
    }

    func testStableRefusesATagZipOrVersionThatDisagree() {
        XCTAssertNil(Updater.parse(stable(tag: "v1.48.0"), channel: .stable))
        XCTAssertNil(Updater.parse(stable(tag: "1.47.1"), channel: .stable))
        XCTAssertNil(Updater.parse(stable(zipName: "lodestar-1.48.0.zip"), channel: .stable))
        XCTAssertNil(Updater.parse(stable(zipName: "symbols.zip"), channel: .stable))
        XCTAssertNil(Updater.parse(stable(tag: "vnightly", version: "nightly"), channel: .stable))
    }

    func testStableReadsTheSitesErrorAsNoAnswer() {
        // The site answers 503 with this body when GitHub cannot be read:
        // the status is a problem on its own, and the body is no release.
        XCTAssertEqual(Updater.httpProblem(status: 503), "HTTP 503")
        XCTAssertNil(Updater.parse(feed(#"{"error": "GitHub could not be read"}"#), channel: .stable))
        XCTAssertNil(Updater.parse(feed("not json"), channel: .stable))
        XCTAssertNil(Updater.parse(feed("[]"), channel: .stable))
    }

    func testStableNeverReadsTheReleasesList() {
        // A releases list handed to the stable parser is not an answer:
        // stable is the site's to say, never the newest build's.
        XCTAssertNil(Updater.parse(feed("""
        [{"tag_name": "v1.48.0", "draft": false, "assets": [
            {"name": "lodestar-1.48.0.zip", "browser_download_url": "https://example.com/48.zip"}]}]
        """), channel: .stable))
    }

    func testAMacAheadOfStableStaysPut() {
        // Switched from preview while on 1.48.0: stable says 1.47.1, which
        // is not newer, so nothing is offered and nothing moves back.
        let release = Updater.parse(stable(), channel: .stable)!
        XCTAssertFalse(Updater.isNewer(release.version, than: [1, 48, 0]))
    }

    func testStableAsksTheSiteFeedbackGoesTo() {
        XCTAssertEqual(Updater.stableURL.host, Feedback.endpoint.host)
        XCTAssertEqual(Updater.stableURL.scheme, "https")
        XCTAssertEqual(Updater.stableURL.path, "/api/stable")
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
                       .refuse(note: "⟲ Already checking for updates"))
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

    /// The watchdog writes `CFBundleShortVersionString`, which has no `v`,
    /// while the tag it is compared against does. A string compare never
    /// matched, so the gate above passed every time and the same broken
    /// build was re-downloaded, re-applied and rolled back once a day.
    /// This is the form the app actually produces.
    func testTombstoneWrittenByTheWatchdogMatchesTheTag() {
        let release = Updater.Release(tag: "v0.18.0", version: [0, 18, 0],
                                      zipName: "lodestar-0.18.0.zip", zipURL: "https://example/z.zip")
        XCTAssertFalse(Updater.shouldOffer(release, refusedTag: "0.18.0"),
                       "the bare version is what lands in the refused file")
        XCTAssertFalse(Updater.shouldOffer(release, refusedTag: "0.18"),
                       "missing places read as zero, here as everywhere else")
        XCTAssertTrue(Updater.shouldOffer(release, refusedTag: "0.17.9"))
        XCTAssertTrue(Updater.shouldOffer(release, refusedTag: "not-a-version"),
                       "an unreadable tombstone must not wedge updates shut")
    }

    func testANewerReleaseClearsTheRefusal() {
        let next = Updater.Release(tag: "v0.9.13", version: [0, 9, 13],
                                   zipName: "lodestar-0.9.13.zip", zipURL: "https://example/z.zip")
        XCTAssertTrue(Updater.shouldOffer(next, refusedTag: "v0.9.12"),
                      "the fix ships as a new tag and must be offered")
    }
}
