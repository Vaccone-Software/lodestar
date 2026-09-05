import XCTest
@testable import LodestarCore

final class CurriculumTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let since = Date(timeIntervalSince1970: 1_700_000_000)

    private func next(after days: Double, used: [String: Date] = [:],
                      records: [Curriculum.Lesson: Curriculum.Record] = [:],
                      walkDone: Bool = true) -> Curriculum.Lesson? {
        Curriculum.next(now: since.addingTimeInterval(days * day), since: since,
                        verbsLastUsed: used, records: records, walkDone: walkDone)
    }

    func testNothingBeforeTheWalkIsDone() {
        XCTAssertNil(next(after: 30, walkDone: false))
    }

    func testNothingBeforeTheRecordBegan() {
        XCTAssertNil(Curriculum.next(now: Date(), since: .distantPast, verbsLastUsed: [:],
                                     records: [:], walkDone: true))
    }

    func testLessonsArriveOnTheirDaysInOrder() {
        XCTAssertNil(next(after: 1), "day one is the walk's")
        XCTAssertEqual(next(after: 2), .inside)
        XCTAssertEqual(next(after: 9), .inside, "the first undone lesson is the one due")
    }

    func testAGestureTheHandFoundIsNeverTaught() {
        let used = ["hints": since.addingTimeInterval(day)]
        XCTAssertEqual(next(after: 4, used: used), .web)
    }

    func testCompletionMovesOn() {
        let records: [Curriculum.Lesson: Curriculum.Record] = [
            .inside: Curriculum.completed(nil, at: since.addingTimeInterval(2 * day)),
        ]
        XCTAssertNil(next(after: 3, records: records), "web is not due until day four")
        XCTAssertEqual(next(after: 4, records: records), .web)
    }

    func testSpacingBetweenOffers() {
        let offered = Curriculum.offered(nil, at: since.addingTimeInterval(4 * day))
        let records: [Curriculum.Lesson: Curriculum.Record] = [
            .inside: Curriculum.completed(nil, at: since.addingTimeInterval(2 * day)),
            .web: offered,
        ]
        XCTAssertNil(next(after: 5, records: records), "one lesson a couple of days apart")
        XCTAssertEqual(next(after: 6, records: records), .clipboard,
                       "a lesson passed over does not hold the ones behind it")
        var later = records
        later[.clipboard] = Curriculum.offered(nil, at: since.addingTimeInterval(6 * day))
        XCTAssertEqual(next(after: 9, records: later), .web,
                       "a lesson passed over retries after the retry wait, ahead of the rest")
    }

    func testTwoOffersParkALesson() {
        var web = Curriculum.offered(nil, at: since.addingTimeInterval(4 * day))
        web = Curriculum.offered(web, at: since.addingTimeInterval(9 * day))
        let records: [Curriculum.Lesson: Curriculum.Record] = [
            .inside: Curriculum.completed(nil, at: since.addingTimeInterval(2 * day)),
            .web: web,
        ]
        XCTAssertEqual(next(after: 15, records: records), .clipboard,
                       "parked for good after two offers; the next lesson is due instead")
    }

    func testEveryLessonEventuallyArrivesForAnUntouchedHand() {
        var records: [Curriculum.Lesson: Curriculum.Record] = [:]
        var seen: [Curriculum.Lesson] = []
        var days = 0.0
        while days < 60 {
            if let lesson = next(after: days, records: records) {
                seen.append(lesson)
                records[lesson] = Curriculum.completed(
                    Curriculum.offered(records[lesson], at: since.addingTimeInterval(days * day)),
                    at: since.addingTimeInterval(days * day))
            }
            days += 1
        }
        XCTAssertEqual(seen, Curriculum.order.map(\.lesson))
    }

    func testPositionNamesTheLessonsPlace() {
        XCTAssertEqual(Curriculum.position(of: .inside).0, 1)
        XCTAssertEqual(Curriculum.position(of: .scroll).0, Curriculum.order.count)
    }
}
