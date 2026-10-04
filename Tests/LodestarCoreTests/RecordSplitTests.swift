import Foundation
import XCTest
@testable import LodestarCore

/// The two records stand apart: what the coach reads (the ring) and the
/// health record each have their own switch, their own files and their
/// own clear, and neither can take the other with it.
final class RecordSplitTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-split-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> ObservationStore {
        ObservationStore(file: directory.appendingPathComponent("observations.json"),
                         log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func pulse(at t: Date) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .pulse)
        event.keys = 100
        return event
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testHealthKeepsRecordingWithObservationsOff() {
        let store = store()
        store.setEnabled(false)
        store.setHealthEnabled(true)
        store.healthPulse(pulse(at: start))
        store.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        store.flush()
        XCTAssertEqual(store.healthLog.readAll().count, 1, "health answers to its own switch")
        XCTAssertTrue(store.log.readAll().isEmpty, "observations off records nothing")
        XCTAssertFalse(exists("events.jsonl"))
        XCTAssertFalse(exists("observations.json"))
    }

    func testObservationsOffLeavesTheFilesUntouchedAtLoad() throws {
        let first = store()
        first.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        first.flush()
        let ring = directory.appendingPathComponent("events.jsonl")
        let before = try Data(contentsOf: ring)
        let modified = try FileManager.default.attributesOfItem(atPath: ring.path)[.modificationDate] as? Date

        let second = store()
        second.setEnabled(false)
        second.setHealthEnabled(false)
        second.load()
        second.flush()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try Data(contentsOf: ring), before)
        let after = try FileManager.default.attributesOfItem(atPath: ring.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, after, "no rotation, no rewrite, while off")
        XCTAssertFalse(exists("rollups.json"))
    }

    func testClearingOneRecordLeavesTheOther() {
        let store = store()
        store.healthPulse(pulse(at: start))
        store.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        store.flush()
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent(KeyStore.subdirectory),
                                                 withIntermediateDirectories: true)

        store.clearLogbook()
        XCTAssertTrue(store.log.readAll().isEmpty)
        XCTAssertEqual(store.healthLog.readAll().count, 1, "the health record outlives a logbook clear")
        XCTAssertTrue(exists(KeyStore.subdirectory))

        store.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        store.flush()
        store.clearHealth()
        XCTAssertTrue(store.healthLog.readAll().isEmpty)
        XCTAssertFalse(exists(KeyStore.subdirectory), "the per-press record goes with health")
        XCTAssertEqual(store.log.readAll().count, 1, "the ring outlives a health clear")
    }

    func testClearRequestsNameWhichRecord() {
        let store = store()
        store.requestClear(logbook: false, health: true)
        let asked = store.consumeClearRequest()
        XCTAssertFalse(asked.logbook)
        XCTAssertTrue(asked.health)
        let again = store.consumeClearRequest()
        XCTAssertFalse(again.logbook || again.health, "a request is consumed once")
    }

    /// Health that once lived in the ring moves to the health log, once,
    /// and the ring keeps everything else.
    func testHealthMovesOutOfTheRingOnce() {
        let log = EventLog(file: directory.appendingPathComponent("events.jsonl"))
        log.append(pulse(at: start))
        var chain = ObservationEvent(t: start.addingTimeInterval(1), kind: .chain)
        chain.chain = ["s"]
        log.append(chain)
        log.flush()

        let store = store()
        store.moveHealthOutOfTheRing()
        XCTAssertEqual(store.log.readAll().map(\.kind), [.chain])
        XCTAssertEqual(store.healthLog.readAll().map(\.kind), [.pulse])

        // A second run finds the marker and leaves both alone.
        store.moveHealthOutOfTheRing()
        XCTAssertEqual(store.healthLog.readAll().count, 1)
        XCTAssertEqual(store.allEvents().map(\.kind), [.pulse, .chain], "research reads both, oldest first")
    }

    func testTheHealthWarningWaitsForTheBound() {
        XCTAssertNil(Retention.warning(for: .init(bytes: 100 << 20, bound: 1 << 30)))
        let near = Retention.warning(for: .init(bytes: 900 << 20, bound: 1 << 30))
        XCTAssertEqual(near, "The health record holds 900 MB of the 1024 MB planned for it. Nothing is trimmed on its own")
    }
}
