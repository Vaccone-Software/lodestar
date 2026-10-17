import Stoic
import StoicTesting
import XCTest
@testable import LodestarCore

/// The note a run leaves about itself: quit or died, readable at the
/// next boot without the process that wrote it.
final class RunMarkerTests: XCTestCase {
    func testADeadPidWithNoQuitNoteIsACrash() {
        XCTAssertTrue(RunMarker.diedUncleanly(contents: RunMarker.alive(pid: 4242),
                                              isAlive: { _ in false }))
    }

    func testALivePidIsAnInstanceOnItsWayOut() {
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "4242\n", isAlive: { $0 == 4242 }))
    }

    func testAQuittingNoteIsAQuitHoweverFarItGot() {
        let note = RunMarker.quitting(pid: 4242)
        XCTAssertTrue(RunMarker.isQuitting(note))
        XCTAssertEqual(RunMarker.pid(in: note), 4242, "the pid still names whose note it is")
        XCTAssertFalse(RunMarker.diedUncleanly(contents: note, isAlive: { _ in false }),
                       "a logout that cut the restore short is not a crash")
    }

    func testGarbageIsNothingToRecoverFrom() {
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "", isAlive: { _ in false }))
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "pid", isAlive: { _ in false }))
        XCTAssertNil(RunMarker.pid(in: "quit"))
    }
}

/// The crash-loop breaker beside the run marker.
final class LaunchGuardTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-guard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch(build: String = "0.41.0") -> RunMarker.Mode {
        // A fresh guard each time: each launch is a new process.
        RunMarker.Mode(RunMarker.launchGuard(in: directory, build: build, bootSession: "boot-1").beginLaunch())
    }

    func testLaunchesThatNeverFinishPutTheNextOneInSafeMode() {
        XCTAssertEqual(launch(), .normal)
        XCTAssertEqual(launch(), .normal, "one died")
        XCTAssertEqual(launch(), .normal, "two died")
        XCTAssertEqual(launch(), .safe(uncleanLaunches: 3), "three in a row")
    }

    func testAStableLaunchStartsTheCountOver() throws {
        XCTAssertEqual(launch(), .normal)
        XCTAssertEqual(launch(), .normal)
        try RunMarker.launchGuard(in: directory, build: "0.41.0", bootSession: "boot-1").markStable()
        XCTAssertEqual(launch(), .normal)
        XCTAssertEqual(launch(), .normal)
        XCTAssertEqual(launch(), .normal, "the two before the stable launch no longer count")
    }

    func testAQuitIsNotACrash() throws {
        for _ in 0..<6 {
            XCTAssertEqual(launch(), .normal)
            try RunMarker.launchGuard(in: directory, build: "0.41.0", bootSession: "boot-1").markCleanExit()
        }
    }

    func testANewBuildIsTheWayOutOfALoop() {
        for _ in 0..<4 { _ = launch() }
        XCTAssertEqual(launch(), .safe(uncleanLaunches: 4))
        XCTAssertEqual(launch(build: "0.41.1"), .normal)
    }

    func testTheStateFileSitsBesideTheOtherState() {
        _ = launch()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(RunMarker.launchGuardFile).path))
    }

    /// The guard must never be the reason the app cannot start: a state file
    /// it cannot write is a normal launch, and Stoic reports the one thing
    /// lost (this launch will not be counted) as `launch.record_failed`.
    func testAGuardThatCannotWriteStillLetsTheLaunchGoOnAndSaysSo() async {
        let missing = directory.appendingPathComponent("nowhere", isDirectory: true)
        let events = RecordingInstrumentation()
        let mode = await withTestAmbient(clock: TestClock(), events: events) {
            RunMarker.Mode(RunMarker.launchGuard(in: missing, build: "x", bootSession: nil).beginLaunch())
        }
        XCTAssertEqual(mode, .normal)
        XCTAssertEqual(events.names, ["launch.record_failed"])
        XCTAssertEqual(events.events.first?.level, .error)
    }
}
