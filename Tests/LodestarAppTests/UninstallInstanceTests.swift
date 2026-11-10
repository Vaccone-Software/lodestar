import XCTest
@testable import LodestarCore
@testable import lodestar

/// How an uninstall finds the running copy and ends it, with real processes:
/// the plan's stop and its wait, on the files the copy takes over by.
final class UninstallInstanceTests: XCTestCase {
    private func pidFile() throws -> URL {
        try instanceFolder().appendingPathComponent("lodestar.pid")
    }

    private func copy(_ file: URL, quitSeconds: Double = 0) throws -> InstanceProbe {
        try InstanceProbe(["copy", "--pid-file", file.path, "--quit-seconds", "\(quitSeconds)"], from: Self.self)
    }

    /// The running copy is found by the pid file, asked to quit, and waited
    /// for until it has restored what it parked and gone.
    func testTheRunningCopyIsFoundAskedToQuitAndWaitedFor() throws {
        let file = try pidFile()
        let running = try copy(file, quitSeconds: 0.5)
        XCTAssertNotNil(running.wait(for: "READY"))

        UninstallPlan.stopInstance(file)
        XCTAssertNotNil(running.wait(for: "TERMED"), "\(running.lines)")
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(file), "it went")
        XCTAssertFalse(running.isRunning, "and the wait did not end before it had")
        XCTAssertEqual(running.waitForExit(), 0, "it shut down, it was not killed")
        XCTAssertTrue(running.lines.contains("EXITING \(running.pid)"), "\(running.lines)")
    }

    func testWithNothingRunningTheStopAsksNobodyAndTheWaitReturnsAtOnce() throws {
        let file = try pidFile()
        UninstallPlan.stopInstance(file)  // no file
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(file))

        try "\(getpid())".write(to: file, atomically: true, encoding: .utf8)
        UninstallPlan.stopInstance(file)  // this process: it is the one running the plan, and is still here
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(file))

        // A launch takes over from whatever the file names, and it names this
        // process: the file goes before a copy is started.
        try FileManager.default.removeItem(at: file)
        let crashed = try copy(file)
        XCTAssertNotNil(crashed.wait(for: "READY"))
        crashed.crash()
        UninstallPlan.stopInstance(file)  // a pid that is not there
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(file))
    }

    /// The gap, with a real stranger: a pid file left by a crash names a
    /// process that is not Lodestar, and the uninstall asks it to quit.
    func testAStalePidFileNamingAnUnrelatedLiveProcessSignalsItToday() throws {
        let folder = try instanceFolder()
        let file = folder.appendingPathComponent("lodestar.pid")
        let signals = folder.appendingPathComponent("stranger.signals")
        let stranger = try InstanceProbe(["stranger", "--signal-log", signals.path], from: Self.self)
        XCTAssertNotNil(stranger.wait(for: "READY"))
        try "\(stranger.pid)".write(to: file, atomically: true, encoding: .utf8)

        UninstallPlan.stopInstance(file)
        let deadline = Date().addingTimeInterval(10)
        while !((try? String(contentsOf: signals, encoding: .utf8)) ?? "").contains("TERM"), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(((try? String(contentsOf: signals, encoding: .utf8)) ?? "").contains("TERM"),
                      "the unrelated process was asked to quit")
    }
}
