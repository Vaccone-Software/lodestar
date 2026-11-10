import Stoic
import StoicTesting
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

    /// A tool that hangs is abandoned, and Stoic says so (`abandoned.started`,
    /// a warning). It is said from a detached task started on the worker
    /// queue, neither of which carries the ambient context the launch bound on
    /// the main thread, so the event went to the unified log alone and never
    /// reached Lodestar's own through `StoicLog`. The controller keeps the
    /// context it was made in and the tool runs in it.
    func testAnAbandonedToolIsReportedToTheInstrumentationTheControllerWasMadeUnder() {
        let events = RecordingInstrumentation()
        // Made where the launch makes it, with the app's instrumentation bound.
        let controller = withAmbient({ $0.instrumentation = events }) { UpdateController() }
        // Run where the update runs it: a dispatch queue, outside that binding.
        let ran = expectation(description: "the tool was given up on")
        let outcome = OutcomeCell()
        DispatchQueue(label: "test.update.worker").async {
            outcome.value = controller.runTool("/bin/sleep", ["30"], within: .milliseconds(80))
            ran.fulfill()
        }
        wait(for: [ran], timeout: 10)
        XCTAssertEqual(outcome.value, .timedOut)
        let started = events.events(named: "abandoned.started")
        XCTAssertEqual(started.count, 1, "events: \(events.names)")
        XCTAssertEqual(started.first?.label, "update.sleep")
    }

    func testAToolRunInAnotherContextReportsThere() {
        let mine = RecordingInstrumentation()
        let other = RecordingInstrumentation()
        let outcome = withAmbient({ $0.instrumentation = mine }) { () -> UpdateController.RunOutcome in
            var captured = Ambient.current
            captured.instrumentation = other
            return UpdateController.run("/bin/sleep", ["30"], within: .milliseconds(80), ambient: captured)
        }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(other.events(named: "abandoned.started").count, 1, "the context it was given")
        XCTAssertTrue(mine.events(named: "abandoned.started").isEmpty, "not the caller's")
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

    private final class OutcomeCell: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UpdateController.RunOutcome?
        var value: UpdateController.RunOutcome? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
