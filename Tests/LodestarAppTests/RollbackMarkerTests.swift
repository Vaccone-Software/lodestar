import StoicStore
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What a launch makes of the markers a handover leaves, now that the release
/// has a record beside them. The markers stay the protocol (the watchdog is a
/// bash script, and a rollback can land on a build from before records), and
/// are read and written as they always were; the record is what carries the
/// announcement across the relay and the resident, once.
///
/// After an update the successor is a relay: it hands the session to launchd
/// and bows out within a second, before the four seconds an announcement
/// waits (here a tenth of a second, `announcementDelay`). What it recorded is
/// there for the resident. A test run resolves `Paths.update` into a home of
/// its own, which `setUp` checks before anything is written there; the
/// records are kept in a folder of the test's own, which two controllers
/// share as a relay and a resident share the person's.
///
/// An instance that is gone is an instance that is deallocated: its pending
/// work holds it weakly, as a process that has exited runs nothing, so no
/// announcement of one test's instance outlives it into the next test.
final class RollbackMarkerTests: XCTestCase {
    private var rolledBack: URL { Paths.update.appendingPathComponent("rolled-back") }
    private var refused: URL { Paths.update.appendingPathComponent("refused") }
    private var updated: URL { Paths.update.appendingPathComponent("updated-to") }
    private let tag = "v9.9.9"
    private var folder: URL!
    private var recordsPath: String { folder.appendingPathComponent("releases").path }

    override func setUp() {
        continueAfterFailure = false
        XCTAssertTrue(Paths.update.standardizedFileURL.path.hasPrefix(TestRun.home.standardizedFileURL.path),
                      "the update directory is the test run's own, not the person's")
        continueAfterFailure = true
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("update-boot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clean()
    }

    override func tearDown() {
        clean()
        try? FileManager.default.removeItem(at: folder)
    }

    private func clean() {
        for url in [rolledBack, refused, updated] { try? FileManager.default.removeItem(at: url) }
    }

    private func leaveRollback() throws {
        try? FileManager.default.createDirectory(at: Paths.update, withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: rolledBack)
    }

    private func leaveUpdate(_ version: String = Lodestar.version) throws {
        try? FileManager.default.createDirectory(at: Paths.update, withIntermediateDirectories: true)
        try Data(version.utf8).write(to: updated)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// What the record says, and an instance's own words for it.
    private var recorded: String { "⚠ 9.9.9 did not start, so Lodestar went back to \(Lodestar.version)" }
    /// What the marker said, for an instance with no record to say it from.
    private var fromMarker: String { "⚠ \(tag) did not start, so Lodestar went back to \(Lodestar.version)" }
    private var updatedWords: String { Self.said(UpdateController.Voice.updated(Lodestar.version)) }

    private static func said(_ words: (String, String)) -> String { "\(words.0) · \(words.1)" }

    /// Polls until `condition`, or `seconds` have passed. The test's thread is not the main thread, which
    /// the test runner's wait keeps turning, so what hops to main arrives while this sleeps.
    @discardableResult
    private func eventually(_ seconds: TimeInterval = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    /// Time for something that must not happen to have had its chance.
    private func linger(_ seconds: TimeInterval = 0.6) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private final class Holder: @unchecked Sendable {
        // Set once by the test's own polling, read by the test after it.
        var store: ReleaseRecords.Store?
    }

    private final class Said: @unchecked Sendable {
        // Written from the main queue alone, read by the test after it has waited.
        var flashes: [String] = []
        var voices: [String] = []
        var all: [String] { flashes + voices }
    }

    private func records(at path: String? = nil) -> ReleaseRecords {
        ReleaseRecords(path: path ?? recordsPath, lockWait: .seconds(4))
    }

    private func instance(_ said: Said, records: ReleaseRecords? = nil, installed: Bool = true) -> UpdateController {
        let controller = UpdateController(
            installURL: installed ? URL(fileURLWithPath: "/Applications/lodestar.app") : nil,
            records: records ?? self.records())
        controller.flash = { said.flashes.append($0) }
        controller.voice = { sentence, detail, _, _ in said.voices.append("\(sentence) · \(detail ?? "")") }
        controller.announcementDelay = .milliseconds(100)
        return controller
    }

    private func rows(_ records: ReleaseRecords? = nil) async -> [ReleaseRecords.Row] {
        await (records ?? self.records()).rows() ?? []
    }

    // MARK: - A rollback, said by the instance that stays

    func testARelayThatBowsOutLeavesTheRollbackForTheResidentInTheRecord() async throws {
        try leaveRollback()
        let relaySaid = Said()
        var relay: UpdateController? = instance(relaySaid)
        weak var gone = relay
        relay?.boot()
        relay = nil
        XCTAssertNil(gone, "the relay has exited: it will run nothing")
        XCTAssertEqual(text(refused), tag, "the tombstone is written the first time, for the builds that read only it")
        let retired = await eventually { self.text(self.rolledBack) == nil }
        XCTAssertTrue(retired, "the record holds the verdict, so the marker has done its work")
        XCTAssertEqual(text(refused), tag)

        let said = Said()
        let resident = instance(said)
        resident.boot()
        XCTAssertEqual(text(refused), tag, "written again by the resident: still the one tag")
        let heard = await eventually { !said.flashes.isEmpty }
        XCTAssertTrue(heard)
        await linger()
        XCTAssertEqual(said.flashes, [recorded], "the resident says it, from the record the relay made")
        XCTAssertEqual(relaySaid.all, [], "the relay said nothing")
        let all = await rows()
        XCTAssertEqual(all.map(\.state), [.rolledBack])
        withExtendedLifetime(resident) {}
    }

    func testAResidentThatNeverSaysReadyStillSaysTheRollbackAndAThirdInstanceSaysNothing() async throws {
        try leaveRollback()
        let said = Said()
        let resident = instance(said)
        resident.boot()
        let heard = await eventually { !said.flashes.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertEqual(said.flashes, [recorded])
        let retired = await eventually { self.text(self.rolledBack) == nil }
        XCTAssertTrue(retired)
        XCTAssertEqual(text(refused), tag)

        let thirdSaid = Said()
        let third = instance(thirdSaid)
        third.boot()
        await linger(0.8)
        XCTAssertEqual(thirdSaid.all, [], "a rollback said once is not said again")
        XCTAssertEqual(said.flashes, [recorded])
        withExtendedLifetime((resident, third)) {}
    }

    func testTheResidentRetiresTheRollbackWhenItSaysReadyAndStillSaysIt() async throws {
        try leaveRollback()
        let said = Said()
        let resident = instance(said)
        resident.boot()
        resident.acknowledgeBoot()
        XCTAssertNil(text(rolledBack), "said ready: the marker has done its work")
        XCTAssertEqual(text(refused), tag, "the tombstone outlives it")
        let heard = await eventually { !said.flashes.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertEqual(said.flashes, [recorded], "what was owed at boot is still said")
        withExtendedLifetime(resident) {}
    }

    /// Before records a relay that outlived the four seconds and the resident each said it. Now
    /// the record owes it once, and whichever of them is first to take it says it.
    func testARelayThatSurvivesPastTheDelayAndTheResidentSayItOnceBetweenThem() async throws {
        try leaveRollback()
        let relaySaid = Said()
        let residentSaid = Said()
        let relay = instance(relaySaid)
        let resident = instance(residentSaid)
        relay.boot()
        resident.boot()
        let heard = await eventually { !relaySaid.flashes.isEmpty || !residentSaid.flashes.isEmpty }
        XCTAssertTrue(heard)
        await linger(1)
        XCTAssertEqual(relaySaid.flashes.count + residentSaid.flashes.count, 1,
                       "a second flash of the same words was the old behavior; the record says it once")
        XCTAssertNil(text(rolledBack))
        XCTAssertEqual(text(refused), tag)
        let all = await rows()
        XCTAssertEqual(all.map(\.state), [.rolledBack])
        withExtendedLifetime((relay, resident)) {}
    }

    // MARK: - What the record took but could not say

    /// The record took the update at boot, and then could not deliver what
    /// it owes (the other instance of a handover holding the store past the
    /// wait, twice): the marker's words are said, so the update is not
    /// silent for the session. It was silent: the fallback asked only
    /// whether boot had recorded it.
    func testAnUpdateTheRecordTookButCouldNotDeliverIsSaidFromTheMarker() async throws {
        try leaveUpdate()
        let said = Said()
        let quick = ReleaseRecords(path: recordsPath, lockWait: .seconds(1))
        let resident = instance(said, records: quick)
        resident.announcementDelay = .milliseconds(800)
        resident.deliveryRetryDelay = .milliseconds(100)
        resident.boot()
        // Take the store's lock once boot has committed the update, and keep
        // it: seen under the lock, so the test can never take it before boot.
        let path = recordsPath
        let id = try XCTUnwrap(ReleaseOnThisMac.id(for: Lodestar.version))
        let holder = Holder()
        let taken = await eventually {
            guard let store = try? await ReleaseRecords.Store.open(
                at: path, journalOptions: Journal.Options(crossProcessLock: true)) else { return false }
            if (try? await store.read(id))?.state == .running {
                holder.store = store
                return true
            }
            try? await store.close()
            return false
        }
        XCTAssertTrue(taken, "boot confirmed it, and the test holds the store")
        let heard = await eventually { !said.voices.isEmpty }
        XCTAssertTrue(heard, "said from the marker when the record could not say it")
        XCTAssertEqual(said.voices, [updatedWords])
        try await holder.store?.close()
        withExtendedLifetime(resident) {}
    }

    // MARK: - An update, said once

    /// 0.54.24 wrote the marker and no record: the build it updated to makes one from the marker.
    func testAMarkerOnlyPredecessorIsConfirmedAndTheUpdateSaidOnce() async throws {
        try leaveUpdate()
        let said = Said()
        let controller = instance(said)
        controller.boot()
        XCTAssertTrue(controller.justUpdated, "known at once, for whatever must not be modal this launch")
        let heard = await eventually { !said.voices.isEmpty }
        XCTAssertTrue(heard)
        await linger()
        XCTAssertEqual(said.voices, [updatedWords])
        XCTAssertEqual(said.flashes, [])
        let all = await rows()
        XCTAssertEqual(all.map(\.state), [.running])
        XCTAssertEqual(all.first?.by, "successor(pid: \(ProcessInfo.processInfo.processIdentifier))")
        XCTAssertEqual(text(updated), Lodestar.version, "the marker stays until the instance that stays says ready")
        withExtendedLifetime(controller) {}
    }

    /// The marker's text and this build's version are compared as versions: `v…` and a fourth place
    /// that is zero are the same release, and a string compare called them a build that did not change.
    func testTheMarkerIsComparedAsAVersionNotAsText() async throws {
        try leaveUpdate("v\(Lodestar.version).0")
        let said = Said()
        let controller = instance(said)
        controller.boot()
        XCTAssertTrue(controller.justUpdated)
        let heard = await eventually { !said.voices.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertNil(text(refused), "not a build that did not change the binary")
        XCTAssertNotNil(text(updated), "and its marker is left for ready")
        withExtendedLifetime(controller) {}
    }

    func testTheRelayAndTheResidentBothBootingSayTheUpdateOnce() async throws {
        try leaveUpdate()
        let relaySaid = Said()
        let residentSaid = Said()
        let relay = instance(relaySaid)
        let resident = instance(residentSaid)
        relay.boot()
        resident.boot()
        let heard = await eventually { !relaySaid.voices.isEmpty || !residentSaid.voices.isEmpty }
        XCTAssertTrue(heard)
        await linger(1)
        XCTAssertEqual(relaySaid.voices.count + residentSaid.voices.count, 1)
        let all = await rows()
        XCTAssertEqual(all.map(\.state), [.running])
        withExtendedLifetime((relay, resident)) {}
    }

    /// Ready never came, so the marker is still there at every boot, and every boot said it again.
    func testBootsRepeatedBeforeReadySayTheUpdateOnce() async throws {
        try leaveUpdate()
        let said = Said()
        for _ in 0..<3 {
            let controller = instance(said)
            controller.boot()
            await linger(0.5)
            withExtendedLifetime(controller) {}
        }
        XCTAssertEqual(said.voices, [updatedWords])
    }

    /// The v0.32.4 guard: applied, relaunched, and still not that version.
    func testABuildThatDidNotChangeTheBinaryIsRefusedAndNothingIsSaid() async throws {
        try leaveUpdate("9.9.9")
        let said = Said()
        let controller = instance(said)
        controller.boot()
        XCTAssertFalse(controller.justUpdated)
        XCTAssertNil(text(updated), "retired at once, as before")
        XCTAssertEqual(text(refused), "9.9.9", "and the tombstone written, for the builds that read only it")
        let refusedInRecord = await eventually { await self.rows().first?.state == .refused }
        XCTAssertTrue(refusedInRecord)
        await linger()
        XCTAssertEqual(said.all, [], "it only logged, and it still does")
        withExtendedLifetime(controller) {}
    }

    // MARK: - Who may be offered what

    func testAnImportedTombstoneIsNotOfferedEvenWhenTheFileIsGone() async throws {
        try? FileManager.default.createDirectory(at: Paths.update, withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: refused)
        let said = Said()
        let controller = instance(said)
        let release = Updater.Release(tag: tag, version: [9, 9, 9], zipName: "lodestar-9.9.9.zip",
                                      zipURL: Updater.downloads + "v9.9.9/lodestar-9.9.9.zip")
        XCTAssertFalse(controller.mayOffer(release), "the tombstone refuses it")
        controller.boot()
        let imported = await eventually { await self.rows().map(\.state) == [.refused] }
        XCTAssertTrue(imported, "the tombstone became a record")
        try FileManager.default.removeItem(at: refused)
        let refusedByRecord = await eventually { !controller.mayOffer(release) }
        XCTAssertTrue(refusedByRecord, "and the record refuses it with the file gone")
        let newer = Updater.Release(tag: "v9.9.10", version: [9, 9, 10], zipName: "lodestar-9.9.10.zip",
                                    zipURL: Updater.downloads + "v9.9.10/lodestar-9.9.10.zip")
        XCTAssertTrue(controller.mayOffer(newer), "a newer release is another record")
        withExtendedLifetime(controller) {}
    }

    func testARolledBackReleaseIsNotOfferedWhateverBecomesOfTheTombstone() async throws {
        try leaveRollback()
        let controller = instance(Said())
        controller.boot()
        let release = Updater.Release(tag: tag, version: [9, 9, 9], zipName: "lodestar-9.9.9.zip",
                                      zipURL: Updater.downloads + "v9.9.9/lodestar-9.9.9.zip")
        try FileManager.default.removeItem(at: refused)
        let refusedByRecord = await eventually { !controller.mayOffer(release) }
        XCTAssertTrue(refusedByRecord)
        withExtendedLifetime(controller) {}
    }

    // MARK: - Only the installed app

    func testABuildThatIsNotInstalledLeavesThePersonsMarkersAlone() async throws {
        try leaveRollback()
        try leaveUpdate()
        try Data("0.0.1".utf8).write(to: refused)
        let said = Said()
        let controller = instance(said, installed: false)
        controller.start()
        controller.acknowledgeBoot()
        await linger(0.5)
        XCTAssertEqual(text(rolledBack), tag, "not read, not judged, not retired")
        XCTAssertEqual(text(updated), Lodestar.version)
        XCTAssertEqual(text(refused), "0.0.1", "and no tombstone of its own")
        XCTAssertFalse(controller.justUpdated)
        XCTAssertEqual(said.all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsPath), "and no record made")
    }

    // MARK: - A store that cannot be opened: what it was before records

    private func unusableRecords() throws -> ReleaseRecords {
        let file = folder.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        return records(at: file.appendingPathComponent("releases").path)
    }

    func testARollbackWithNoRecordIsFlashedFromTheMarkerAndRetiredWhenSaid() async throws {
        try leaveRollback()
        let said = Said()
        let resident = instance(said, records: try unusableRecords())
        resident.boot()
        XCTAssertEqual(text(rolledBack), tag, "read, not retired: it is retired by being said")
        XCTAssertEqual(text(refused), tag)
        let heard = await eventually { !said.flashes.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertEqual(said.flashes, [fromMarker])
        let retired = await eventually { self.text(self.rolledBack) == nil }
        XCTAssertTrue(retired, "retired once said")
        XCTAssertEqual(text(refused), tag)
        withExtendedLifetime(resident) {}
    }

    func testARelayWithNoRecordLeavesTheMarkerForTheResident() async throws {
        try leaveRollback()
        let relaySaid = Said()
        var relay: UpdateController? = instance(relaySaid, records: try unusableRecords())
        weak var gone = relay
        relay?.boot()
        relay = nil
        XCTAssertNil(gone)
        await linger(0.4)
        XCTAssertEqual(text(rolledBack), tag, "an instance that exits before it can say so leaves the marker")
        XCTAssertEqual(text(refused), tag)
        let said = Said()
        let resident = instance(said, records: try unusableRecords())
        resident.boot()
        let heard = await eventually { !said.flashes.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertEqual(said.flashes, [fromMarker])
        XCTAssertEqual(relaySaid.all, [])
        withExtendedLifetime(resident) {}
    }

    func testAnUpdateWithNoRecordIsSaidFromTheMarker() async throws {
        try leaveUpdate()
        let said = Said()
        let controller = instance(said, records: try unusableRecords())
        controller.boot()
        XCTAssertTrue(controller.justUpdated)
        let heard = await eventually { !said.voices.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertEqual(said.voices, [updatedWords])
        withExtendedLifetime(controller) {}
    }

    func testABuildThatDidNotChangeTheBinaryStillWritesItsTombstoneWithNoRecord() async throws {
        try leaveUpdate("9.9.9")
        let said = Said()
        let controller = instance(said, records: try unusableRecords())
        controller.boot()
        XCTAssertNil(text(updated))
        XCTAssertEqual(text(refused), "9.9.9")
        await linger()
        XCTAssertEqual(said.all, [])
        withExtendedLifetime(controller) {}
    }

    // MARK: - A launch tidies what the last run left half done

    func testALaunchAbandonsAReleaseThatWasDownloadingOrStaged() async throws {
        let records = records()
        records.offered("v9.9.9", because: "the stable feed offered it")                 // downloading
        records.offered("v9.9.10", because: "the stable feed offered it")
        records.record(.verified, of: "v9.9.10", because: "checked")                     // staged
        await records.settled()
        let controller = instance(Said(), records: records)
        controller.start()
        let abandoned = await eventually { await self.rows(records).map(\.state) == [.offered, .offered] }
        XCTAssertTrue(abandoned, "the staging folder is cleared at launch, so nothing is behind either")
        let all = await rows(records)
        XCTAssertEqual(all.map(\.by), ["launch", "launch"])
        withExtendedLifetime(controller) {}
    }

    // MARK: - Said at most as long as it is true

    /// An announcement an earlier launch never said, found by a later release: "Now 0.54.25" on a Mac that
    /// is on another release would be wrong.
    func testAnUpdateAnnouncementForAnotherReleaseIsDiscardedNotSaid() async throws {
        let earlier = records()
        let booted = await earlier.boot(.init(version: "0.0.1", pid: 1, updated: "0.0.1"))
        XCTAssertEqual(booted?.updated, .running)
        let said = Said()
        let controller = instance(said)
        controller.boot()
        await linger(0.8)
        XCTAssertEqual(said.all, [], "0.0.1 is not the release this is")
        let again = Said()
        let next = instance(again)
        next.boot()
        await linger(0.6)
        XCTAssertEqual(again.all, [], "and it was discarded, not kept to be tried at every launch")
        withExtendedLifetime((controller, next)) {}
    }

    // MARK: - What the controller tells the record

    func testAStagedBuildThatIsStoodDownIsOfferedAgainAndADownloadThatFailedIsToo() async throws {
        let records = records()
        let controller = instance(Said(), records: records)
        records.offered("v9.9.9", because: "the stable feed offered it")
        records.record(.verified, of: "v9.9.9", because: "checked")
        records.offered("v9.9.10", because: "the stable feed offered it")
        controller.standDown(releasing: "9.9.9", as: .abandon, because: "updates were turned off")
        controller.downloadFailed(
            Updater.Release(tag: "v9.9.10", version: [9, 9, 10], zipName: "z", zipURL: "https://example.com/z"),
            URLError(.notConnectedToInternet), force: false)
        await records.settled()
        let all = await rows(records)
        XCTAssertEqual(all.map(\.state), [.offered, .offered])
        XCTAssertEqual(all.map(\.because), ["updates were turned off",
                                            "the download failed: " + UpdateDownload.problem(
                                                URLError(.notConnectedToInternet),
                                                release: Updater.Release(tag: "v9.9.10", version: [9, 9, 10],
                                                                         zipName: "z", zipURL: "https://example.com/z"))])
        withExtendedLifetime(controller) {}
    }
}
