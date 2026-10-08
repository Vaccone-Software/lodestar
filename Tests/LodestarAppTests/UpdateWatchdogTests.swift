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

    /// A surface that only shows never becomes the key window. A titled
    /// panel ordered in took key status without Lodestar coming forward,
    /// and the launch note rang the alert for every key typed under it.
    func testASurfaceThatOnlyShowsNeverTakesKeys() throws {
        XCTAssertFalse(Glass.makePanel(level: .statusBar, takesKeys: false).canBecomeKey)
        XCTAssertTrue(Glass.makePanel(level: .statusBar).canBecomeKey, "a surface that types still can")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["HUD", "ModePill", "SelectOverlay", "IndexBadges", "LinkChip", "CheatSheet"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/lodestar/\(name).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains("takesKeys: false"), "\(name) only shows, so its panel never takes keys")
        }
    }
}

/// The watchdog, run: a fake new app and old app in a folder, a pid file,
/// and stand-ins for `sleep` (instant) and `open` (recorded) first on the
/// PATH. Its tests above only read the text; these hold what it does.
final class UpdateWatchdogRunTests: XCTestCase {
    private var root: URL!
    private var app: URL { root.appendingPathComponent("Lodestar.app") }
    private var previous: URL { root.appendingPathComponent("Lodestar.previous.app") }
    private var markers: URL { root.appendingPathComponent("markers") }
    private var pidFile: URL { root.appendingPathComponent("lodestar.pid") }
    private var opened: URL { root.appendingPathComponent("opened.log") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-run-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in [app.appendingPathComponent("Contents/MacOS"), previous.appendingPathComponent("Contents/MacOS"),
                    markers, root.appendingPathComponent("bin")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "new".write(to: app.appendingPathComponent("Contents/which"), atomically: true, encoding: .utf8)
        try "old".write(to: previous.appendingPathComponent("Contents/which"), atomically: true, encoding: .utf8)
        try "0.0.1".write(to: markers.appendingPathComponent("updated-to"), atomically: true, encoding: .utf8)
        try executable("bin/sleep", "#!/bin/bash\nexit 0\n")
        try executable("bin/open", "#!/bin/bash\necho \"$*\" >> \"\(opened.path)\"\n")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func executable(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The new build's CLI: answers `state --json` with this status.
    private func successorAnswers(_ status: Int32) throws {
        try executable("Lodestar.app/Contents/MacOS/lodestar", "#!/bin/bash\nexit \(status)\n")
    }

    private func run(pid: String, routing: Bool = false) throws -> Int32 {
        try pid.write(to: pidFile, atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("watchdog.sh")
        try UpdateController.watchdogScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, app.path, previous.path, "1", "0.0.2", markers.path, pidFile.path,
                             routing ? "1" : "0"]
        process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private var which: String? { try? String(contentsOf: app.appendingPathComponent("Contents/which"), encoding: .utf8) }
    private var rolledBack: String? { try? String(contentsOf: markers.appendingPathComponent("rolled-back"), encoding: .utf8) }
    private var opens: [String] {
        ((try? String(contentsOf: opened, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// A pid that is alive and is not the old one: this test process.
    private var alive: String { String(ProcessInfo.processInfo.processIdentifier) }

    func testASuccessorThatBootsAndAnswersIsBlessed() throws {
        try successorAnswers(0)
        XCTAssertEqual(try run(pid: alive), 0)
        XCTAssertEqual(which, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path), "the old build is let go")
        XCTAssertNil(rolledBack)
        XCTAssertEqual(opens, [], "nothing relaunched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers.appendingPathComponent("updated-to").path),
                      "the success marker stays for the new build to announce")
    }

    func testASuccessorThatNeverBootsIsRolledBack() throws {
        try successorAnswers(0)
        XCTAssertEqual(try run(pid: "1"), 0, "the pid file never changed hands")
        XCTAssertEqual(which, "old", "the old build is back in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(rolledBack, "0.0.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markers.appendingPathComponent("updated-to").path),
                       "no false 'updated' when that version boots some day")
        XCTAssertEqual(opens, ["-g -n \(app.path)"], "relaunched, behind the app in front")
    }

    /// Alive and holding the pid, but its main thread answers nothing.
    func testASuccessorThatNeverAnswersIsRolledBack() throws {
        try successorAnswers(1)
        _ = try run(pid: alive)
        XCTAssertEqual(which, "old")
        XCTAssertEqual(rolledBack, "0.0.2")
    }

    func testWhileRoutingTheSuccessorMustSayItsRouterAnswered() throws {
        try successorAnswers(0)
        try "12345".write(to: markers.appendingPathComponent("routes-ok"), atomically: true, encoding: .utf8)
        _ = try run(pid: alive, routing: true)
        XCTAssertEqual(which, "old", "a stale marker from another pid blesses nothing")
    }

    func testWhileRoutingASuccessorThatSaysSoIsBlessed() throws {
        try successorAnswers(0)
        try alive.write(to: markers.appendingPathComponent("routes-ok"), atomically: true, encoding: .utf8)
        _ = try run(pid: alive, routing: true)
        XCTAssertEqual(which, "new")
        XCTAssertNil(rolledBack)
    }

    /// Another actor already resolved the swap: with nothing to put back,
    /// the app is never deleted.
    func testWithNothingToPutBackTheAppIsLeftAlone() throws {
        try successorAnswers(0)
        try FileManager.default.removeItem(at: previous)
        XCTAssertEqual(try run(pid: "1"), 0)
        XCTAssertEqual(which, "new")
        XCTAssertNil(rolledBack)
        XCTAssertEqual(opens, [])
    }
}
