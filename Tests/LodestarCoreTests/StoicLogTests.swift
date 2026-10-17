import Stoic
import XCTest
@testable import LodestarCore

/// Stoic's warnings and errors in Lodestar's own log.
final class StoicLogTests: XCTestCase {
    private var lines: [String] = []

    override func setUp() {
        lines = []
        Log.listener = { [weak self] in self?.lines.append($0) }
    }

    override func tearDown() {
        Log.listener = nil
    }

    func testAnEventIsNamedForStoicAndCarriesItsLabelAndPublicFieldsInOrder() {
        let event = Event("retry.exhausted", level: .warning, label: "editor.model", fields: [
            .init("attempts", .int(3)),
            .init("waited", .duration(.seconds(2))),
            .init("flag", .bool(true)),
        ])
        let line = StoicLog.format(event)
        XCTAssertEqual(line.event, "stoic.retry.exhausted")
        XCTAssertEqual(line.fields.map(\.key), ["label", "attempts", "waited", "flag"])
        XCTAssertEqual(line.fields.map { "\($0.value)" }, ["editor.model", "3", "2.0 seconds", "true"])
    }

    /// The log's tail goes into public bug reports: what Stoic marks
    /// private (a string, an error's description) is not written, whatever
    /// the field's value, and a field marked public is.
    func testPrivateFieldsAreRedactedAsStoicRedactsThem() {
        let event = Event("store.recovered_previous", level: .warning, fields: [
            .init("path", .string("/Users/someone/secret plans.json")),
            .init("error", .error(type: "StoreError", description: "corrupt at /Users/someone")),
            .init("reason", .string("checksum"), privacy: .public),
            .init("count", .int(2)),
            .init("note", .int(7), privacy: .private),
        ])
        let line = StoicLog.format(event)
        XCTAssertEqual(line.fields.map { "\($0.key)=\($0.value)" },
                       ["path=<private>", "error=<private>", "reason=checksum", "count=2", "note=<private>"])
        lines = []
        StoicLog().record(event)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("someone"), lines[0])
        XCTAssertFalse(lines[0].contains("secret"), lines[0])
        XCTAssertTrue(lines[0].contains(" WARN stoic.store.recovered_previous path=<private> error=<private> reason=checksum count=2 note=<private>\n"), lines[0])
    }

    func testAWarningIsAWarningLineAndAnErrorIsAnErrorLine() throws {
        let sink = StoicLog()
        sink.record(Event("abandonment.limit", level: .warning, label: "speech", fields: [.init("limit", .int(3))]))
        sink.record(Event("launch.record_failed", level: .error))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(" WARN stoic.abandonment.limit label=speech limit=3\n"), lines[0])
        XCTAssertTrue(lines[1].contains(" ERR  stoic.launch.record_failed\n"), lines[1])
    }

    func testNothingBelowAWarningIsWritten() {
        let sink = StoicLog()
        for level in [Event.Level.debug, .info, .notice] {
            XCTAssertFalse(sink.isEnabled(level), "\(level)")
            sink.record(Event("span.started", level: level))
        }
        XCTAssertTrue(sink.isEnabled(.warning))
        XCTAssertTrue(sink.isEnabled(.error))
        XCTAssertTrue(lines.isEmpty)
    }

    /// The whole way: a Stoic primitive records an event in an ambient that
    /// has the sink, and the line is in the log. A launch guard that cannot
    /// write its file is the one the app was blind to.
    func testALaunchThatCouldNotBeRecordedReachesTheLog() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("stoic-log-\(UUID().uuidString)", isDirectory: true)
        await withAmbient({ $0.instrumentation = CompositeInstrumentation([$0.instrumentation, StoicLog()]) }) {
            _ = RunMarker.launchGuard(in: missing, build: "x", bootSession: nil).beginLaunch()
        }
        XCTAssertEqual(lines.filter { $0.contains(" ERR  stoic.launch.record_failed error=<private>\n") }.count, 1, "\(lines)")
    }
}
