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

    /// Every launch of a Lodestar that the person did not ask for stays
    /// behind the app in front. Brought forward, a Lodestar with no window
    /// to take a key answered each key typed during the handover, and each
    /// key the smoke probe posted, with the alert.
    func testNoLaunchOfLodestarComesForward() throws {
        let successor = UpdateController.successorLaunch
        XCTAssertTrue(successor.createsNewApplicationInstance, "a new instance, or the old one only comes forward")
        XCTAssertFalse(successor.activates, "the successor launches behind the app in front")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let smoke = try String(contentsOf: root.appendingPathComponent("scripts/smoke.sh"), encoding: .utf8)
        for (name, text) in [("the rollback", UpdateController.watchdogScript), ("smoke.sh", smoke)] {
            let lines = text.split(separator: "\n").filter { $0.contains("open ") && $0.contains("$APP") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            XCTAssertFalse(lines.isEmpty, "\(name) still launches the app")
            for line in lines { XCTAssertTrue(line.contains("open -g"), "\(name): \(line.trimmingCharacters(in: .whitespaces))") }
        }
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
