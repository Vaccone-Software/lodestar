import XCTest
@testable import LodestarCore

/// The two bounds, declared once and measured honestly: the ring counts
/// its live file and shards, the health record its three stores, and
/// eighty percent of either is where the instrument should speak.
final class RetentionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, bytes: Int) {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(repeating: 0, count: bytes).write(to: url)
    }

    func testTheBoundsAreWhatWasAgreed() {
        XCTAssertEqual(Retention.behavioralBytes, 256 * 1024 * 1024)
        XCTAssertEqual(Retention.healthBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(Retention.warnFraction, 0.8)
    }

    func testTheRingCountsItsLiveFileAndShardsOnly() {
        write("events.jsonl", bytes: 100)
        write("events-2026-08.jsonl", bytes: 250)
        write("observations.json", bytes: 1000)
        write("health-2026-07.jsonl.z", bytes: 1000)
        write("keys/keys-2026-09-16.bin", bytes: 1000)
        let usage = Retention.behavioralUsage(in: directory)
        XCTAssertEqual(usage.bytes, 350)
        XCTAssertEqual(usage.bound, Retention.behavioralBytes)
        XCTAssertFalse(usage.nearBound)
    }

    func testTheHealthRecordCountsItsThreeStores() {
        write("keys/keys-2026-09-16.bin", bytes: 300)
        write("keys/keys-2026-09-15.bin.z", bytes: 200)
        write("pointer/pointer-2026-09-16.bin", bytes: 400)
        write("health-2026-07.jsonl.z", bytes: 100)
        write("events.jsonl", bytes: 5000)
        let usage = Retention.healthUsage(in: directory)
        XCTAssertEqual(usage.bytes, 1000)
        XCTAssertEqual(usage.bound, Retention.healthBytes)
    }

    func testNearTheBoundIsEightyPercent() {
        XCTAssertFalse(Retention.Usage(bytes: 79, bound: 100).nearBound)
        XCTAssertTrue(Retention.Usage(bytes: 80, bound: 100).nearBound)
        XCTAssertEqual(Retention.Usage(bytes: 50, bound: 200).fraction, 0.25)
    }
}
