import XCTest
@testable import LodestarCore

/// The sharded ring: closed months leave the live file for immutable
/// shards, retention retires whole files, and bounded reads open only
/// what a window touches. The promises are the old ones — nothing
/// appended is lost, order holds — over a year instead of ninety days.
final class EventLogShardTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-shards-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLog() -> EventLog {
        EventLog(file: directory.appendingPathComponent("events.jsonl"))
    }

    private func event(at date: Date) -> ObservationEvent {
        var event = ObservationEvent(t: date, kind: .verb)
        event.verb = "graph"
        return event
    }

    /// A UTC-safe moment inside a month.
    private func day(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    func testCompactionMovesClosedMonthsIntoShards() {
        let log = makeLog()
        let july = day("2026-07-10T12:00:00Z")
        let august = day("2026-08-10T12:00:00Z")
        let september = day("2026-09-05T12:00:00Z")
        for d in [july, august, september] { log.append(event(at: d)) }
        log.flush()
        log.compact(now: september)

        XCTAssertEqual(EventLog.read(file: log.file).count, 1,
                       "the live file keeps only the open month")
        XCTAssertEqual(EventLog.read(file: log.shardFile(for: "2026-07")).count, 1)
        XCTAssertEqual(EventLog.read(file: log.shardFile(for: "2026-08")).count, 1)
        XCTAssertEqual(log.readAll().map(\.t), [july, august, september],
                       "the whole ring reads back, oldest first")
    }

    func testShardsAccumulateAcrossCompactions() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2026-08-01T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        log.append(event(at: day("2026-08-20T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        XCTAssertEqual(EventLog.read(file: log.shardFile(for: "2026-08")).count, 2,
                       "a month that closes across compactions accumulates")
    }

    private func pulse(at date: Date) -> ObservationEvent {
        var event = ObservationEvent(t: date, kind: .pulse)
        event.keys = 10
        event.holdN = 10
        event.holdSum = 0.9
        return event
    }

    /// The ring is bounded by size: over the bound, the oldest month
    /// retires as a whole file — and its health kinds leave first, for
    /// an archive the bound never touches.
    func testTheBoundRetiresTheOldestShardAndArchivesItsHealth() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2026-06-10T12:00:00Z")))
        log.append(pulse(at: day("2026-06-10T12:15:00Z")))
        log.append(event(at: day("2026-07-10T12:00:00Z")))
        log.append(event(at: day("2026-09-01T12:00:00Z")))
        log.flush()
        // Rotation first, under a bound nothing reaches.
        log.compact(now: now)
        let june = log.shardFile(for: "2026-06")
        let july = log.shardFile(for: "2026-07")
        XCTAssertTrue(FileManager.default.fileExists(atPath: june.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: july.path))
        func size(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        // A bound that July and the live file fit under, but June does not.
        log.behavioralBound = size(july) + size(log.file)
        log.compact(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: june.path), "the oldest month retired")
        XCTAssertTrue(FileManager.default.fileExists(atPath: july.path), "and only the oldest")
        XCTAssertEqual(log.readAll().count, 2)
        // June's pulse survived into the health archive; June's verb did not.
        let archived = EventLog.healthArchive(month: "2026-06", beside: log.file)
        XCTAssertEqual(archived.map(\.kind), [.pulse])
        XCTAssertEqual(archived.first?.holdN, 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.healthArchiveFile(for: "2026-06").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.healthArchiveFile(for: "2026-07").path),
                       "a month still in the ring has no archive yet")
    }

    /// A shard that has aged, under the bound, stays: age is not a rule.
    func testAgeAloneRetiresNothing() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2024-06-10T12:00:00Z")))
        log.append(event(at: day("2026-08-10T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.shardFile(for: "2024-06").path))
        XCTAssertEqual(log.readAll().count, 2)
    }

    func testRecentBoundsTheRead() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2026-01-10T12:00:00Z")))
        log.append(event(at: day("2026-08-20T12:00:00Z")))
        log.append(event(at: day("2026-09-01T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        XCTAssertEqual(log.recent(days: 90, now: now).count, 2)
        XCTAssertEqual(log.snapshot(days: 90, now: now).count, 2)
        XCTAssertEqual(log.snapshot(now: now).count, 3, "nil days reads everything")
    }

    func testClearTakesTheShardsToo() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2026-07-10T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        log.clear()
        XCTAssertTrue(log.readAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: log.shardFile(for: "2026-07").path))
    }

    func testShardMonthParsing() {
        XCTAssertEqual(EventLog.shardMonth(
            of: directory.appendingPathComponent("events-2026-08.jsonl")), "2026-08")
        XCTAssertNil(EventLog.shardMonth(
            of: directory.appendingPathComponent("events.jsonl")))
        XCTAssertNil(EventLog.shardMonth(
            of: directory.appendingPathComponent("events-backup.jsonl")))
    }
}
