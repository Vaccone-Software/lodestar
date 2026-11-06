import Foundation
import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// `lodestar health`: the record read whole, each stretch labelled with how
/// it was measured, periods cut only where a number's meaning changed, and
/// what was not recorded null rather than zero.
final class HealthQueryTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("healthquery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SealedFailures.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 2026-09-14 (a Monday), noon UTC.
    private let monday = Date(timeIntervalSince1970: 1_789_387_200)

    private func at(_ days: Double, _ hours: Double = 0) -> Date {
        monday.addingTimeInterval(days * 86_400 + hours * 3600)
    }

    private func pulse(_ t: Date, hold: Double? = nil, stamped: Bool = false, bout: Int = 0) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .pulse)
        event.keys = 100
        event.backspaces = 10
        event.activeMinutes = 10
        event.boutIndex = bout
        event.boutSeconds = Double(bout) * 900
        if let hold {
            event.holdN = 100
            event.holdSum = hold * 100
            event.holdSumSq = hold * hold * 100
        }
        if stamped {
            event.jitterN = 100
            event.jitterSum = 0.3
        }
        return event
    }

    private func era(_ t: Date, _ version: String, exact: Bool? = nil,
                     intervals: [String: ReportInterval]? = nil) -> ObservationEvent {
        var event = ObservationEvent(t: t, kind: .era)
        event.era = EraInfo(appVersion: version, keySchema: 2, pointerSchema: 2, reportIntervals: intervals,
                            exactKeyboards: exact)
        return event
    }

    private func blind(_ from: Date, hours: Double, _ kind: BlindKind = .asleep) -> ObservationEvent {
        BlindSpan.event(kind, from: from, to: from.addingTimeInterval(hours * 3600))
    }

    // MARK: The timeline

    func testBeforeErasTheStageIsInferredFromWhatThePulsesCarry() {
        let events = [pulse(at(0)), pulse(at(1), hold: 0.09), pulse(at(2), hold: 0.09, stamped: true),
                      era(at(3), "0.35.0")]
        let timeline = HealthMeasurement.Timeline(events: events)
        XCTAssertEqual(timeline.at(at(0)).holdClock, .none)
        XCTAssertEqual(timeline.at(at(1)).holdClock, .callback)
        XCTAssertEqual(timeline.at(at(1)).basis, .inferred)
        XCTAssertNil(timeline.at(at(1)).build)
        XCTAssertEqual(timeline.at(at(2)).holdClock, .eventStamp)
        XCTAssertEqual(timeline.at(at(2)).keyboardList, .launchSnapshot)
        XCTAssertEqual(timeline.at(at(3)).basis, .era)
        XCTAssertEqual(timeline.at(at(3)).build, "0.35.0")
        XCTAssertFalse(timeline.at(at(3)).blindSpans)
    }

    func testAnEraNamesWhatItsBuildMeasured() {
        let old = HealthMeasurement(era: EraInfo(appVersion: "0.39.1", keySchema: 2, pointerSchema: 1))
        XCTAssertEqual(old.keyboardList, .launchSnapshot)
        XCTAssertEqual(old.pressKeyboard, .lid)
        let live = HealthMeasurement(era: EraInfo(appVersion: "0.39.2", keySchema: 2, pointerSchema: 1))
        XCTAssertEqual(live.keyboardList, .live)
        XCTAssertEqual(live.pressKeyboard, .keyboardType)
        XCTAssertFalse(live.blindSpans)
        // Numbers, not text: 0.100.0 is after 0.53.0.
        let later = HealthMeasurement(era: EraInfo(appVersion: "0.100.0", keySchema: 2, pointerSchema: 2,
                                                   exactKeyboards: true))
        XCTAssertTrue(later.blindSpans)
        XCTAssertTrue(later.voice)
        XCTAssertEqual(later.pressKeyboard, .exact)
    }

    func testAStatedIntervalOutranksAnUnknownFromAnotherEra() {
        let timeline = HealthMeasurement.Timeline(events: [
            era(at(0), "0.46.0", intervals: ["bt": .unknown, "built-in": .microseconds(8000)]),
            era(at(1), "0.46.1", intervals: ["bt": .microseconds(15000)]),
            era(at(2), "0.46.2", intervals: ["bt": .unknown]),
        ])
        XCTAssertEqual(timeline.intervals, ["bt": .microseconds(15000), "built-in": .microseconds(8000)])
    }

    // MARK: Periods

    func testAWeekIsCutWhereTheHoldClockChangedAndEachPartKeepsItsOwnHolds() throws {
        let events = [pulse(at(0), hold: 0.080), pulse(at(1), hold: 0.080),
                      pulse(at(2), hold: 0.100, stamped: true), pulse(at(3), hold: 0.100, stamped: true)]
        let timeline = HealthMeasurement.Timeline(events: events)
        let rows = HealthQuery.periods(.week, events: events, timeline: timeline, days: .init(), calendar: calendar)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.split), [true, true])
        XCTAssertEqual(rows.map(\.measurement.holdClock), [.callback, .eventStamp])
        XCTAssertEqual(try XCTUnwrap(rows[0].hold?.meanMs), 80, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rows[1].hold?.meanMs), 100, accuracy: 1e-9)
        XCTAssertEqual(rows[0].firstDay, "2026-09-14")
        XCTAssertEqual(rows[1].lastDay, "2026-09-20")
        XCTAssertEqual(rows[0].end, rows[1].start, "the parts meet at the change")
    }

    func testBuildsTakingTurnsDoNotCutAPeriodTheySayHowMuchWasRecorded() throws {
        // A release day: the new build, the old one again for a while, the new one.
        var events = [era(at(-1), "0.53.0"), era(at(0, 6), "0.52.0"), era(at(0, 12), "0.53.0")]
        events += (0..<7).map { pulse(at(Double($0), 1), hold: 0.09, stamped: true) }
        var voice = ObservationEvent(t: at(1), kind: .voice)
        voice.voice = VoiceStats(seconds: 5, speechSeconds: 4, voicedSeconds: 3, pauses: Moments(), f0: nil,
                                 f0SpreadSemitones: nil, intensity: nil, jitter: 0.01, shimmer: nil, cyclePairs: 0,
                                 hnr: nil, speechRate: 2, articulationRate: nil, words: 10)
        events.append(voice)
        let timeline = HealthMeasurement.Timeline(events: events)
        let rows = HealthQuery.periods(.week, events: events, timeline: timeline, days: .init(), calendar: calendar)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(row.split)
        XCTAssertEqual(row.builds, ["0.53.0", "0.52.0"])
        // Monday 04:00 to the next Monday 04:00: the old build ran six of its
        // 168 hours, from six in the evening to midnight.
        XCTAssertEqual(row.measurement.recorded.voice, (168.0 - 6) / 168, accuracy: 1e-9)
        XCTAssertEqual(row.voice?.drafts, 1)
    }

    func testBlindTimeIsNullWhereNothingRecordedItAndCutAtTheDayItBelongsTo() throws {
        let events = [pulse(at(0), hold: 0.09, stamped: true), era(at(1), "0.46.0"),
                      pulse(at(1, 1), hold: 0.09, stamped: true), blind(at(1, 10), hours: 10),
                      pulse(at(2, 1), hold: 0.09, stamped: true)]
        let timeline = HealthMeasurement.Timeline(events: events)
        let days = HealthQuery.periods(.day, events: events, timeline: timeline, days: .init(), calendar: calendar)
        XCTAssertEqual(days.map(\.firstDay), ["2026-09-14", "2026-09-15", "2026-09-16"])
        XCTAssertNil(days[0].blind, "before 0.46.0 an unseen hour looks like a quiet one")
        XCTAssertEqual(days[0].measurement.recorded.blindSpans, 0)
        // 22:00 to 08:00, the health day turning at 04:00: six hours, then four.
        XCTAssertEqual(days[1].blind, ["asleep": 6 * 3600])
        XCTAssertEqual(days[2].blind, ["asleep": 4 * 3600])

        let json = try String(decoding: JSONEncoder().encode(days[0]), as: UTF8.self)
        XCTAssertTrue(json.contains(#""blind":null"#), "an unmeasured section is written as null, not left out")
    }

    func testTheSinceAndUntilDaysBoundEveryGrain() {
        let events = (0..<5).map { pulse(at(Double($0)), hold: 0.09, stamped: true) }
        let timeline = HealthMeasurement.Timeline(events: events)
        let days = HealthQuery.Days(since: "2026-09-15", until: "2026-09-16")
        XCTAssertEqual(HealthQuery.periods(.day, events: events, timeline: timeline, days: days, calendar: calendar)
            .map(\.firstDay), ["2026-09-15", "2026-09-16"])
        let week = HealthQuery.periods(.week, events: events, timeline: timeline, days: days, calendar: calendar)
        XCTAssertEqual(week.map(\.firstDay), ["2026-09-15"])
        XCTAssertEqual(week.map(\.lastDay), ["2026-09-16"])
        XCTAssertEqual(week.first?.input?.keys, 200)
        XCTAssertEqual(HealthQuery.events(.pulse, events: events, timeline: timeline, days: days, calendar: calendar).count, 2)
        XCTAssertTrue(HealthQuery.Days.isDay("2026-09-15", calendar: calendar))
        for wrong in ["2026-13-01", "2026-02-30", "2026-9-15", "yesterday"] {
            XCTAssertFalse(HealthQuery.Days.isDay(wrong, calendar: calendar), wrong)
        }
    }

    // MARK: Bouts

    func testBoutsAreCountedTheWayTheDriftCountsThem() {
        let events = [pulse(at(0), bout: 3), pulse(at(0, 0.25), bout: 4),
                      pulse(at(0, 2), bout: 0), pulse(at(0, 2.25), bout: 1), pulse(at(0, 2.5), bout: 2)]
        let bouts = Vigilance.bouts(events: events)
        XCTAssertEqual(bouts.map(\.pulses), [2, 3])
        XCTAssertEqual(bouts.map(\.joined), [true, false], "the record began inside the first")
        XCTAssertEqual(bouts[1].minutes, 2 * 15 + 10)
        XCTAssertEqual(Vigilance.report(events: events, days: 10_000, now: at(1))?.bouts, 2)
    }

    // MARK: Reading the sealed record

    func testTheRecordIsReadAcrossItsMonthsAndAKeyThatWillNotOpenIsSaid() throws {
        let custody = InMemoryKeyCustody()
        let vault = SealedFixture.vault(directory, custody: custody)
        let log = SealedFixture.eventLog(directory.appendingPathComponent("health-events.jsonl"), ring: .health)
        log.behavioralBound = .max
        log.append(pulse(at(-40)))
        log.append(pulse(at(0)))
        log.flush()
        log.compact(now: at(1))
        log.close()

        let read = HealthRecord.read(in: directory, ring: vault.ring(.health))
        XCTAssertEqual(read.problems, [])
        XCTAssertEqual(read.events.map(\.t), [at(-40), at(0)])

        let locked = Vault(custody: LockedCustody(copying: custody), directory: directory)
        let refused = HealthRecord.read(in: directory, ring: locked.ring(.health))
        XCTAssertTrue(refused.events.isEmpty)
        XCTAssertFalse(refused.problems.isEmpty)
        XCTAssertTrue(refused.problems.allSatisfy { $0.contains("key is unavailable") }, "\(refused.problems)")
    }

    func testAPressRowNamesItsHandAndKeyboardAndNeverAKey() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let store = KeyStore(directory: directory.appendingPathComponent("keys"), installID: "i",
                             timeZone: calendar.timeZone, appVersion: "0.54.0", ring: vault.ring(.health))
        var press = KeyPress(down: at(0), hold: 0.085, hand: .left, kind: .letter, shift: false, chord: false,
                             gesture: false, lens: false, repeated: false, keyboardType: 40)
        press.keyboard = 2
        store.append(press, roster: ["built-in", "keychron"])
        store.flushSync()
        store.close()

        let day = DayFile.day(of: at(0), calendar: calendar)
        XCTAssertEqual(HealthRecord.pressDays(in: directory), [day])
        let read = HealthRecord.presses(day: day, in: directory, ring: vault.ring(.health))
        XCTAssertNil(read.problem)
        let timeline = HealthMeasurement.Timeline(events: [era(at(-1), "0.54.0", exact: true)])
        let rows = HealthQuery.presses(read.presses, day: day, timeline: timeline)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].keyboard, "keychron")
        XCTAssertEqual(rows[0].hand, "left")
        XCTAssertEqual(rows[0].kind, "letter")
        XCTAssertEqual(try XCTUnwrap(rows[0].holdMs), 85, accuracy: 0.01)
        XCTAssertEqual(rows[0].measurement.pressKeyboard, .exact)
        let json = try String(decoding: JSONEncoder().encode(rows[0]), as: UTF8.self)
        XCTAssertFalse(json.contains("keycode"))

        // A press no release was seen for, charged to no keyboard: both said.
        var stranded = press
        stranded.hold = nil
        stranded.keyboard = 0
        let unknown = HealthQuery.presses([(stranded, nil)], day: day, timeline: timeline)[0]
        let text = try String(decoding: JSONEncoder().encode(unknown), as: UTF8.self)
        XCTAssertTrue(text.contains(#""holdMs":null"#), text)
        XCTAssertTrue(text.contains(#""keyboard":null"#), text)
    }

    // MARK: What the reviews asked for

    func testClicksInTwoAppsAtTheSameInstantAreBothRead() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let log = SealedFixture.eventLog(directory.appendingPathComponent("health-events.jsonl"), ring: .health)
        for app in ["brave", "slack"] {
            var clicks = ObservationEvent(t: at(0), kind: .clicks)
            clicks.app = app
            clicks.clicks = 3
            log.append(clicks)
        }
        log.flush()
        log.close()
        let read = HealthRecord.read(in: directory, ring: vault.ring(.health))
        XCTAssertEqual(read.events.compactMap(\.app).sorted(), ["brave", "slack"])
    }

    func testNothingToReadGivesNoRowsRatherThanEmptyOnes() {
        let timeline = HealthMeasurement.Timeline(events: [])
        for grain in [HealthQuery.Grain.summary, .day, .week, .month] {
            XCTAssertTrue(HealthQuery.periods(grain, events: [], timeline: timeline, days: .init(), calendar: calendar).isEmpty)
        }
        let events = [pulse(at(0), hold: 0.09, stamped: true)]
        let later = HealthQuery.Days(since: "2027-01-01")
        XCTAssertTrue(HealthQuery.periods(.week, events: events, timeline: timeline, days: later, calendar: calendar).isEmpty)
        XCTAssertTrue(HealthQuery.bouts(events: events, timeline: timeline, days: later, calendar: calendar).isEmpty)
    }

    func testADayEndsAtFourOnTheWallClockAcrossTheChangeOfTime() throws {
        // New York leaves daylight time at 02:00 on 2026-11-01: the health day
        // of Oct 31 runs 25 hours, and 03:30 that night is still Oct 31.
        var york = Calendar(identifier: .gregorian)
        york.timeZone = TimeZone(identifier: "America/New_York")!
        let late = try XCTUnwrap(york.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 3, minute: 30)))
        let events = [pulse(late.addingTimeInterval(-3 * 3600), hold: 0.09, stamped: true),
                      pulse(late, hold: 0.09, stamped: true),
                      pulse(late.addingTimeInterval(3 * 3600), hold: 0.09, stamped: true)]
        let rows = HealthQuery.periods(.day, events: events, timeline: HealthMeasurement.Timeline(events: events),
                                       days: .init(), calendar: york)
        XCTAssertEqual(rows.map(\.firstDay), ["2026-10-31", "2026-11-01"])
        XCTAssertEqual(rows[0].input?.keys, 200)
        XCTAssertEqual(rows[0].end, rows[1].start)
        XCTAssertEqual(rows[1].start, DayFile.dayStart(of: "2026-11-01", calendar: york))
    }

    func testADayAsleepFromEndToEndIsARowOfBlindTime() {
        let events = [era(at(-1), "0.46.0"), pulse(at(0), hold: 0.09, stamped: true),
                      blind(at(0, 10), hours: 48), pulse(at(2, 12), hold: 0.09, stamped: true)]
        let timeline = HealthMeasurement.Timeline(events: events)
        let rows = HealthQuery.periods(.day, events: events, timeline: timeline, days: .init(), calendar: calendar)
        XCTAssertEqual(rows.map(\.firstDay), ["2026-09-14", "2026-09-15", "2026-09-16"])
        XCTAssertEqual(rows[1].blind, ["asleep": 24 * 3600])
        XCTAssertNil(rows[1].input)
    }

    func testABoutCutInTwoCountsOnlyEachRowsPart() {
        let events = [pulse(at(0), hold: 0.09, bout: 0), pulse(at(0, 0.25), hold: 0.09, bout: 1),
                      pulse(at(0, 0.5), hold: 0.09, stamped: true, bout: 2),
                      pulse(at(0, 0.75), hold: 0.09, stamped: true, bout: 3)]
        let rows = HealthQuery.bouts(events: events, timeline: HealthMeasurement.Timeline(events: events),
                                     days: .init(), calendar: calendar)
        XCTAssertEqual(rows.map(\.joined), [false, true])
        XCTAssertEqual(rows.map(\.minutes), [15 + 10, 15 + 10], "never the first part twice")
    }

    func testAWeekStillRunningEndsNow() throws {
        let events = [era(at(-1), "0.53.0"), pulse(at(0), hold: 0.09, stamped: true), era(at(1), "0.52.0")]
        let now = at(2)
        let row = try XCTUnwrap(HealthQuery.periods(.week, events: events, timeline: HealthMeasurement.Timeline(events: events),
                                                    days: .init(), calendar: calendar, now: now).first)
        XCTAssertEqual(row.end, now)
        // Monday 04:00 to Wednesday noon is 56 hours; 0.53.0 recorded voice for 32 of them.
        XCTAssertEqual(row.measurement.recorded.voice, 32.0 / 56, accuracy: 1e-9)
    }

    func testTheFourWeeksCountASpanThatBeganBeforeThemForThePartInside() {
        let rows = BlindSummary.rows(events: [blind(at(-1), hours: 48)], days: 1, now: at(1))
        XCTAssertEqual(rows.map(\.seconds), [24 * 3600])
    }
}
