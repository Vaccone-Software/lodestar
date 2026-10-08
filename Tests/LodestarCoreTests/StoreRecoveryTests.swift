import Foundation
import XCTest
@testable import LodestarCore

/// A view file that will not decode (a bug, a schema change, a version
/// from before) is set aside beside itself and the view is rebuilt from
/// the ring, never written over with whatever the ring still holds and
/// never silently dropped.
final class ObservationRecoveryTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("observations.json") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func store() -> ObservationStore {
        ObservationStore(file: file, log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A store that has recorded two chains and saved both the ring and the view.
    private func recorded() -> Observations {
        let first = store()
        first.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        first.chainCompleted(["d"], gaps: [0.4], peeked: true, at: start.addingTimeInterval(60))
        first.flush()
        return first.observations
    }

    private func quarantined() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("observations.json.corrupt-") }
    }

    func testAViewThatWillNotDecodeIsSetAsideAndRebuiltFromTheRing() throws {
        let before = recorded()
        XCTAssertNotEqual(before, Observations(), "something was recorded")
        let garbage = Data("{\"version\": 2, \"chains\": [tru".utf8)
        try garbage.write(to: file)

        let second = store()
        second.load()
        XCTAssertEqual(second.observations, before, "the ring is the truth, replayed")
        let aside = quarantined()
        XCTAssertEqual(aside.count, 1, "the file that would not decode is kept beside it")
        XCTAssertEqual(try aside.first.map { try Data(contentsOf: $0) }, garbage, "byte for byte")
    }

    func testAViewFromAnEarlierVersionIsSetAsideAndRebuilt() throws {
        let before = recorded()
        var old = before
        old.version = Observations.currentVersion - 1
        try JSONEncoder().encode(old).write(to: file)

        let second = store()
        second.load()
        XCTAssertEqual(second.observations.version, Observations.currentVersion)
        XCTAssertEqual(second.observations, before)
        XCTAssertEqual(quarantined().count, 1)
    }

    func testWithAnEmptyRingTheQuarantinedFileIsTheHistory() throws {
        try Data("not json".utf8).write(to: file)
        let store = store()
        store.load()
        XCTAssertEqual(store.observations, Observations(), "starting fresh")
        XCTAssertEqual(quarantined().count, 1, "and the old file is kept, not overwritten")
        store.chainCompleted(["s"], gaps: [0.3], peeked: false, at: start)
        store.flush()
        XCTAssertEqual(quarantined().count, 1, "a save never touches the quarantined file")
    }

    func testAViewThatDecodesIsLoadedAsItIs() {
        let before = recorded()
        let second = store()
        second.load()
        XCTAssertEqual(second.observations, before)
        XCTAssertEqual(quarantined(), [])
    }
}
