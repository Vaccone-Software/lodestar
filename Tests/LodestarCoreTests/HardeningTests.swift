import XCTest
@testable import LodestarCore

/// The 0.22.2 review, pinned: every test here stands on a repair — a trap
/// removed, a rate made honest, a cache made real — so the next
/// simplification cannot quietly reopen it.
final class HardeningTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Traps removed

    func testDuplicateCalendarSpellingsDoNotTrap() {
        // Config keys are typed by hand; "Work" and "work" fold to one key
        // and must read as a quirk, never crash the join.
        let resolved = Meetings.mappedProfile(
            calendar: "work", account: nil,
            mappings: ["Work": "brave:A", "work": "brave:B"])
        XCTAssertNotNil(resolved)
        XCTAssertTrue(["brave:A", "brave:B"].contains(resolved?.profile ?? ""))
    }

    func testDuplicateElementIdsDoNotTrap() {
        var core = SelectCore(elements: [
            SelectCore.Element(id: 0, text: "left pane"),
            SelectCore.Element(id: 0, text: "right pane"),
        ], alphabet: "asdf")
        _ = core.key("p", shift: false)
        XCTAssertEqual(core.query, "p", "a harvest quirk is survivable")
    }

    func testATableKeyCannotSwallowAnExistingLeaf() throws {
        // JSON keys are case-sensitive, so "E" and "e" both arrive; the
        // table branch used to overwrite the leaf silently.
        let root = try Json.parse(#"{"graph": {"E": "Excel", "e": {"o": "Outlook"}}}"#)
        var problems: [String] = []
        let node = GraphNode.build(from: root.value(at: ["graph"])!.table!,
                                   path: "", problems: &problems)
        guard case .leaf(let target) = node.resolve(["e"]) else {
            return XCTFail("the first binding holds")
        }
        XCTAssertEqual(target.label, "Excel")
        XCTAssertTrue(problems.contains { $0.contains("bound twice") },
                      "the collision is reported, not swallowed")
    }

    // MARK: - Honest weekly rates

    private func chainEvent(_ letters: [String], at date: Date) -> ObservationEvent {
        var event = ObservationEvent(t: date, kind: .chain)
        event.chain = letters
        event.gaps = [0.4]
        return event
    }

    func testObservedWeeksOutlivesThePrunedRing() {
        var o = Observations()
        for week in 0..<20 {
            o.apply(chainEvent(["w"], at: start.addingTimeInterval(Double(week) * 604_800)))
        }
        let now = start.addingTimeInterval(19 * 604_800)
        XCTAssertEqual(o.activeWeeks(address: ["w"]), Observations.weekCap,
                       "the gate saturates with the ring — that is its job")
        XCTAssertEqual(o.observedWeeks(address: ["w"], now: now), 20,
                       "the denominator does not: twenty weeks is twenty weeks")
    }

    func testLegacyRecordsFallBackToActiveWeeks() {
        var o = Observations()
        o.apply(chainEvent(["w"], at: start))
        var record = o.addresses["w"]!
        record.firstWeek = nil // a record from before the field existed
        o.addresses["w"] = record
        XCTAssertEqual(o.observedWeeks(address: ["w"], now: start), 1,
                       "no first week on file — the old reading, not a crash")
    }

    func testRouteChipCountsOnlyChosenOpens() {
        var o = Observations()
        func web(_ profile: String, times: Int) {
            for _ in 0..<times {
                var event = ObservationEvent(t: start, kind: .web)
                event.host = "github.com"
                event.profile = profile
                event.source = "clicked"
                o.apply(event)
            }
        }
        web("pass", times: 40)
        web("work", times: 9)
        web("personal", times: 1)
        let rec = Recommendation(kind: .route, target: "github.com",
                                 detail: "", secondsPerWeek: 12, probability: 0.9,
                                 evidence: [],
                                 edit: .addRoute(pattern: "github.com", profileKey: "work"))
        let chip = Coach.chip(for: rec, observations: o)
        XCTAssertTrue(chip.evidence.contains("9 of 10"),
                      "the chip prices the same population the advisor did — "
                          + "pass-throughs chose nothing")
    }

    func testRetireWaitsOnTheBindingsAgeNotTheStores() {
        var o = Observations()
        // A six-month-old store...
        o.apply(chainEvent(["a"], at: start.addingTimeInterval(-26 * 604_800)))
        let now = start
        var added = ObservationEvent(t: now.addingTimeInterval(-2 * 86_400), kind: .epoch)
        added.address = "q"
        added.change = "added"
        added.epoch = 1
        // ...whose "q" binding is two days old and never typed.
        let fresh = Advisor.Context(
            observations: o, events: [added],
            leaves: [Advisor.Leaf(chain: ["q"], label: "Linear", value: "Linear")],
            now: now)
        XCTAssertTrue(Advisor.retireCandidates(fresh).isEmpty,
                      "two days old is not four weeks unused")
        // The same binding with no add in the ring is older than the ring.
        let aged = Advisor.Context(
            observations: o, events: [],
            leaves: [Advisor.Leaf(chain: ["q"], label: "Linear", value: "Linear")],
            now: now)
        XCTAssertEqual(Advisor.retireCandidates(aged).count, 1)
    }

    func testSearcherDemandZeroFillsFromFirstSightingToNow() {
        // Anchored to a week boundary so the day offsets land in known
        // buckets: slack in weeks 0, 0, 2; figma in week 1; now in week 3.
        let epoch = Date(timeIntervalSince1970: 2810 * 604_800)
        var events: [ObservationEvent] = []
        for (offset, app) in [(0, "slack"), (5, "slack"), (9, "figma"), (16, "slack")] {
            var event = ObservationEvent(t: epoch.addingTimeInterval(Double(offset) * 86_400),
                                         kind: .reach)
            event.app = app
            event.route = "searcher"
            events.append(event)
        }
        let now = epoch.addingTimeInterval(22 * 86_400)
        XCTAssertEqual(Demand.weeklySearcherCounts(app: "slack", events: events, now: now),
                       [2, 0, 1, 0], "silence between sightings counts as silence")
        XCTAssertEqual(Demand.weeklySearcherCounts(app: "figma", events: events, now: now),
                       [1, 0, 0], "the series starts at the app's own first week")
    }

    // MARK: - The strip's order invariant

    func testMergingKeepsTheHistoryNewestFirst() {
        // `recents` no longer sorts — this invariant is what it stands on.
        func clip(_ id: String, at seconds: TimeInterval) -> Clipboard.Clip {
            Clipboard.Clip(id: id, kind: .text,
                           created: start.addingTimeInterval(seconds),
                           sourceBundleID: nil, sourceAppName: nil,
                           preview: id, bytes: 1, pinnedSlot: nil)
        }
        var clips: [Clipboard.Clip] = []
        clips = Clipboard.merging(clips, with: clip("a", at: 0))
        clips = Clipboard.merging(clips, with: clip("b", at: 10))
        clips = Clipboard.merging(clips, with: clip("c", at: 20))
        clips = Clipboard.merging(clips, with: clip("a", at: 30)) // re-copy promotes
        let recents = Clipboard.recents(clips)
        XCTAssertEqual(recents.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(recents.map(\.created), recents.map(\.created).sorted(by: >),
                       "newest-first holds by construction, so no sort is owed")
    }

    // MARK: - The event log's ordering contract

    func testSnapshotSeesEverythingAppendedBeforeIt() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardening-\(UUID().uuidString)")
        let log = EventLog(file: dir.appendingPathComponent("events.jsonl"))
        defer { log.clear() }
        log.append(ObservationEvent(t: start, kind: .verb))
        log.append(ObservationEvent(t: start, kind: .verb))
        XCTAssertEqual(log.snapshot().count, 2,
                       "the io queue is FIFO: appends land before the read")
        log.flushSoon()
        XCTAssertEqual(log.readAll().count, 2,
                       "a scheduled flush is ordered before the next read too")
        log.clear()
        XCTAssertEqual(log.snapshot().count, 0)
    }

    // MARK: - The settings window and the schema

    func testSettingsNumericBoundsAgreeWithTheSchema() {
        func schemaBounds(at path: [String]) -> (min: Double, max: Double)? {
            var node = Config.schema
            for key in path {
                guard case .table(let table, _) = node, let next = table[key] else { return nil }
                node = next
            }
            guard case .number(let min, let max, _) = node else { return nil }
            return (min, max)
        }
        let rows = SettingsModel.catalog(config: Config(), machine: .init())
            .flatMap(\.rows)
        for (path, unitScale) in [("scroll.speed", 1.0), ("clipboard.max-size-mb", 1.0)] {
            guard let row = rows.first(where: { $0.path == path }),
                  case .number(_, let min, let max, _) = row.control,
                  let schema = schemaBounds(at: path.split(separator: ".").map(String.init))
            else { return XCTFail("row or schema missing for \(path)") }
            XCTAssertEqual(Double(min) * unitScale, schema.min, "\(path) min drifted")
            XCTAssertEqual(Double(max) * unitScale, schema.max, "\(path) max drifted")
        }
    }
}
