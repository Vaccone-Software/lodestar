import XCTest
@testable import LodestarCore

/// The strip records itself the way every surface does — how the card
/// was addressed, what the search cost, how it ended — and never a clip.
final class StripObservationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func paste(action: String = "pasted", seconds: Double = 2,
                       at time: Date? = nil) -> ObservationEvent {
        var event = ObservationEvent(t: time ?? start, kind: .paste)
        event.action = action
        event.source = "label"
        event.row = "plain"
        event.rank = 0
        event.typed = 0
        event.seconds = seconds
        return event
    }

    func testTheStoreRecordsAPasteWithoutTheClip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventLog(file: directory.appendingPathComponent("events.jsonl"))
        let store = ObservationStore(file: directory.appendingPathComponent("observations.json"),
                                     log: log)
        store.pasted(app: "Slack", action: "pasted", source: "search", row: "native",
                     rank: 2, typed: 5, seconds: 3.5, firstKey: 0.8, at: start)
        let event = try XCTUnwrap(log.readAll().first)
        XCTAssertEqual(event.kind, .paste)
        XCTAssertEqual(event.app, "slack")
        XCTAssertEqual(event.action, "pasted")
        XCTAssertEqual(event.source, "search")
        XCTAssertEqual(event.row, "native")
        XCTAssertEqual(event.rank, 2)
        XCTAssertEqual(event.typed, 5)
        XCTAssertEqual(event.seconds, 3.5)
        XCTAssertEqual(event.openToFirstKey, 0.8)
        store.flush()
        let line = try String(contentsOf: log.file, encoding: .utf8)
        XCTAssertFalse(line.contains("preview"), "never the clip")
        XCTAssertTrue(line.contains("\"paste\""))
    }

    func testTheOverheadPricesPastesAgainstTwoKeystrokes() throws {
        var events: [ObservationEvent] = []
        for i in 0..<10 {
            events.append(paste(seconds: 2, at: start.addingTimeInterval(Double(i) * 60)))
        }
        events.append(paste(action: "abandoned", seconds: 30))
        events.append(paste(seconds: 500))
        var pulse = ObservationEvent(t: start, kind: .pulse)
        pulse.keys = 500
        pulse.backspaces = 0
        pulse.clicks = 0
        pulse.scrolls = 0
        pulse.activeMinutes = 15
        pulse.ikN = 500
        pulse.ikSum = 100
        pulse.ikSumSq = 20
        events.append(pulse)
        let now = start.addingTimeInterval(3600)
        let health = Health.summary(events: events, days: 28, now: now)
        let overhead = Overhead.compute(events: events, latency: nil, health: health,
                                        clicks: nil, now: now)
        let channel = try XCTUnwrap(overhead.channels.first { $0.name == "clipboard" })
        XCTAssertEqual(channel.actsPerDay, 10, "abandons and hunts past the ceiling are not pastes")
        XCTAssertEqual(channel.actualSecondsPerDay, 20)
        XCTAssertEqual(channel.floorSecondsPerDay, 10 * 2 * 0.2, accuracy: 0.001)
        XCTAssertEqual(channel.ratio ?? 0, 5, accuracy: 0.01)
        XCTAssertTrue(channel.measured)
    }

    func testNoPastesNoChannel() {
        let overhead = Overhead.compute(events: [], latency: nil, health: nil, clicks: nil,
                                        now: start)
        XCTAssertNil(overhead.channels.first { $0.name == "clipboard" })
    }
}
