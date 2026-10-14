import XCTest
@testable import lodestar

/// ditto and codesign are waited on for a bounded time. A tool that never
/// exits used to hold the update's worker, and the update in `.checking`,
/// for ever.
final class UpdateToolDeadlineTests: XCTestCase {
    func testAToolThatPassesFailsOrIsMissing() {
        XCTAssertEqual(UpdateController.run("/usr/bin/true", []), .succeeded)
        XCTAssertEqual(UpdateController.run("/usr/bin/false", []), .failed)
        XCTAssertEqual(UpdateController.run("/nonexistent/tool", []), .failed)
    }

    func testAToolThatNeverExitsIsGivenUpOnAndStopped() {
        let started = Date()
        let outcome = UpdateController.run("/bin/sleep", ["30"], within: .milliseconds(80))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "returned at the deadline, not when sleep ended")
    }

    func testTheDeadlineIsGenerousForARealUnpack() {
        XCTAssertGreaterThanOrEqual(UpdateController.toolDeadline, .seconds(60))
    }

    func testAMarkerThatCannotBeWrittenReportsFailure() {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        XCTAssertFalse(UpdateController.writeMarker("v1", to: blocker.appendingPathComponent("refused"),
                                                    what: "the refusal tombstone", consequence: "a loop"))
        let good = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: good) }
        XCTAssertTrue(UpdateController.writeMarker("v1", to: good, what: "a marker", consequence: "nothing"))
    }
}
