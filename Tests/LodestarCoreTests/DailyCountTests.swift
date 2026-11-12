import Foundation
import Stoic
import StoicHTTP
import XCTest
@testable import LodestarCore

/// The daily count: what is sent (two words and nothing that could tell one
/// Mac from another), when (once a UTC day, after the notice, with the
/// switch on), who may send at all, and what each answer means.
final class DailyCountTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// 2026-11-12T15:00:00Z.
    private let noon = Date(timeIntervalSince1970: 1_794_495_600)
    private var seen: DailyCount.Record { DailyCount.Record(installedAt: noon, noticeSeenAt: noon) }

    // MARK: - What is sent

    func testTheAgeBucketsMeetAtTheRetentionDays() {
        let cases: [(Int, DailyCount.Age)] = [
            (-3, .firstDay), (0, .firstDay), (1, .firstWeek), (6, .firstWeek), (7, .firstMonth), (29, .firstMonth),
            (30, .firstQuarter), (89, .firstQuarter), (90, .later), (4000, .later),
        ]
        for (days, age) in cases { XCTAssertEqual(DailyCount.Age(days: days), age, "\(days) days") }
        XCTAssertEqual(DailyCount.Age.allCases.map(\.rawValue), ["0", "1-6", "7-29", "30-89", "90+"],
                       "the site accepts exactly these words")
    }

    func testAgeIsWholeDaysSinceTheFirstRun() {
        XCTAssertEqual(DailyCount.Age(installedAt: noon, now: noon.addingTimeInterval(day - 1)), .firstDay)
        XCTAssertEqual(DailyCount.Age(installedAt: noon, now: noon.addingTimeInterval(day)), .firstWeek)
        XCTAssertEqual(DailyCount.Age(installedAt: noon, now: noon.addingTimeInterval(7 * day)), .firstMonth)
        XCTAssertEqual(DailyCount.Age(installedAt: noon.addingTimeInterval(day), now: noon), .firstDay,
                       "a clock set back is the first day, never a negative bucket")
    }

    func testThePayloadIsTheChannelTheAgeAndTheVersionAndNothingElse() throws {
        let body = DailyCount.Payload(channel: .preview, age: .firstMonth, version: "0.54.25").body
        XCTAssertEqual(String(data: body, encoding: .utf8),
                       #"{"age":"7-29","channel":"preview","version":"0.54.25"}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["channel", "age", "version"], "no macOS, no date, no id")
    }

    func testTheVersionIsThePlainDottedNumber() {
        let version = DailyCount.Payload(channel: .stable, age: .later).version
        XCTAssertEqual(version, Lodestar.version)
        XCTAssertNotNil(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression),
                        "no v and no build suffix: \(version)")
    }

    func testTheRequestGoesToTheSitesCountDoor() async throws {
        let transport = ScriptedTransport()
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(204)])
        let payload = DailyCount.Payload(channel: .stable, age: .later)
        let response = try await DailyCount.client(transport: transport).send(payload.httpRequest)
        XCTAssertEqual(DailyCount.classify(response), .counted)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://lodestar.vaccone.software/api/count")
        XCTAssertEqual(sent.method, .post)
        XCTAssertEqual(sent.headers["x-lodestar-count"], "1")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.body, [UInt8](payload.body))
        XCTAssertNil(sent.headers["Idempotency-Key"], "nothing that could follow a Mac from one day to the next")
        XCTAssertNil(sent.headers["Cookie"])
    }

    func testATryIsOneAttemptTheControllerRetries() {
        let policy = DailyCount.client().policy
        XCTAssertEqual(policy.attemptTimeout, .seconds(20))
        XCTAssertEqual(policy.schedule.maximumAttempts, 1)
    }

    // MARK: - The answers

    private func status(_ code: Int) -> HTTPError {
        .status(code, excerpt: "", retryAfter: nil, keyed: false, attempts: 1)
    }

    func testOnlyA204IsCounted() {
        XCTAssertEqual(DailyCount.classify(HTTPResponse(status: 204, body: [])), .counted)
        // A wifi sign-in page answers 200 to everything.
        for code in [200, 201, 202] {
            XCTAssertEqual(DailyCount.classify(HTTPResponse(status: code, body: Array("<html>".utf8))), .later, "\(code)")
        }
    }

    func testA400IsRefusedAndEverythingElseIsLater() {
        XCTAssertEqual(DailyCount.classify(status(400)), .refused)
        for code in [403, 404, 429, 500, 502, 503, 504] {
            XCTAssertEqual(DailyCount.classify(status(code)), .later, "\(code)")
        }
        XCTAssertEqual(DailyCount.classify(HTTPError.timedOut(attempt: 1)), .later)
        XCTAssertEqual(DailyCount.classify(URLError(.notConnectedToInternet)), .later)
    }

    func testRetriesAreThreeAndBounded() {
        let random = RandomSource.seeded(7)
        for (failures, whole) in [(1, 60.0), (2, 300.0), (3, 1800.0)] {
            let delay = try? XCTUnwrap(DailyCount.retryDelay(afterFailures: failures, random: random))
            XCTAssertNotNil(delay)
            XCTAssertGreaterThanOrEqual(delay ?? 0, whole / 2)
            XCTAssertLessThanOrEqual(delay ?? .infinity, whole)
        }
        XCTAssertNil(DailyCount.retryDelay(afterFailures: 4, random: random), "then the day goes uncounted")
        XCTAssertNil(DailyCount.retryDelay(afterFailures: 0, random: random))
    }

    // MARK: - Who may count

    func testOnlyTheInstalledReleaseCounts() {
        XCTAssertTrue(DailyCount.eligible(debug: false, testRun: false, development: false, installed: true))
        XCTAssertFalse(DailyCount.eligible(debug: true, testRun: false, development: false, installed: true))
        XCTAssertFalse(DailyCount.eligible(debug: false, testRun: true, development: false, installed: true))
        XCTAssertFalse(DailyCount.eligible(debug: false, testRun: false, development: true, installed: true))
        XCTAssertFalse(DailyCount.eligible(debug: false, testRun: false, development: false, installed: false))
    }

    func testThisTestRunNeverCounts() {
        XCTAssertFalse(DailyCount.thisProcessIsEligible())
    }

    // MARK: - When

    func testTheDayIsTheUTCDay() {
        XCTAssertEqual(DailyCount.day(of: noon), "2026-11-12")
        XCTAssertEqual(DailyCount.day(of: Date(timeIntervalSince1970: 1_794_441_599)), "2026-11-11", "23:59:59Z")
        XCTAssertEqual(DailyCount.day(of: Date(timeIntervalSince1970: 1_794_441_600)), "2026-11-12", "00:00:00Z")
    }

    func testNothingIsSentBeforeTheNotice() {
        let fresh = DailyCount.Record(installedAt: noon)
        XCTAssertEqual(DailyCount.use(fresh, now: noon, enabled: true, delay: 0), .showNotice)
        XCTAssertEqual(DailyCount.use(fresh, now: noon, enabled: false, delay: 0), .nothing,
                       "with the switch off, not even the notice")
    }

    func testTheFirstUseOfADayWaitsItsRandomDelay() {
        XCTAssertEqual(DailyCount.use(seen, now: noon, enabled: true, delay: 600),
                       .schedule(DailyCount.Pending(day: "2026-11-12", due: noon.addingTimeInterval(600))))
        XCTAssertEqual(DailyCount.use(seen, now: noon, enabled: true, delay: 99_999),
                       .schedule(DailyCount.Pending(day: "2026-11-12", due: noon.addingTimeInterval(7200))),
                       "never more than two hours")
        XCTAssertEqual(DailyCount.use(seen, now: noon, enabled: true, delay: -5),
                       .schedule(DailyCount.Pending(day: "2026-11-12", due: noon)))
    }

    func testOncePerDay() {
        var record = seen
        record.lastSentDay = "2026-11-12"
        XCTAssertEqual(DailyCount.use(record, now: noon, enabled: true, delay: 0), .nothing, "sent today")
        record.lastSentDay = "2026-11-11"
        record.pending = DailyCount.Pending(day: "2026-11-12", due: noon)
        XCTAssertEqual(DailyCount.use(record, now: noon, enabled: true, delay: 0), .nothing, "waiting today")
        record.pending = nil
        if case .schedule = DailyCount.use(record, now: noon, enabled: true, delay: 0) {} else {
            XCTFail("yesterday's count does not stand for today")
        }
    }

    func testAPendingDayIsThatDaysAlone() {
        let pending = DailyCount.Pending(day: "2026-11-12", due: noon.addingTimeInterval(3600))
        XCTAssertFalse(DailyCount.isDue(pending, now: noon))
        XCTAssertTrue(DailyCount.isDue(pending, now: noon.addingTimeInterval(3600)))
        let tomorrow = noon.addingTimeInterval(day)
        XCTAssertNil(DailyCount.live(pending, now: tomorrow), "a day that passed waiting goes uncounted")
        XCTAssertFalse(DailyCount.isDue(pending, now: tomorrow))
    }

    func testTheFirstRunIsTheOldestEvidence() {
        let folder = noon.addingTimeInterval(-40 * day)
        let logbook = noon.addingTimeInterval(-10 * day)
        XCTAssertEqual(DailyCount.installedAt(evidence: [logbook, folder, nil], now: noon), folder)
        XCTAssertEqual(DailyCount.installedAt(evidence: [nil, .distantPast], now: noon), noon,
                       "a logbook never written says nothing")
        XCTAssertEqual(DailyCount.installedAt(evidence: [noon.addingTimeInterval(day)], now: noon), noon,
                       "the future says nothing")
        XCTAssertEqual(DailyCount.installedAt(evidence: [], now: noon), noon)
    }

    // MARK: - The record

    func testRecordsMergeToTheEarliestFirstRunAndTheLatestDay() {
        let older = DailyCount.Record(installedAt: noon.addingTimeInterval(-9 * day), noticeSeenAt: noon,
                                      lastSentDay: "2026-11-10")
        let newer = DailyCount.Record(installedAt: noon, noticeSeenAt: nil, lastSentDay: "2026-11-12",
                                      pending: DailyCount.Pending(day: "2026-11-12", due: noon))
        let merged = older.merging(newer: newer)
        XCTAssertEqual(merged.installedAt, noon.addingTimeInterval(-9 * day))
        XCTAssertEqual(merged.noticeSeenAt, noon, "a notice seen stays seen")
        XCTAssertEqual(merged.lastSentDay, "2026-11-12")
        XCTAssertNil(merged.pending, "a day already counted is not waiting")
        XCTAssertEqual(merged.merging(newer: newer), merged, "idempotent, as the state's merge must be")
    }

    func testTheRecordRidesInTheStateAndOlderStatesReadWithoutIt() throws {
        var state = PersistedState()
        state.dailyCount = seen
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: data).dailyCount, seen)
        // A state written before the count has no such key, and reads as never counted.
        let older = try JSONEncoder().encode(PersistedState())
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("dailyCount"))
        XCTAssertNil(try JSONDecoder().decode(PersistedState.self, from: older).dailyCount)
    }

    // MARK: - Words

    func testTheWordsSayWhatIsSentAndWhereToTurnItOff() {
        let (fact, way) = FlashLine.split(DailyCount.notice)
        XCTAssertTrue(fact.hasPrefix("⚠ "), "a flash that waits for the next key")
        let way_ = try? XCTUnwrap(way)
        XCTAssertTrue(way_?.contains("the version, the update channel") == true)
        XCTAssertTrue(DailyCount.settingsDetail.contains("its version, the update channel"))
        XCTAssertTrue(way_?.contains("No ID and no tracker") == true)
        XCTAssertTrue(way_?.contains("Settings, General") == true)
        for text in [DailyCount.notice, DailyCount.settingsDetail] {
            XCTAssertFalse(text.contains("—") || text.contains("–") || text.contains(";"), "the voice has no dashes")
        }
        XCTAssertFalse(DailyCount.settingsDetail.hasSuffix("."), "a row's detail ends without a stop, as its neighbours do")
    }

    func testTheSwitchIsItsOwnAndOnByDefault() {
        XCTAssertTrue(Config().dailyCount)
        var file = ConfigFile()
        file.app.dailyCount = false
        file.app.autoUpdate = true
        var problems: [String] = []
        let config = Config.build(from: file, problems: &problems)
        XCTAssertFalse(config.dailyCount)
        XCTAssertTrue(config.autoUpdate, "turning the count off leaves updates alone")
    }
}
