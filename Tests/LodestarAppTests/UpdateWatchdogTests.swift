import XCTest
@testable import lodestar

/// The watchdog's two verdicts: the pid file changed hands, and the
/// successor answers on its socket. A build that holds a pid and says
/// nothing is rolled back like one that never booted.
final class UpdateWatchdogTests: XCTestCase {
    func testTheWatchdogProbesTheSocketBeforeBlessing() {
        let script = UpdateController.watchdogScript
        XCTAssertTrue(script.contains("state --json"), "the successor must answer a verb")
        XCTAssertTrue(script.contains("alarm shift; exec @ARGV' 3"), "with a three-second alarm")
        // The probe stands between the pid check and the blessing.
        let probe = script.range(of: "state --json")!.lowerBound
        let bless = script.range(of: "rm -rf \"$PREVIOUS\"\n        exit 0")!.lowerBound
        let pid = script.range(of: "kill -0 \"$PID\"")!.lowerBound
        XCTAssertLessThan(pid, probe)
        XCTAssertLessThan(probe, bless)
        // And a failed probe keeps polling rather than blessing.
        let after = script[probe...]
        XCTAssertTrue(after.contains("continue"))
        XCTAssertTrue(script.contains("mv \"$PREVIOUS\" \"$APP\""), "the rollback is still there")
    }

    func testTheScriptIsValidBash() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-\(UUID().uuidString).sh")
        try UpdateController.watchdogScript.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
