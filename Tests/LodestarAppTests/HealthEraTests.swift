import XCTest
@testable import lodestar
@testable import LodestarCore

/// The era check reads preferences, the IO registry and the device list,
/// all of which wait on other processes. One of those reads hung a minute
/// after launch and the watchdog ended the app. The main thread must come
/// back from a check at once however long the reads take, and a hung
/// read must not pile up a check a minute behind it.
final class HealthEraTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-health-era-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAHungSettingsReadNeverHoldsTheMainThread() {
        let observations = ObservationStore(file: directory.appendingPathComponent("observations.json"),
                                            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        observations.setHealthEnabled(true)
        let health = HealthMonitor(directory: directory)
        health.observations = observations
        health.listensToTheMouse = false
        let hung = DispatchSemaphore(value: 0)
        let reads = NSLock()
        var readCount = 0
        var answered = 0
        health.readSettings = {
            reads.withLock { readCount += 1 }
            _ = hung.wait(timeout: .now() + 5)
            reads.withLock { answered += 1 }
            return InputSettings()
        }

        let started = Date()
        health.setEnabled(true)
        for minute in 1...3 { health.tick(now: started.addingTimeInterval(Double(minute) * 60)) }
        // Main came back while the read was still hung: had it waited, the
        // read would have answered first.
        XCTAssertEqual(reads.withLock { answered }, 0, "main came straight back")

        hung.signal()
        health.drainErasForTesting()
        Stage.pump()
        XCTAssertEqual(reads.withLock { readCount }, 1, "one check out at a time; the minutes behind it skipped")
        observations.flush()
        let eras = observations.healthLog.recent(days: 30, now: Date().addingTimeInterval(1)).filter { $0.kind == .era }
        XCTAssertEqual(eras.count, 1, "the check that did return is written down")
        health.setEnabled(false)
    }
}
