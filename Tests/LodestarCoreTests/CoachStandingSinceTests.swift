import XCTest
@testable import LodestarCore

/// When a suggestion took the standing slot, and why that has to outlive
/// the process.
///
/// `cueWaitDays` is the promise that a suggestion holding out for its cue
/// eventually goes out at any quiet boundary instead — "nothing waits
/// forever". The stamp it counts from used to be set on the first
/// recommendation pass after launch, which made the promise conditional on
/// the app running uninterrupted for four days. Across 120 launches on the
/// author's machine the longest run was 2.3 days and the median was twelve
/// minutes, so the hatch had never once opened. An auto-update is enough
/// to reset it.
final class CoachStandingSinceTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        // Never the real state.json: a store with a defaulted path has
        // written into live user data from a test suite before.
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-standing-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.appendingPathExtension("bak"))
        super.tearDown()
    }

    func testTheStampIsTakenOnceAndNeverMoves() {
        let store = StateStore(file: file)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let stamped = store.coachStandingSince("shorten:b x", now: first)
        XCTAssertEqual(stamped, first)

        // The regression: asking again — which every recommendation pass
        // does — must not restart the clock.
        let later = first.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(store.coachStandingSince("shorten:b x", now: later), first)
    }

    /// The one that actually failed in the field: a relaunch used to hand
    /// the suggestion a fresh stamp, so four days never elapsed.
    func testTheStampSurvivesARestart() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let store = StateStore(file: file)
        _ = store.coachStandingSince("shorten:b x", now: first)
        store.save()

        let restarted = StateStore(file: file)
        restarted.load()
        let afterRelaunch = first.addingTimeInterval(2 * 86_400)
        let recovered = restarted.coachStandingSince("shorten:b x", now: afterRelaunch)
        XCTAssertEqual(recovered.timeIntervalSince1970, first.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertGreaterThanOrEqual(afterRelaunch.timeIntervalSince(recovered), 2 * 86_400)
    }

    func testEachSuggestionKeepsItsOwnStamp() {
        let store = StateStore(file: file)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(86_400)
        XCTAssertEqual(store.coachStandingSince("shorten:b x", now: first), first)
        XCTAssertEqual(store.coachStandingSince("shorten:v z", now: second), second)
        XCTAssertEqual(store.coachStandingSince("shorten:b x", now: second), first)
    }

    /// Only one suggestion stands at a time, so the map grows only as they
    /// rotate — but it must still be bounded, and eviction must take the
    /// oldest rather than whatever the dictionary happens to yield.
    func testTheMapStaysBounded() {
        let store = StateStore(file: file)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let total = StateStore.coachStandingCap + 20
        for i in 0..<total {
            _ = store.coachStandingSince("shorten:\(i)",
                                         now: start.addingTimeInterval(Double(i) * 60))
        }
        let map = store.state.coachStandingSince ?? [:]
        XCTAssertLessThanOrEqual(map.count, StateStore.coachStandingCap)
        // The newest survived; the oldest is what went.
        XCTAssertNotNil(map["shorten:\(total - 1)"])
        XCTAssertNil(map["shorten:0"])
    }
}
