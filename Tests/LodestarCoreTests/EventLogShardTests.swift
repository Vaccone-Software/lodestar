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

    func testRetentionRetiresWholeShards() {
        let log = makeLog()
        let now = day("2026-09-05T12:00:00Z")
        log.append(event(at: day("2025-06-10T12:00:00Z"))) // 15 months back
        log.append(event(at: day("2026-08-10T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        // The ancient event aged out before ever reaching a shard.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: log.shardFile(for: "2025-06").path))
        // And a shard that exists but has aged out is deleted next pass.
        try? "".write(to: log.shardFile(for: "2025-05"), atomically: true, encoding: .utf8)
        log.append(event(at: day("2026-07-01T12:00:00Z")))
        log.flush()
        log.compact(now: now)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: log.shardFile(for: "2025-05").path))
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
