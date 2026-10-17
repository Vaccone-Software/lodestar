import XCTest
@testable import lodestar
@testable import LodestarCore

/// The era is written when the instrument changes, and when an attached
/// keyboard's report interval is not yet written down: once per keyboard,
/// again only if it reports differently, never because one went away.
final class EraTrackerTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("era-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func info(_ intervals: [String: ReportInterval]?, version: String = "0.46.0") -> EraInfo {
        EraInfo(appVersion: version, keySchema: 3, pointerSchema: 2, keyboards: Array((intervals ?? [:]).keys),
                reportIntervals: intervals)
    }

    func testTheFirstEraWritesEveryIntervalDown() {
        let tracker = EraTracker(file: file, ring: SealedFixture.vault(file.deletingLastPathComponent()).ring(.health))
        let event = tracker.check(info(["builtin": .microseconds(8000), "bt": .unknown]))
        XCTAssertEqual(event?.era?.reason, "boot")
        XCTAssertEqual(event?.era?.reportIntervals?["builtin"], .microseconds(8000))
        XCTAssertEqual(event?.era?.reportIntervals?["bt"], .unknown)
        XCTAssertNil(tracker.check(info(["builtin": .microseconds(8000), "bt": .unknown])), "nothing new")
    }

    func testAKeyboardAttachedLaterIsWrittenDownOnce() {
        let tracker = EraTracker(file: file, ring: SealedFixture.vault(file.deletingLastPathComponent()).ring(.health))
        _ = tracker.check(info(["builtin": .microseconds(8000)]))
        let attached = tracker.check(info(["builtin": .microseconds(8000), "kinesis": .microseconds(11250)]))
        XCTAssertEqual(attached?.era?.reason, "keyboard")
        XCTAssertEqual(attached?.era?.reportIntervals?["kinesis"], .microseconds(11250))
        XCTAssertNil(tracker.check(info(["builtin": .microseconds(8000)])), "a keyboard going away is not an era")
        XCTAssertNil(tracker.check(info(["builtin": .microseconds(8000), "kinesis": .microseconds(11250)])),
                     "back again, already written down")
    }

    func testAKeyboardReportingDifferentlyIsWrittenDownAgain() {
        let tracker = EraTracker(file: file, ring: SealedFixture.vault(file.deletingLastPathComponent()).ring(.health))
        _ = tracker.check(info(["kinesis": .unknown]))
        XCTAssertEqual(tracker.check(info(["kinesis": .microseconds(7500)]))?.era?.reason, "keyboard")
    }

    func testABuildChangeIsStillAChange() {
        let tracker = EraTracker(file: file, ring: SealedFixture.vault(file.deletingLastPathComponent()).ring(.health))
        _ = tracker.check(info(["builtin": .microseconds(8000)]))
        XCTAssertEqual(tracker.check(info(["builtin": .microseconds(8000)], version: "0.46.1"))?.era?.reason, "changed")
    }

    /// An era file from before intervals were read: the instrument is the
    /// same, so the only news is the intervals, written down once.
    func testAnEraFileFromBeforeIntervalsLearnsThemOnce() throws {
        let tracker = EraTracker(file: file, ring: SealedFixture.vault(file.deletingLastPathComponent()).ring(.health))
        _ = tracker.check(info(nil))
        let ring = SealedFixture.vault(file.deletingLastPathComponent()).ring(.health)
        let bytes = try XCTUnwrap(SealedValueFile(url: file, ring: ring).read().bytes)
        var stored = try JSONSerialization.jsonObject(with: Data(bytes)) as! [String: Any]
        stored.removeValue(forKey: "intervals")
        // Written back in the clear, as an older build left it: still read.
        try JSONSerialization.data(withJSONObject: stored).write(to: file)
        XCTAssertEqual(tracker.check(info(["builtin": .microseconds(8000)]))?.era?.reason, "keyboard")
        XCTAssertNil(tracker.check(info(["builtin": .microseconds(8000)])))
    }
}
