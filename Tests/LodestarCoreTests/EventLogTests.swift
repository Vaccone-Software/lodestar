import XCTest
@testable import LodestarCore

/// The event log is the source of truth; these tests hold it to the two
/// promises that make that claim real — nothing appended is lost, and the
/// store's live view always equals a replay of the log.
final class EventLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func chainEvent(at date: Date) -> ObservationEvent {
        var event = ObservationEvent(t: date, kind: .chain)
        event.chain = ["g"]
        event.gaps = [0.25]
        event.peeked = false
        return event
    }

    /// A flush that cannot open the file must not replace the ring with
    /// the batch it was holding.
    ///
    /// The fallback branch was written for "the file does not exist yet"
    /// but fired on any open failure — a descriptor limit, a permission
    /// change — and atomically wrote the last few seconds of events over
    /// ninety days of them. The batch was also cleared before the write,
    /// so a failure silently dropped it as well.
    func testFlushDoesNotTruncateAnExistingRingItCannotOpen() throws {
        let log = makeLog()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<5 { log.append(chainEvent(at: old.addingTimeInterval(Double(offset)))) }
        log.flush()
        XCTAssertEqual(EventLog(file: log.file).readAll().count, 5)

        // Make the file unopenable for writing, then try to add to it.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: log.file.path) }
        log.append(chainEvent(at: old.addingTimeInterval(100)))
        log.flush()

        XCTAssertEqual(EventLog(file: log.file).readAll().count, 5,
                       "the existing ring must survive a failed write")

        // The batch was held, not dropped, so it lands once writing works.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: log.file.path)
        log.flush()
        XCTAssertEqual(EventLog(file: log.file).readAll().count, 6,
                       "the held batch should append once the file opens again")
    }

    func testAppendFlushAndReadRoundTrip() {
        let log = makeLog()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        log.append(chainEvent(at: date))
        var reach = ObservationEvent(t: date, kind: .reach)
        reach.app = "slack"
        reach.route = "searcher"
        reach.typed = 3
        reach.openToCommit = 1.5
        log.append(reach)
        log.flush()

        let back = EventLog(file: log.file).readAll()
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.first?.kind, .chain)
        XCTAssertEqual(back.first?.gaps ?? [], [0.25])
        XCTAssertEqual(back.last?.app, "slack")
        XCTAssertEqual(back.last?.openToCommit ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(back.first?.t.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testPendingEventsAreVisibleBeforeFlush() {
        let log = makeLog()
        log.append(chainEvent(at: Date()))
        XCTAssertEqual(log.readAll().count, 1, "a reader must never miss the last few seconds")
    }

    func testAppendsAccumulateAcrossFlushes() {
        let log = makeLog()
        log.append(chainEvent(at: Date()))
        log.flush()
        log.append(chainEvent(at: Date()))
        log.flush()
        XCTAssertEqual(log.readAll().count, 2, "flushing appends; it never rewrites")
    }

    func testCompactionDropsOnlyWhatAgedOut() {
        let log = makeLog()
        let now = Date()
        log.append(chainEvent(at: now.addingTimeInterval(-EventLog.retention - 86_400)))
        log.append(chainEvent(at: now.addingTimeInterval(-3600)))
        log.flush()
        log.compact(now: now)
        let kept = EventLog(file: log.file).readAll()
        XCTAssertEqual(kept.count, 1, "the ring is bounded by age")
        XCTAssertEqual(kept.first?.t.timeIntervalSince(now) ?? 0, -3600, accuracy: 5)
    }

    func testClearRemovesEverything() {
        let log = makeLog()
        log.append(chainEvent(at: Date()))
        log.flush()
        log.clear()
        XCTAssertEqual(log.readAll().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.file.path))
    }

    // MARK: - The store keeps its books

    func testStoreViewEqualsReplayOfItsOwnLog() {
        let store = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: makeLog())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.chainCompleted(["b", "g"], gaps: [0.3, 0.4], peeked: true, at: date)
        store.chainAbandoned(["b"], hover: 2.5, at: date)
        store.wrongKey(after: ["b"], pressed: "w", at: date)
        store.reached("slack", via: .searcher,
                      cost: Observations.LauncherCost(typed: 3, prefix: "sl", rank: 0,
                                                      listLength: 5, openToFirstKey: 0.4,
                                                      openToCommit: 1.6), at: date)
        store.webOpened(host: "github.com", profile: "brave:work", source: "typed", at: date)
        store.focused(app: "ghostty", at: date)
        store.focused(app: "brave", at: date)
        store.verbUsed("launcher", at: date)
        store.epochBumped(address: ["b", "g"], change: "retargeted", at: date)

        XCTAssertEqual(Observations.rebuild(from: store.log.readAll()), store.observations,
                       "the view and the log can never disagree")
    }

    func testStoreLoadRebuildsFromLogWhenViewIsMissingOrStale() {
        let file = directory.appendingPathComponent("observations.json")
        let log = makeLog()
        let store = ObservationStore(file: file, log: log)
        // Recent, because load() compacts the ring first and a stale
        // fixture would age out — which is itself correct behavior.
        let date = Date().addingTimeInterval(-3600)
        store.chainCompleted(["g"], gaps: [0.2], peeked: false, at: date)
        store.flush()
        // No view file at all — a fresh install onto an existing log, or a
        // schema bump: either way the log answers.
        try? FileManager.default.removeItem(at: file)
        let reloaded = ObservationStore(file: file, log: EventLog(file: log.file))
        reloaded.load()
        XCTAssertEqual(reloaded.observations.addresses["g"]?.completions, 1,
                       "the truth is the log; the view is a cache")
    }

    func testDisabledStoreRecordsNothing() {
        let store = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: makeLog())
        store.setEnabled(false)
        store.chainCompleted(["g"], gaps: [0.2], peeked: false)
        store.flush()
        XCTAssertEqual(store.log.readAll().count, 0, "off means off, not smaller")
        XCTAssertEqual(store.observations, Observations())
    }
}
