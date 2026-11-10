import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The monthly roll reads the logs a month at a time. What it writes must be
/// what it wrote when it read them whole: the same bytes, whatever the state
/// the ring is in (rotated, not rotated, half rotated, with events pending),
/// whichever months the file already holds, and at every month's turn.
final class RollupStreamTests: XCTestCase {
    private static let now = SyntheticLogbook.utc("2026-11-09T12:00:00Z")
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-rollstream-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Six months of a logbook with only the turns in August (a month with
    /// next to nothing between two full ones), and every month's turn marked
    /// with what a fold does at one: the order the events were appended in is
    /// not the order of their stamps.
    private static let events: [ObservationEvent] = {
        let june = SyntheticLogbook.events(from: SyntheticLogbook.utc("2026-06-20T00:00:00Z"),
                                           days: 42, perDay: 60, seed: 5)
        let autumn = SyntheticLogbook.events(from: SyntheticLogbook.utc("2026-09-01T00:00:00Z"),
                                             days: 69, perDay: 60, seed: 9)
        let turns = SyntheticLogbook.boundaryEvents(monthStarts: ["2026-07-01", "2026-08-01", "2026-09-01",
                                                                  "2026-10-01", "2026-11-01"]
            .map { SyntheticLogbook.utc("\($0)T00:00:00Z") })
        return june + autumn + turns
    }()

    private func makeStore() -> ObservationStore {
        ObservationStore(file: directory.appendingPathComponent("observations.json"),
                         vault: SealedFixture.vault(directory))
    }

    /// Each event into the record the app files it under.
    private func append(_ events: [ObservationEvent], to store: ObservationStore) {
        for (index, event) in events.enumerated() {
            (ObservationEvent.healthKinds.contains(event.kind) ? store.healthLog : store.log).append(event)
            if index % 4000 == 3999 { store.log.flush(); store.healthLog.flush() }
        }
    }

    private func flush(_ store: ObservationStore) {
        store.log.flush()
        store.healthLog.flush()
    }

    private var ring: Vault.Ring { SealedFixture.vault(directory).ring(.logbook) }

    private func opened(_ file: URL) -> [UInt8]? {
        SealedValueFile(url: file, ring: ring, fileSystem: PosixFileSystem()).read().bytes
    }

    /// What was written to `file` before the roll: months a past roll
    /// archived, one of them marked so that a recomputed month shows.
    private func archive(months keep: [String], into files: [URL]) throws {
        var seed = Rollup()
        let built = Rollup.build(events: Self.events, now: Self.now)
        for key in keep {
            var month = try XCTUnwrap(built[key], key)
            month.events = 999_999
            seed.months[key] = month
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(seed)
        for file in files {
            XCTAssertEqual(SealedValueFile(url: file, ring: ring, fileSystem: PosixFileSystem()).write([UInt8](data)),
                           .written)
        }
    }

    /// Roll the whole read to `old.json` and the stream to `rollups.json`,
    /// and say they are the same file.
    @discardableResult
    private func assertSameArchive(_ store: ObservationStore, expectingAdded: [String]? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let whole = directory.appendingPathComponent("old.json")
        let oldOutcome = Rollup.roll(events: store.allEvents(), file: whole, ring: ring, now: Self.now)
        let newOutcome = store.roll(now: Self.now)
        XCTAssertEqual(newOutcome, oldOutcome, "the same months archived", file: file, line: line)
        XCTAssertFalse(newOutcome.added.isEmpty, "a roll that archives nothing proves nothing", file: file, line: line)
        if let expectingAdded { XCTAssertEqual(newOutcome.added, expectingAdded, file: file, line: line) }
        let old = try XCTUnwrap(opened(whole), "the old roll wrote nothing", file: file, line: line)
        let new = try XCTUnwrap(opened(store.rollupFile), "the new roll wrote nothing", file: file, line: line)
        XCTAssertEqual(new.count, old.count, file: file, line: line)
        XCTAssertTrue(new == old, "rollups.json differs from what the whole read wrote", file: file, line: line)
        return newOutcome.added
    }

    func testARotatedRingRollsToTheBytesTheWholeReadWrote() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        store.log.compact(now: Self.now)
        store.healthLog.compact(now: Self.now)
        try assertSameArchive(store, expectingAdded: ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
    }

    func testARingNeverRotatedHoldsEveryMonthInItsLiveFile() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        try assertSameArchive(store, expectingAdded: ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
    }

    /// Rotated a month early, then a straggler for a closed month lands in
    /// the live file at the instant a shard's event has, and events are still
    /// pending: shard, then live file, then pending, is the old order.
    func testAHalfRotatedRingWithStragglersAndPendingEventsKeepsTheOldOrder() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        let october = SyntheticLogbook.utc("2026-10-02T00:00:00Z")
        store.log.compact(now: october)
        store.healthLog.compact(now: october)
        let september = Self.events.filter { $0.kind == .focus && $0.t > SyntheticLogbook.utc("2026-09-10T00:00:00Z")
            && $0.t < SyntheticLogbook.utc("2026-09-11T00:00:00Z") }
        let twin = try XCTUnwrap(september.first)
        var straggler = twin
        straggler.app = "Straggler"
        var lateStretch = ObservationEvent(t: twin.t.addingTimeInterval(-3600), kind: .pulse)
        lateStretch.activeMinutes = 11
        lateStretch.boutIndex = 0
        store.log.append(straggler)
        store.healthLog.append(lateStretch)
        flush(store)
        // Pending, in a closed month and in the open one, in both records.
        var pendingFocus = ObservationEvent(t: twin.t, kind: .focus)
        pendingFocus.app = "Pending"
        var pendingPulse = ObservationEvent(t: Self.now.addingTimeInterval(-60), kind: .pulse)
        pendingPulse.activeMinutes = 5
        store.log.append(pendingFocus)
        store.healthLog.append(pendingPulse)
        _ = store.log.readAll()
        _ = store.healthLog.readAll()
        try assertSameArchive(store, expectingAdded: ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
    }

    /// The file already holds July and September, marked: those months are
    /// not replaced, and June, August and October are what a whole read made
    /// of them, the dwell that opens October included, because the stored
    /// months are still folded for what they end in.
    func testStoredMonthsAreFoldedForTheMonthsAfterThem() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        store.log.compact(now: Self.now)
        store.healthLog.compact(now: Self.now)
        try archive(months: ["2026-07", "2026-09"],
                    into: [directory.appendingPathComponent("old.json"), store.rollupFile])
        try assertSameArchive(store, expectingAdded: ["2026-06", "2026-08", "2026-10"])
        let written = try XCTUnwrap(Rollup.load(file: store.rollupFile, ring: ring).archive)
        XCTAssertEqual(written.months["2026-09"]?.events, 999_999, "a stored month is never replaced")
        XCTAssertEqual(written.months["2026-07"]?.events, 999_999)
        XCTAssertGreaterThan(written.months["2026-10"]?.weeks.values.map(\.switches).reduce(0, +) ?? 0, 0)
    }

    /// Nothing new to archive: the fold runs over every stored month and the
    /// file is not written.
    func testAFullyArchivedRingWritesNothing() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        store.log.compact(now: Self.now)
        store.healthLog.compact(now: Self.now)
        try archive(months: ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"], into: [store.rollupFile])
        let before = try XCTUnwrap(opened(store.rollupFile))
        XCTAssertEqual(store.roll(now: Self.now), Rollup.Outcome())
        XCTAssertTrue(try XCTUnwrap(opened(store.rollupFile)) == before)
    }

    /// A shard that carries a line of another month cannot be read in month
    /// order: the stream says so, and the roll reads the whole ring, as it did.
    func testAShardWithALineOfAnotherMonthFallsBackToTheWholeRead() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        store.log.compact(now: Self.now)
        store.healthLog.compact(now: Self.now)
        // An August line written into September's shard.
        let shard = SealedFixture.eventLog(store.log.shardFile(for: "2026-09"))
        var stray = ObservationEvent(t: SyntheticLogbook.utc("2026-08-15T10:00:00Z"), kind: .focus)
        stray.app = "Stray"
        shard.append(stray)
        shard.flush()
        shard.close()

        let stream = MonthStream([store.log, store.healthLog])
        _ = stream.months()
        XCTAssertThrowsError(try stream.visit("2026-09", kinds: nil) { _ in }) {
            XCTAssertTrue($0 is EventLog.MisplacedLine)
        }
        let added = try assertSameArchive(store)
        XCTAssertTrue(added.contains("2026-08"), "the stray's own month is rolled, as the whole read does")
    }

    func testMonthsAreTheUnionOfShardsLiveFileAndPending() throws {
        let store = makeStore()
        append(Self.events, to: store)
        flush(store)
        store.log.compact(now: Self.now)
        store.healthLog.compact(now: Self.now)
        let stream = MonthStream([store.log, store.healthLog])
        XCTAssertEqual(stream.months(), ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10", "2026-11"])
    }
}
