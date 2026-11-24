import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The prewarmer reads the ring for what it needs, a time and an app, and
/// never holds an event: these tests pin that the answers are the ones the
/// whole read gave.
final class FocusStreamTests: XCTestCase {
    static let now = SyntheticLogbook.utc("2026-11-09T12:00:00Z")
    private static var directory: URL!
    private static var log: EventLog!

    /// About a hundred and forty days over six months: sparse for the first
    /// stretch, then dense enough that more than the scoring window's worth
    /// of switches sit inside ninety days, so the window's edge is crossed.
    override class func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-focus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        let early = SyntheticLogbook.events(from: SyntheticLogbook.utc("2026-06-20T00:00:00Z"),
                                            days: 42, perDay: 40, seed: 3)
        let late = SyntheticLogbook.events(from: SyntheticLogbook.utc("2026-08-01T00:00:00Z"),
                                           days: 100, perDay: 520, seed: 11)
        for (index, event) in (early + late).enumerated() {
            log.append(event)
            if index % 5000 == 4999 { log.flush() }
        }
        log.flush()
        log.compact(now: now)
    }

    override class func tearDown() {
        log.close()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// What the whole read gives: every event of the window decoded, the
    /// focus ones kept. The old path, as the warmer ran it.
    private var wholeRead: [ObservationEvent] { Self.log.snapshot(days: 90, now: Self.now) }

    private var stream: [FocusStamp] { Self.log.focusStream(days: 90, now: Self.now) }

    func testTheStreamIsTheWholeReadsFocusesInTheSameOrder() {
        let whole = wholeRead
        let expected = whole.filter { $0.kind == .focus }
            .enumerated().sorted { $0.element.t < $1.element.t || ($0.element.t == $1.element.t && $0.offset < $1.offset) }
            .map { FocusStamp(t: $0.element.t, app: $0.element.app) }
        XCTAssertEqual(stream, expected)
        XCTAssertGreaterThan(expected.count, NextApp.scoringWindow,
                             "more switches than the scoring window, so its edge is crossed")
        XCTAssertTrue(expected.contains { $0.app == nil }, "a focus with no app keeps its place in the window")
        XCTAssertTrue(expected.contains { $0.app == "" })
    }

    /// Captured from the code before the warmer read a stream, on this
    /// synthetic ring: the answers it gave from the whole read.
    func testTunedAndEvaluatedAreWhatTheWholeReadGave() {
        let focuses = stream
        let tuning = NextApp.tune(focuses: focuses)
        XCTAssertEqual(tuning, NextApp.Tuning(weight: 0.7, decay: 0.5, secondOrder: false))
        let scores = NextApp.evaluate(focuses: focuses, tuning: tuning)
        let expected: [(NextApp.Strategy, [Double])] = [
            (.markov, [0.53036760788492276, 0.72914224826851359, 0.78002131060202451]),
            (.previous, [0.36430474160895043, 0.36430474160895043, 0.36430474160895043]),
            (.mru, [0.36430474160895043, 0.4180074587107086, 0.58886521044219498]),
            (.blend, [0.37224294086307941, 0.7433670751198721, 0.81342567927543952]),
            (.markov2, [0.36638252530633991, 0.69936068193926482, 0.81955247735748538]),
            (.tuned, [0.49014384656366544, 0.78801278636121475, 0.83734683004794885]),
        ]
        XCTAssertEqual(scores.map(\.strategy), expected.map(\.0))
        XCTAssertEqual(scores.map(\.hits), expected.map(\.1))
        XCTAssertTrue(scores.allSatisfy { $0.switches == 18_770 })
        XCTAssertEqual(NextApp.best(scores), .tuned)
    }

    /// The events path (a report holding a whole ring) and the stream path
    /// are one computation.
    func testTheEventsEntryPointsAnswerAsTheStreamDoes() {
        let events = wholeRead
        let tuning = NextApp.tune(events: events)
        XCTAssertEqual(tuning, NextApp.tune(focuses: stream))
        XCTAssertEqual(NextApp.evaluate(events: events, tuning: tuning),
                       NextApp.evaluate(focuses: stream, tuning: tuning))
    }

    func testTheSeededModelIsTheOneEveryFocusTeaches() {
        // The warmer's old loop: filter focus, sort by time, observe each app.
        var oracle = NextApp(tuning: NextApp.Tuning(weight: 0.7, decay: 0.5, secondOrder: true))
        let whole = wholeRead
        for event in whole.filter({ $0.kind == .focus }).sorted(by: { $0.t < $1.t }) {
            if let app = event.app { oracle.observe(app) }
        }
        let seeded = NextApp.seed(from: Self.log, retune: false,
                                  current: NextApp.Tuning(weight: 0.7, decay: 0.5, secondOrder: true),
                                  now: Self.now)
        XCTAssertEqual(seeded.model, oracle)
        XCTAssertTrue(seeded.scores.isEmpty, "no re-tune, no scoring")
        for strategy in NextApp.Strategy.allCases {
            XCTAssertEqual(seeded.model.predict(strategy), oracle.predict(strategy), "\(strategy)")
        }
        let retuned = NextApp.seed(from: Self.log, retune: true, current: NextApp.Tuning(), now: Self.now)
        XCTAssertEqual(retuned.tuning, NextApp.tune(events: whole))
        XCTAssertEqual(retuned.scores, NextApp.evaluate(events: whole, tuning: retuned.tuning))
    }

    /// The window's edge is the old one: a month is opened if any of it can
    /// be inside, and a line is kept if it is at the cutoff or after.
    func testTheWindowEdgeAndAnUnflushedFocusAreTheOldOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-focus-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        let now = SyntheticLogbook.utc("2026-11-09T12:00:00Z")
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        func focus(_ app: String, _ t: Date) -> ObservationEvent {
            var event = ObservationEvent(t: t, kind: .focus)
            event.app = app
            return event
        }
        log.append(focus("before", cutoff.addingTimeInterval(-1)))
        log.append(focus("at", cutoff))
        log.append(focus("after", cutoff.addingTimeInterval(1)))
        log.append(ObservationEvent(t: cutoff.addingTimeInterval(2), kind: .verb))
        log.flush()
        log.compact(now: now)
        log.append(focus("unflushed", now))
        XCTAssertEqual(log.focusStream(days: 90, now: now).map(\.app), ["at", "after", "unflushed"])
        XCTAssertEqual(log.snapshot(days: 90, now: now).filter { $0.kind == .focus }.map(\.app),
                       ["at", "after", "unflushed"], "and that is what the whole read keeps")
        log.close()
    }

    /// Two switches stamped at one instant are learned in the order the ring
    /// holds them, as the old sort kept them: the model's history, and so its
    /// next prediction, depends on it.
    func testFocusesAtOneInstantKeepTheOrderTheRingHoldsThem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-focus-ties-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        let now = SyntheticLogbook.utc("2026-11-09T12:00:00Z")
        let instant = now.addingTimeInterval(-3600)
        for app in ["Third", "First", "Second"] {
            var event = ObservationEvent(t: instant, kind: .focus)
            event.app = app
            log.append(event)
        }
        var early = ObservationEvent(t: instant.addingTimeInterval(-60), kind: .focus)
        early.app = "Early"
        log.append(early)
        log.flush()
        let whole = log.snapshot(days: 90, now: now).filter { $0.kind == .focus }.sorted { $0.t < $1.t }
        XCTAssertEqual(whole.map(\.app), ["Early", "Third", "First", "Second"], "the old sort's order")
        XCTAssertEqual(log.focusStream(days: 90, now: now).map(\.app), whole.map(\.app))
        XCTAssertEqual(NextApp.seed(from: log, retune: false, current: NextApp.Tuning(), now: now).model.history,
                       ["early", "third", "first", "second"])
        log.close()
    }

    func testAStreamOfNothingTeachesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-focus-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        XCTAssertEqual(log.focusStream(days: 90), [])
        let seed = NextApp.seed(from: log, retune: true, current: NextApp.Tuning())
        XCTAssertEqual(seed.tuning, NextApp.Tuning())
        XCTAssertEqual(seed.scores, [])
        XCTAssertEqual(seed.model, NextApp())
    }
}
