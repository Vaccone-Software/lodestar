import Foundation
import Stoic
import StoicStore
import StoicTesting
import Synchronization
import XCTest
@testable import LodestarCore

/// The records as the updater uses them: opened for each piece of work and
/// let go, in order, never in the update's way. A real file system and the
/// real cross-process lock (two stores in one process contend as two
/// processes do: `flock` is per open file), on a test clock so a wait for the
/// other process is something the test moves.
final class ReleaseRecordsTests: XCTestCase {
    typealias Release = ReleaseOnThisMac
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("releases").path }
    /// What the log said, from whichever thread said it.
    private final class Lines: Sendable {
        private let stored = Mutex<[String]>([])
        func add(_ line: String) { stored.withLock { $0.append(line) } }
        func clear() { stored.withLock { $0 = [] } }
        var all: [String] { stored.withLock { $0 } }
    }
    private let logged = Lines()
    private var lines: [String] { logged.all }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("release-records-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logged.clear()
        Log.listener = { [logged] line in logged.add(line) }
    }

    override func tearDown() {
        Log.listener = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func records(lockWait: Duration = .seconds(5)) -> ReleaseRecords {
        ReleaseRecords(path: path, lockWait: lockWait)
    }

    /// A store opened as another process would: with the lock, held until it is closed.
    private func heldByAnotherProcess() async throws -> ReleaseRecords.Store {
        try await ReleaseRecords.Store.open(
            at: path, fileSystem: PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700),
            journalOptions: Journal.Options(crossProcessLock: true))
    }

    private func ambient<R>(_ body: (TestClock) async throws -> R) async throws -> R {
        let clock = TestClock()
        return try await withTestAmbient(clock: clock) { try await body(clock) }
    }

    private let applied = ReleaseRecords.Boot(version: "0.54.25", pid: 4_242, updated: "0.54.25")

    // MARK: - In order, off the caller's thread

    func testWhatWasDecidedFirstIsWrittenFirst() async throws {
        try await ambient { _ in
            let records = records()
            for number in 0..<12 {
                let tag = "v0.60.\(number)"
                records.offered(tag, because: "the stable feed offered it")
                records.record(.verified, of: tag, because: "its signature and version checked out")
                records.record(.apply, of: tag, because: "the quiet gate opened")
            }
            await records.settled()
            let all = await records.rows()
            let rows = try XCTUnwrap(all)
            XCTAssertEqual(rows.map(\.id), (0..<12).map { "0.60.\($0)" }, "in the order they were offered")
            XCTAssertEqual(Set(rows.map(\.state)), [.applying], "download, verified, apply: out of order any one of them is ignored")
            XCTAssertTrue(rows.allSatisfy { $0.by == "updater" && $0.because == "the quiet gate opened" })
        }
    }

    func testCallsReturnWithoutWaitingForTheStore() async throws {
        try await ambient { _ in
            let held = try await heldByAnotherProcess()
            let records = records()
            // The store is held and will be for a long time: none of these waits for it.
            records.offered("0.54.25", because: "the feed offered it")
            records.record(.verified, of: "0.54.25", because: "checked")
            records.abandonInFlight()
            XCTAssertFalse(records.refuses("0.54.25"))
            try await held.close()
        }
    }

    // MARK: - Two processes at once

    func testASecondProcessWaitsForTheFirstToLetGoAndNothingIsLost() async throws {
        try await ambient { clock in
            let first = try await heldByAnotherProcess()
            let inserted = try await first.insert(.new(in: .applying, by: .importer, because: "the first process's"), as: "0.54.24")
            XCTAssertTrue(inserted)
            let second = records()
            second.offered("0.54.25", because: "the second process's")
            await clock.waitForSleepers(count: 1)
            XCTAssertTrue(lines.isEmpty, "waiting for the other process is not a failure to tell: \(lines)")
            try await first.close()
            await clock.advance(by: .milliseconds(100))
            await second.settled()
            let all = await second.rows()
            let rows = try XCTUnwrap(all)
            XCTAssertEqual(rows.map(\.id), ["0.54.24", "0.54.25"], "the first's record is there, and so is the one that waited")
            XCTAssertEqual(rows.map(\.state), [.applying, .downloading])
        }
    }

    func testAStoreHeldBeyondTheWaitIsGivenUpOnAndLogged() async throws {
        try await ambient { clock in
            let held = try await heldByAnotherProcess()
            let records = records(lockWait: .seconds(1))
            let booted = Task { [applied] in await records.boot(applied) }
            // A second at a tenth of a second is ten tries and nine waits between them.
            for _ in 0..<9 {
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .milliseconds(100))
            }
            let result = await booted.value
            XCTAssertNil(result, "no store: the controller does what it did before records")
            XCTAssertTrue(lines.contains { $0.contains("records=unavailable") && $0.contains("markers carry the update") }, "\(lines)")
            // And the one that held it is whole.
            try await held.close()
            let reopened = try await heldByAnotherProcess()
            let leftBehind = await reopened.records().count
            XCTAssertEqual(leftBehind, 0)
            try await reopened.close()
        }
    }

    // MARK: - A store that cannot be used

    func testAStoreThatCannotBeOpenedMakesEveryCallALoggedNoOp() async throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        try await ambient { _ in
            let records = ReleaseRecords(path: file.appendingPathComponent("releases").path)
            records.offered("0.54.25", because: "the feed offered it")
            records.record(.verified, of: "0.54.25", because: "checked")
            records.abandonInFlight()
            let booted = await records.boot(applied)
            let delivered = await records.deliver { _ in XCTFail("nothing is owed"); return .delivered }
            let rows = await records.rows()
            XCTAssertNil(booted)
            XCTAssertFalse(delivered)
            XCTAssertNil(rows)
            XCTAssertFalse(records.refuses("0.54.25"))
            XCTAssertGreaterThanOrEqual(lines.filter { $0.contains("records=unavailable") }.count, 6,
                                        "each piece of work says it could not be done: \(lines)")
        }
    }

    // MARK: - Boot: the markers become events

    func testAMarkerOnlyPredecessorIsConfirmedAndSaidOnce() async throws {
        try await ambient { _ in
            let records = records()
            let result = await records.boot(applied)
            XCTAssertEqual(result, .init(updated: .running, rolledBack: nil))
            let said = Said()
            let first = await records.deliver(using: said.say)
            let second = await records.deliver(using: said.say)
            XCTAssertTrue(first && second)
            XCTAssertEqual(said.all, [.init(id: "0.54.25", announcement: .running)], "said once, however often asked")
            let all = await records.rows()
            let row = try XCTUnwrap(all?.first)
            XCTAssertEqual(row.state, .running)
            XCTAssertEqual(row.by, "successor(pid: 4242)")
        }
    }

    /// On the real clock: the two take turns at the lock, and the one that waits waits in real tenths of a second.
    func testTheRelayAndTheResidentBothBootingSayItOnce() async throws {
        do {
            let relay = records()
            let resident = records()
            let said = Said()
            // Both boot at once, and both are asked to say it at once: the lock makes them take turns.
            async let relayBooted = relay.boot(applied)
            async let residentBooted = resident.boot(.init(version: "0.54.25", pid: 4_243, updated: "0.54.25"))
            let booted = await [relayBooted, residentBooted]
            XCTAssertEqual(booted.map { $0?.updated }, [.running, .running], "the second finds it confirmed: running, not moved")
            async let relaySaid = relay.deliver(using: said.say)
            async let residentSaid = resident.deliver(using: said.say)
            let delivered = await [relaySaid, residentSaid]
            XCTAssertEqual(delivered, [true, true])
            XCTAssertEqual(said.all.count, 1, "\(said.all)")
            let history = try await historyOfOnlyRecord()
            XCTAssertEqual(history.map(\.event), [.confirm], "one confirm in the history; the second boot's was ignored")
        }
    }

    func testBootsRepeatedBeforeReadySayItOnce() async throws {
        try await ambient { _ in
            let said = Said()
            for pid: Int32 in [101, 102, 103, 104] {
                let records = records()
                _ = await records.boot(.init(version: "0.54.25", pid: pid, updated: "0.54.25"))
                _ = await records.deliver(using: said.say)
            }
            XCTAssertEqual(said.all.count, 1, "a marker that stays until ready no longer says it at every boot")
        }
    }

    func testTheVersionIsComparedAsAVersionNotAsText() async throws {
        try await ambient { _ in
            let records = records()
            let result = await records.boot(.init(version: "0.54.25", pid: 7, updated: "v0.54.25.0"))
            XCTAssertEqual(result?.updated, .running, "the raw compare of the strings called this a build that did not change")
        }
    }

    func testARolledBackMarkerIsTheWatchdogsVerdictSaidOnce() async throws {
        try await ambient { _ in
            let records = records()
            let result = await records.boot(.init(version: "0.54.24", pid: 9, rolledBack: "0.54.25"))
            XCTAssertEqual(result, .init(updated: nil, rolledBack: .rolledBack))
            XCTAssertTrue(records.refuses("v0.54.25"), "and the release is not offered again")
            let said = Said()
            _ = await records.deliver(using: said.say)
            _ = await records.deliver(using: said.say)
            XCTAssertEqual(said.all, [.init(id: "0.54.25", announcement: .rolledBack)])
            let history = try await historyOfOnlyRecord()
            XCTAssertEqual(history.map(\.event), [.rollBack])
            XCTAssertEqual(history.first?.by, .principal(.watchdog))
            // The record the marker made for an earlier build's apply says where it came from.
            let created = try await onlyRecord().created
            XCTAssertEqual(created.because, "applied by an earlier build; from its marker")
        }
    }

    func testTheVerdictThatReachesARunningReleaseIsStillRecorded() async throws {
        try await ambient { _ in
            let records = records()
            _ = await records.boot(applied)
            let result = await records.boot(.init(version: "0.54.24", pid: 5, rolledBack: "0.54.25"))
            XCTAssertEqual(result?.rolledBack, .rolledBack)
            XCTAssertTrue(records.refuses("0.54.25"))
        }
    }

    func testABuildThatDidNotChangeTheBinaryIsRefusedAndNothingIsSaid() async throws {
        try await ambient { _ in
            let records = records()
            let result = await records.boot(.init(version: "0.54.24", pid: 9, updated: "0.54.25"))
            XCTAssertEqual(result?.updated, .refused)
            XCTAssertTrue(records.refuses("0.54.25"))
            let said = Said()
            _ = await records.deliver(using: said.say)
            XCTAssertEqual(said.all, [], "the guard only logs")
        }
    }

    func testATombstoneBecomesARefusedRecordAndIsNotOffered() async throws {
        try await ambient { _ in
            let records = records()
            _ = await records.boot(.init(version: "0.54.24", pid: 9, tombstone: "0.54.25"))
            XCTAssertTrue(records.refuses("v0.54.25"))
            XCTAssertFalse(records.refuses("v0.54.26"), "a newer release is another record")
            let created = try await onlyRecord().created
            XCTAssertEqual(created.by, .principal(.importer))
            // A release the tombstone names that already has a record is left as the record has it.
            let again = await records.boot(.init(version: "0.54.24", pid: 9, tombstone: "0.54.25"))
            XCTAssertEqual(again, .init(updated: nil, rolledBack: nil))
            let unchanged = try await historyOfOnlyRecord()
            XCTAssertEqual(unchanged.count, 0)
        }
    }

    /// The other instance of a handover writes the tombstone as soon as it reads the marker, before the
    /// record has the verdict: a boot that finds both is not to read the tombstone as an earlier build's.
    func testATombstoneForTheReleaseTheMarkerNamesDoesNotPreemptTheVerdict() async throws {
        try await ambient { _ in
            let records = records()
            let result = await records.boot(.init(version: "0.54.24", pid: 9, tombstone: "0.54.25", rolledBack: "0.54.25"))
            XCTAssertEqual(result?.rolledBack, .rolledBack, "the verdict, not an import")
            let said = Said()
            _ = await records.deliver(using: said.say)
            XCTAssertEqual(said.all, [.init(id: "0.54.25", announcement: .rolledBack)])
            let created = try await onlyRecord().created
            XCTAssertEqual(created.by, .principal(.importer))
            XCTAssertEqual(created.because, "applied by an earlier build; from its marker", "made from the marker, not the tombstone")
            let mismatch = records
            let other = await mismatch.boot(.init(version: "0.54.24", pid: 9, tombstone: "0.54.26", updated: "0.54.26"))
            XCTAssertEqual(other?.updated, .refused, "and the build that did not change the binary is recorded as that")
            let history = try await historyOf("0.54.26")
            XCTAssertEqual(history.map(\.event), [.unchanged])
        }
    }

    func testARecordForAnApplyThatIsStillWaitingHoldsTheOfferUntilItTimesOut() async throws {
        try await ambient { clock in
            let records = records()
            records.offered("0.54.25", because: "offered")
            records.record(.verified, of: "0.54.25", because: "checked")
            records.record(.apply, of: "0.54.25", because: "swapped in")
            await records.settled()
            XCTAssertTrue(records.refuses("0.54.25"), "applying: a successor may still confirm")
            // Thirty minutes with nobody to confirm it, and a later piece of work sees it refused outright.
            await clock.advance(by: .seconds(31 * 60))
            _ = await records.boot(.init(version: "0.54.24", pid: 1))
            XCTAssertTrue(records.refuses("0.54.25"))
            let rows = await records.rows()
            XCTAssertEqual(rows?.first?.state, .refused)
        }
    }

    func testALaunchAbandonsWhatWasInFlight() async throws {
        try await ambient { _ in
            let records = records()
            records.offered("0.54.25", because: "offered")                         // downloading
            records.offered("0.54.26", because: "offered")
            records.record(.verified, of: "0.54.26", because: "checked")           // staged
            records.offered("0.54.27", because: "offered")
            records.record(.verified, of: "0.54.27", because: "checked")
            records.record(.apply, of: "0.54.27", because: "swapped in")           // applying: not touched
            records.abandonInFlight()
            await records.settled()
            let all = await records.rows()
            let rows = try XCTUnwrap(all)
            XCTAssertEqual(rows.map(\.state), [.offered, .offered, .applying])
            XCTAssertEqual(rows.first?.by, "launch")
        }
    }

    // MARK: - Said at least once, under a key

    func testAnAnnouncementThatWasNotSaidIsOwedToTheNextProcess() async throws {
        try await ambient { _ in
            let first = records()
            _ = await first.boot(applied)
            // The process that owed it exits before it could say it, or says it and is cut off before it can tell.
            let kept = await first.deliver { _ in .keep }
            XCTAssertTrue(kept)
            let said = Said()
            let second = records()
            _ = await second.deliver(using: said.say)
            XCTAssertEqual(said.all, [.init(id: "0.54.25", announcement: .running)])
        }
    }

    func testTheRecordsSurviveARelaunch() async throws {
        try await ambient { _ in
            do {
                let records = records()
                _ = await records.boot(.init(version: "0.54.24", pid: 9, rolledBack: "0.54.25"))
                await records.settled()
            }
            let relaunched = records()
            let rows = await relaunched.rows()
            XCTAssertEqual(rows?.map(\.state), [.rolledBack], "a rollback stands across launches")
            XCTAssertTrue(relaunched.refuses("0.54.25"))
        }
    }

    func testWarmReadsTheSnapshotAtLaunch() async throws {
        try await ambient { _ in
            _ = await records().boot(.init(version: "0.54.24", pid: 9, rolledBack: "0.54.25"))
            let later = records()
            XCTAssertFalse(later.refuses("0.54.25"), "before it has read anything it knows nothing")
            later.warm()
            await later.settled()
            XCTAssertTrue(later.refuses("0.54.25"))
        }
    }

    func testAFileOnlyThisProcessCanReadIsWhatIsWritten() async throws {
        try await ambient { _ in
            let records = records()
            _ = await records.boot(applied)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    // MARK: - Helpers

    private final class Said: Sendable {
        private let seen = Mutex<[ReleaseRecords.Delivery]>([])
        var all: [ReleaseRecords.Delivery] { seen.withLock { $0 } }
        var say: @Sendable (ReleaseRecords.Delivery) async -> DeliveryResult {
            { [self] delivery in seen.withLock { $0.append(delivery) }; return .delivered }
        }
    }

    /// The store as another process would read it, closed again afterwards.
    private func onlyRecord() async throws -> Release.Record {
        let store = try await heldByAnotherProcess()
        let all = await store.records()
        try await store.close()
        XCTAssertEqual(all.count, 1)
        return try XCTUnwrap(all.first?.record)
    }

    private func historyOf(_ id: String) async throws -> [Release.Entry] {
        let store = try await heldByAnotherProcess()
        let history = try await store.history(of: id)
        try await store.close()
        return history
    }

    private func historyOfOnlyRecord() async throws -> [Release.Entry] {
        let store = try await heldByAnotherProcess()
        let all = await store.records()
        XCTAssertEqual(all.count, 1)
        let history = try await store.history(of: try XCTUnwrap(all.first?.id))
        try await store.close()
        return history
    }
}
