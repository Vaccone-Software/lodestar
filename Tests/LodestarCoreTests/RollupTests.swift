import XCTest
@testable import LodestarCore

/// The monthly archive: what survives the ring. These tests pin the two
/// promises the retrospective will one day stand on — the aggregation is
/// faithful sufficient statistics, and a written month is never rewritten.
final class RollupTests: XCTestCase {
    // 2023-11-14 22:13:20 UTC.
    private let november = Date(timeIntervalSince1970: 1_700_000_000)
    private var december: Date { november.addingTimeInterval(30 * 86_400) }
    private var january: Date { november.addingTimeInterval(60 * 86_400) }

    private func event(_ kind: ObservationEvent.Kind, at t: Date,
                       _ shape: (inout ObservationEvent) -> Void = { _ in }) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: kind)
        shape(&event)
        return event
    }

    // MARK: - Bucketing

    func testBucketsByUTCMonthAndSkipsTheOpenMonth() {
        XCTAssertEqual(Rollup.monthKey(Date(timeIntervalSince1970: 1_706_745_599)), "2024-01",
                       "one second before the UTC month turns")
        XCTAssertEqual(Rollup.monthKey(Date(timeIntervalSince1970: 1_706_745_601)), "2024-02")

        let months = Rollup.build(events: [
            event(.focus, at: november) { $0.app = "slack" },
            event(.focus, at: december) { $0.app = "slack" },
            event(.focus, at: january) { $0.app = "slack" },
        ], now: january)
        XCTAssertEqual(Set(months.keys), ["2023-11", "2023-12"],
                       "the month now sits in is still being written")
    }

    func testDaysCountDistinctDays() {
        let months = Rollup.build(events: [
            event(.focus, at: november) { $0.app = "slack" },
            event(.focus, at: november.addingTimeInterval(3600)) { $0.app = "mail" },
            event(.focus, at: november.addingTimeInterval(3 * 86_400)) { $0.app = "slack" },
        ], now: january)
        XCTAssertEqual(months["2023-11"]?.days, 2)
        XCTAssertEqual(months["2023-11"]?.events, 3)
    }

    // MARK: - Faithful aggregation

    func testAggregatesSufficientStatisticsNotModels() {
        let months = Rollup.build(events: [
            event(.chain, at: november) { $0.chain = ["B", "p"]; $0.gaps = [0.5, 0.1]; $0.peeked = true },
            event(.chain, at: november) { $0.chain = ["b", "p"]; $0.gaps = [0.7, 0.2] },
            event(.abandon, at: november) { $0.chain = ["b"]; $0.hover = 2.5 },
            event(.wrongKey, at: november) { $0.chain = ["b"]; $0.pressed = "g" },
            event(.reach, at: november) { $0.app = "slack"; $0.route = "searcher"; $0.openToCommit = 2.0 },
            event(.reach, at: november) { $0.app = "slack"; $0.route = "graph" },
            event(.launcherAbandon, at: november),
            event(.verb, at: november) { $0.verb = "scroll" },
            event(.web, at: november) { $0.host = "github.com"; $0.profile = "brave:Work"; $0.source = "typed"; $0.row = "link" },
            event(.focus, at: november) { $0.app = "slack" },
            event(.epoch, at: november) { $0.address = "b p"; $0.change = "added" },
            event(.meeting, at: november) { $0.action = "joined"; $0.lead = -30 },
            event(.coach, at: november) { $0.action = "offered"; $0.rec = "bind"; $0.app = "slack"; $0.address = "s"; $0.seconds = 42 },
            event(.coach, at: november) { $0.action = "accepted"; $0.rec = "bind"; $0.app = "slack" },
            event(.select, at: november) { $0.action = "completed"; $0.source = "ocr"; $0.row = "held" },
        ], now: january)

        guard let month = months["2023-11"] else { return XCTFail("month missing") }
        let address = month.addresses["b p"]
        XCTAssertEqual(address?.completions, 2, "chain keys fold case like the view's")
        XCTAssertEqual(address?.peeked, 1)
        XCTAssertEqual(address?.trigger.n, 2)
        XCTAssertEqual(address?.trigger.sum ?? 0, log(0.5) + log(0.7), accuracy: 1e-9)
        XCTAssertEqual(address?.inner.n, 2)
        XCTAssertEqual(month.addresses["b"]?.abandons, 1)
        XCTAssertEqual(month.addresses["b"]?.hoverSum, 2.5)
        XCTAssertEqual(month.addresses["b"]?.confusion["g"], 1)

        XCTAssertEqual(month.apps["slack"]?.reaches["searcher"], 1)
        XCTAssertEqual(month.apps["slack"]?.reaches["graph"], 1)
        XCTAssertEqual(month.apps["slack"]?.focuses, 1)
        XCTAssertEqual(month.apps["slack"]?.launcherCommit.n, 1)
        XCTAssertEqual(month.apps["slack"]?.launcherCommit.sum ?? 0, log(2.0), accuracy: 1e-9)

        XCTAssertEqual(month.launcherAbandons, 1)
        XCTAssertEqual(month.verbs["scroll"], 1)
        XCTAssertEqual(month.web.opens, 1)
        XCTAssertEqual(month.web.hostProfiles["github.com"]?["brave:Work"], 1)
        XCTAssertEqual(month.epochs["added"], 1)
        XCTAssertEqual(month.meetings.actions["joined"], 1)
        XCTAssertEqual(month.meetings.joinedLead.sum, -30)

        let coach = month.coach["bind:slack"]
        XCTAssertEqual(coach?.offered, 1)
        XCTAssertEqual(coach?.accepted, 1)
        XCTAssertEqual(coach?.seconds, 42)
        XCTAssertEqual(coach?.address, "s")

        XCTAssertEqual(month.selectActions["completed"], 1)
        XCTAssertEqual(month.selectSources["ocr"], 1)
        XCTAssertEqual(month.selectRows["held"], 1)
    }

    // MARK: - The archive's one law

    func testAdoptIsAddOnly() {
        var archive = Rollup()
        var full = Rollup.Month(firstEvent: november, lastEvent: november)
        full.events = 100
        XCTAssertEqual(archive.adopt(["2023-11": full]), ["2023-11"])

        var shrunken = full
        shrunken.events = 3
        XCTAssertEqual(archive.adopt(["2023-11": shrunken, "2023-12": full]), ["2023-12"])
        XCTAssertEqual(archive.months["2023-11"]?.events, 100,
                       "a recomputation against a shrunken ring never overwrites"
                       + " the fuller answer written earlier")
    }

    func testRollWritesOnceAndHoldsWhatItWrote() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollup-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let fullRing = (0..<10).map { i in
            event(.focus, at: november.addingTimeInterval(Double(i) * 86_400)) { $0.app = "slack" }
        }
        let first = Rollup.roll(events: fullRing, file: file, now: january)
        XCTAssertEqual(first.added, ["2023-11"])

        // The ring moved on: November thinned to one event, December new.
        let thinned = [fullRing.last!, event(.focus, at: december) { $0.app = "mail" }]
        let second = Rollup.roll(events: thinned, file: file, now: january)
        XCTAssertEqual(second.added, ["2023-12"])

        let third = Rollup.roll(events: thinned, file: file, now: january)
        XCTAssertTrue(third.added.isEmpty, "idempotent once every month is archived")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try? decoder.decode(Rollup.self, from: Data(contentsOf: file))
        XCTAssertEqual(archive?.months["2023-11"]?.events, 10,
                       "November stands as first written, not as the ring last saw it")
        XCTAssertEqual(archive?.months["2023-12"]?.events, 1)
    }

    func testANewerSchemaIsLeftExactlyAlone() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollup-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let foreign = Data(#"{"version": 99, "future": true}"#.utf8)
        try? foreign.write(to: file)

        let outcome = Rollup.roll(events: [event(.focus, at: november) { $0.app = "slack" }],
                                  file: file, now: january)
        XCTAssertTrue(outcome.held, "an old binary must never rewrite a newer archive")
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertEqual(try? Data(contentsOf: file), foreign, "byte-identical")
    }
}
