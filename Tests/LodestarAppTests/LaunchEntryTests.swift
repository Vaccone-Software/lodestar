import Stoic
import StoicStore
import XCTest
import LodestarCore
@testable import lodestar

/// What a launch that is in safe mode writes to the log. Stoic's launch
/// guard says it (`launch.safe_mode`, which `StoicLog` carries into the log
/// with the count and the limit), and the app said it again in a line of its
/// own, so a reader of the log saw one decision twice.
final class LaunchEntryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-entry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func guardian() -> LaunchGuard {
        RunMarker.launchGuard(in: directory, build: "0.99.0", bootSession: "boot-1")
    }

    /// Launches that were begun and never finished, the app being killed in each.
    private func neverFinished(_ launches: Int) {
        for _ in 0..<launches { _ = guardian().beginLaunch() }
    }

    /// The log's lines while `body` runs, with Stoic's events going to it as
    /// they do in the app (main.swift binds `StoicLog` for the run loop).
    private func logged<T>(_ body: () -> T) -> (T, [String]) {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [String] = []
        Log.listener = { line in lock.withLock { lines.append(line) } }
        defer { Log.listener = nil }
        let result = withAmbient({ $0.instrumentation = CompositeInstrumentation([$0.instrumentation, StoicLog()]) }) {
            body()
        }
        return (result, lock.withLock { lines })
    }

    func testSafeModeIsSaidOnceAndTheWatchdogIsToldToLogAStallAndLive() {
        neverFinished(3)
        let watchdog = MainThreadWatchdog()
        let (mode, lines) = logged { LaunchEntry.begin(guardian(), watchdog: watchdog) }
        XCTAssertEqual(mode, .safe(uncleanLaunches: 3))
        XCTAssertEqual(watchdog.response, .logOnly, "the stall is written down and the process left alone")
        let said = lines.filter { $0.lowercased().contains("safe") }
        XCTAssertEqual(said.count, 1, "one decision, one line: \(lines)")
        XCTAssertTrue(said[0].contains(" ERR  stoic.launch.safe_mode unclean=3 limit=3"), said[0])
    }

    func testANormalLaunchSaysNothingAndKeepsTheAbort() {
        neverFinished(1)
        let watchdog = MainThreadWatchdog()
        let (mode, lines) = logged { LaunchEntry.begin(guardian(), watchdog: watchdog) }
        XCTAssertEqual(mode, .normal)
        XCTAssertEqual(watchdog.response, .abort)
        XCTAssertEqual(lines.filter { $0.lowercased().contains("safe") }, [])
    }
}
