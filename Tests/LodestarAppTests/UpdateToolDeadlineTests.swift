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

    /// The tool's own children go with it: a tool that hangs in something
    /// it started (a shell waiting on a sleep) leaves nothing running.
    func testAToolThatHangsInAChildLeavesNothingRunning() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("grandchild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let outcome = UpdateController.run("/bin/sh", ["-c", "/bin/sleep 30 & echo $! > \(marker.path); wait"],
                                           within: .milliseconds(300))
        XCTAssertEqual(outcome, .timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        // The signal reaches the whole group, but the sleep is the shell's
        // child, not ours: once the shell is gone, launchd reaps it, a few
        // milliseconds after `run` returns on a loaded Mac (seen at 1 to 7 ms
        // in 8 of 30 loaded runs, 2026-11-27, and on CI). So it must go, and
        // soon: a sleep nobody stopped would stand for its 30 seconds.
        let until = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < until { usleep(1000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the sleep the shell started was stopped with it")
    }

    /// A tool that hangs is stopped at the deadline, and Stoic says so
    /// (`deadline.expired`, then `process.exited` for the signal that ended
    /// it). It is said from a task started on the worker queue, which
    /// carries none of the ambient context the launch bound on the main
    /// thread, so the events went to the unified log alone and never
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
        XCTAssertEqual(events.events(named: "deadline.expired").count, 1, "events: \(events.names)")
        let exited = events.events(named: "process.exited")
        XCTAssertEqual(exited.count, 1, "events: \(events.names)")
        XCTAssertEqual(exited.first?.label, "update.sleep")
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
        XCTAssertEqual(other.events(named: "process.exited").count, 1, "the context it was given")
        XCTAssertTrue(mine.events(named: "process.exited").isEmpty, "not the caller's")
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
