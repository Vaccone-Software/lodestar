import Foundation
import LodestarCore
import Stoic
import StoicProcess
import StoicTesting
import XCTest

/// The one way Lodestar runs another program, from a thread that cannot
/// await (a dispatch queue, the launch path).
final class ProgramsTests: XCTestCase {
    func testARunReturnsWhatTheProgramPrintedAndHowItEnded() throws {
        let command = Command("/bin/sh", ["-c", "echo hello; exit 3"], environment: Programs.environment)
        let result = try Programs.runBlocking(command, timeout: .seconds(10)).get()
        XCTAssertEqual(result.exit, .exited(3))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outputText, "hello\n")
    }

    func testAProgramThatIsNotThereIsAFailureNotAResult() {
        let result = Programs.runBlocking(Programs.quiet("/nonexistent/tool", []), timeout: .seconds(10))
        guard case .failure(let error) = result else { return XCTFail("ran: \(result)") }
        XCTAssertTrue(error is ProcessError, "\(error)")
    }

    func testAProgramPastItsDeadlineIsStoppedAndSaysSo() throws {
        let began = ContinuousClock.now
        let result = try Programs.runBlocking(Programs.quiet("/bin/sleep", ["30"]), timeout: .milliseconds(100)).get()
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit, .signalled(SIGTERM))
        XCTAssertLessThan(began.duration(to: .now), .seconds(5), "returned at the deadline, not when sleep ended")
    }

    /// Run from a dispatch queue, which carries no Stoic context, the events
    /// go to the context named.
    func testEventsGoToTheContextNamed() {
        let events = RecordingInstrumentation()
        var ambient = Ambient.current
        ambient.instrumentation = events
        let ran = expectation(description: "ran")
        DispatchQueue(label: "test.programs").async {
            _ = Programs.runBlocking(Programs.quiet("/usr/bin/true", []), timeout: .seconds(10),
                                     label: "named", ambient: ambient)
            ran.fulfill()
        }
        wait(for: [ran], timeout: 15)
        XCTAssertEqual(events.events(named: "process.exited").first?.label, "named", "events: \(events.names)")
    }

    /// The code names come from git; outside a repository there are none,
    /// and git's complaint is not taken for a name.
    func testGitOutsideARepositoryGivesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(CodeNames.gather(folder), [])
    }
}
