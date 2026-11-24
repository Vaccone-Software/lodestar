import XCTest
@testable import LodestarCore

final class MeetingsInProgressTests: XCTestCase {
    private func occurrence(_ id: String, from: Date, minutes: Double) -> Meetings.Occurrence {
        Meetings.Occurrence(eventID: id, title: "Standup", start: from,
                            end: from.addingTimeInterval(minutes * 60),
                            link: Meetings.Link(provider: .zoom, url: "https://example.invalid"),
                            calendar: "work", account: "work")
    }

    private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testInsideItsWindow() {
        let one = occurrence("a", from: noon, minutes: 30)
        XCTAssertTrue(Meetings.inProgress(occurrences: [one],
                                          now: noon.addingTimeInterval(60)))
    }

    func testStartIsInclusiveAndEndIsNot() {
        let one = occurrence("a", from: noon, minutes: 30)
        XCTAssertTrue(Meetings.inProgress(occurrences: [one], now: noon))
        XCTAssertFalse(Meetings.inProgress(occurrences: [one],
                                           now: noon.addingTimeInterval(30 * 60)))
    }

    func testBeforeAndAfterAreQuiet() {
        let one = occurrence("a", from: noon, minutes: 30)
        XCTAssertFalse(Meetings.inProgress(occurrences: [one],
                                           now: noon.addingTimeInterval(-60)))
        XCTAssertFalse(Meetings.inProgress(occurrences: [one],
                                           now: noon.addingTimeInterval(3600)))
    }

    /// The whole reason this is not `candidate(…) != nil`: joining spends
    /// the occurrence, and joining is when the sharing starts. A question
    /// answered from the chip would go false at exactly the wrong instant.
    func testSpentOccurrencesStillCount() {
        let one = occurrence("a", from: noon, minutes: 30)
        let mid = noon.addingTimeInterval(5 * 60)
        XCTAssertNil(Meetings.candidate(occurrences: [one], now: mid,
                                        leadMinutes: 5, spent: [one.key]))
        XCTAssertTrue(Meetings.inProgress(occurrences: [one], now: mid))
    }

    /// The lead minutes are somebody else's job — the chip is standing
    /// through them, and the chip already suppresses the coach.
    func testLeadTimeIsNotInProgress() {
        let one = occurrence("a", from: noon, minutes: 30)
        let soon = noon.addingTimeInterval(-2 * 60)
        XCTAssertNotNil(Meetings.candidate(occurrences: [one], now: soon,
                                           leadMinutes: 5, spent: []))
        XCTAssertFalse(Meetings.inProgress(occurrences: [one], now: soon))
    }

    func testAnyOverlappingOccurrenceCounts() {
        let one = occurrence("a", from: noon, minutes: 15)
        let two = occurrence("b", from: noon.addingTimeInterval(3600), minutes: 15)
        XCTAssertTrue(Meetings.inProgress(occurrences: [one, two],
                                          now: noon.addingTimeInterval(3600 + 60)))
        XCTAssertFalse(Meetings.inProgress(occurrences: [one, two],
                                           now: noon.addingTimeInterval(1800)))
    }

    func testNoOccurrencesIsQuiet() {
        XCTAssertFalse(Meetings.inProgress(occurrences: [], now: noon))
    }
}
