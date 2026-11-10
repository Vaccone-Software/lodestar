import XCTest
@testable import LodestarCore

/// The whole reads (`readAll`, `recent`, `allEvents`) build one array and
/// filter or sort it where it stands. What they return is what the joins and
/// filters they replaced returned, order and ties included.
final class EventLogReadTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-readtests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let now = SyntheticLogbook.utc("2026-11-09T12:00:00Z")

    private func makeStore() -> ObservationStore {
        ObservationStore(file: directory.appendingPathComponent("observations.json"),
                         vault: SealedFixture.vault(directory))
    }

    /// Four months, rotated, with an unflushed event and an event exactly at
    /// the window's edge.
    private func rotatedStore(days: Int) -> (store: ObservationStore, cutoff: Date) {
        let store = makeStore()
        let events = SyntheticLogbook.events(from: SyntheticLogbook.utc("2026-07-20T00:00:00Z"),
                                             days: 112, perDay: 30, seed: 21)
        for event in events {
            (ObservationEvent.healthKinds.contains(event.kind) ? store.healthLog : store.log).append(event)
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        store.log.append(ObservationEvent(t: cutoff, kind: .verb))
        store.log.flush()
        store.healthLog.flush()
        store.log.compact(now: now)
        store.healthLog.compact(now: now)
        store.log.append(ObservationEvent(t: cutoff, kind: .verb))
        _ = store.log.readAll()
        return (store, cutoff)
    }

    func testRecentIsTheWholeReadKeptToTheWindow() {
        let (store, cutoff) = rotatedStore(days: 45)
        let whole = store.log.readAll()
        let expected = whole.filter { $0.t >= cutoff }
        let recent = store.log.recent(days: 45, now: now)
        XCTAssertEqual(recent, expected, "the same events in the same order, the edge and the pending one included")
        XCTAssertGreaterThan(expected.count, 100)
        XCTAssertLessThan(expected.count, whole.count, "and the window cut something")
        XCTAssertEqual(recent.filter { $0.t == cutoff }.count, 2, "an event at the edge is inside it")
    }

    func testAllEventsIsBothLogsOldestFirstALogbookEventFirstAtATie() {
        let store = makeStore()
        let instant = now.addingTimeInterval(-86_400)
        for (index, app) in ["Second", "First"].enumerated() {
            var event = ObservationEvent(t: instant, kind: .focus)
            event.app = app
            store.log.append(event)
            var pulse = ObservationEvent(t: instant, kind: .pulse)
            pulse.activeMinutes = index + 1
            store.healthLog.append(pulse)
        }
        var early = ObservationEvent(t: instant.addingTimeInterval(-5), kind: .pulse)
        early.activeMinutes = 9
        store.healthLog.append(early)
        store.log.flush()
        store.healthLog.flush()
        let expected = (store.log.readAll() + store.healthLog.readAll()).sorted { $0.t < $1.t }
        let all = store.allEvents()
        XCTAssertEqual(all, expected)
        XCTAssertEqual(all.map(\.kind), [.pulse, .focus, .focus, .pulse, .pulse],
                       "the early pulse, then the logbook's two in the order appended, then the health record's")
        XCTAssertEqual(all.dropFirst().prefix(2).map(\.app), ["Second", "First"])
    }

    func testReadAllIntoAppendsAfterWhatIsThere() {
        let store = makeStore()
        store.log.append(ObservationEvent(t: now, kind: .verb))
        store.log.flush()
        var events = [ObservationEvent(t: now.addingTimeInterval(-1), kind: .focus)]
        store.log.readAll(into: &events)
        XCTAssertEqual(events.map(\.kind), [.focus, .verb])
    }
}
