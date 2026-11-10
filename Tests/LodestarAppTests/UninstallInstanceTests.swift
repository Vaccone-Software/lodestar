import XCTest
import StoicStore
@testable import LodestarCore
@testable import lodestar

/// How an uninstall finds the running copy and ends it, with real processes: the
/// plan's stop and its wait, on the files the copy takes over by. A copy of the
/// new build is found by the lock it holds, an older one by the pid file it wrote,
/// and a pid file that only names a stranger finds nobody.
final class UninstallInstanceTests: XCTestCase {
    private var folder: URL!
    private var files: SingleInstance.Files!

    override func setUpWithError() throws {
        folder = try instanceFolder()
        files = .init(lock: folder.appendingPathComponent("lodestar.lock"), pid: folder.appendingPathComponent("lodestar.pid"))
    }

    /// The machine, but with this process called what the probe is called: the
    /// app and the copy it replaces are both `lodestar`; the test host and the
    /// probe are not, and a copy is only taken for an older build of the same name.
    private struct AsTheProbe: InstanceProcesses {
        private let system = SystemProcesses()
        func isAlive(_ pid: Int32) -> Bool { system.isAlive(pid) }
        func terminate(_ pid: Int32) { system.terminate(pid) }
        func identity(of pid: Int32) -> ProcessIdentity? {
            pid == getpid() ? system.identity(of: pid).map { ProcessIdentity(started: $0.started, name: "probe") }
                : system.identity(of: pid)
        }
    }

    private func startCopy(locked: Bool, quitSeconds: Double = 0) throws -> InstanceProbe {
        var arguments = ["copy", "--pid-file", files.pid.path, "--quit-seconds", "\(quitSeconds)"]
        if locked { arguments += ["--lock", files.lock.path] }
        return try InstanceProbe(arguments, from: Self.self)
    }

    /// The running copy is found by its lock, asked to quit, and waited for until
    /// it has restored what it parked and gone.
    func testACopyHoldingTheLockIsFoundAskedToQuitAndWaitedFor() throws {
        let running = try startCopy(locked: true, quitSeconds: 0.5)
        XCTAssertNotNil(running.wait(for: "READY"))
        UninstallPlan.stopInstance(files)
        XCTAssertNotNil(running.wait(for: "TERMED"), "\(running.lines)")
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files), "it went")
        XCTAssertFalse(running.isRunning, "and the wait did not end before it had")
        XCTAssertEqual(running.waitForExit(), 0, "it shut down, it was not killed")
        XCTAssertTrue(running.lines.contains("EXITING \(running.pid)"), "\(running.lines)")
    }

    /// An instance of an older build holds no lock: it is found by the pid file.
    func testACopyOfAnOlderBuildIsFoundByThePidFile() throws {
        let running = try startCopy(locked: false, quitSeconds: 0.3)
        XCTAssertNotNil(running.wait(for: "READY"))
        UninstallPlan.stopInstance(files, processes: AsTheProbe())
        XCTAssertNotNil(running.wait(for: "TERMED"), "\(running.lines)")
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files, processes: AsTheProbe()))
        XCTAssertEqual(running.waitForExit(), 0)
    }

    func testWithNothingRunningTheStopAsksNobodyAndTheWaitReturnsAtOnce() throws {
        UninstallPlan.stopInstance(files)  // no files
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files))

        try "\(getpid())".write(to: files.pid, atomically: true, encoding: .utf8)
        UninstallPlan.stopInstance(files)  // this process: it is the one running the plan, and is still here
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files))

        // A launch takes over from whatever the file names, and it names this
        // process: the file goes before a copy is started.
        try FileManager.default.removeItem(at: files.pid)
        let crashed = try startCopy(locked: true)
        XCTAssertNotNil(crashed.wait(for: "READY"))
        crashed.crash()
        UninstallPlan.stopInstance(files)  // a record and a pid that are not there
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files))
    }

    /// A pid file left by a crash that names a process that is not Lodestar:
    /// the uninstall does not ask it to quit, and does not wait for it.
    func testAStalePidFileNamingAnUnrelatedLiveProcessSignalsNothing() throws {
        let signals = folder.appendingPathComponent("stranger.signals")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "trap 'echo TERM >> \"\(signals.path)\"' TERM; while :; do sleep 0.1; done"]
        try shell.run()
        addTeardownBlock { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }
        usleep(300_000)
        try "\(shell.processIdentifier)".write(to: files.pid, atomically: true, encoding: .utf8)

        UninstallPlan.stopInstance(files)
        let began = Date()
        XCTAssertTrue(UninstallPlan.awaitInstanceExit(files), "no copy of Lodestar is there to wait for")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        usleep(500_000)
        XCTAssertFalse(((try? String(contentsOf: signals, encoding: .utf8)) ?? "").contains("TERM"), "the stranger was sent nothing")
        XCTAssertTrue(shell.isRunning)
    }

    /// The plan stops the copy through the files its world names.
    func testThePlanStopsTheInstanceThroughTheFilesItNames() {
        var seen: [SingleInstance.Files] = []
        var actions = UninstallPlan.Actions()
        actions.stopInstance = { seen.append($0) }
        actions.stopAgent = {}
        actions.forgetPermissions = { _ in }
        let world = UninstallPlan.World(
            agentPlist: folder.appendingPathComponent("a.plist"), bundles: [], links: [],
            alertSound: folder.appendingPathComponent("a.aiff"), alertSelected: false, dataRoots: [], keychainItems: "",
            pidFile: files.pid, lockFile: files.lock, bundleID: "x", browserToRestore: nil, exists: { _ in false })
        UninstallPlan.make(world: world, purge: false, actions: actions).steps.forEach { $0.run() }
        XCTAssertEqual(seen, [files], "the lock and the pid file, together")
    }
}
