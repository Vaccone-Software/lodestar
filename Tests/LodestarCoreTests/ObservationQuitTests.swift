import StoicSealed
import XCTest
@testable import LodestarCore

/// A quit saves the view and nothing else waits on it: the monthly roll
/// reads every month the logs hold, and an update's relay, replaced a
/// moment after it booted, waited behind one until its successor gave up
/// at five seconds, every update.
final class ObservationQuitTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsquit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func store() -> ObservationStore {
        ObservationStore(file: directory.appendingPathComponent("observations.json"),
                         vault: Vault(custody: InMemoryKeyCustody(), directory: directory))
    }

    func testAQuitSaveNeverWaitsForARollup() {
        let store = store()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.rollupWillRun = {
            entered.signal()
            release.wait()
        }
        store.rollupSoon()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the roll is under way")

        let saved = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.flush()
            saved.signal()
        }
        XCTAssertEqual(saved.wait(timeout: .now() + 1), .success, "the quit save did not wait for the roll")
        release.signal()
    }

    /// Reading the store at launch queues no upkeep: that is the app's to
    /// start once it is the instance staying.
    func testALaunchReadQueuesNoUpkeep() {
        let store = store()
        let rolled = DispatchSemaphore(value: 0)
        store.rollupWillRun = { rolled.signal() }
        store.load(compacting: false)
        XCTAssertEqual(rolled.wait(timeout: .now() + 0.5), .timedOut, "no roll from a launch read")
        store.tendSoon()
        XCTAssertEqual(rolled.wait(timeout: .now() + 5), .success, "upkeep rolls when it is asked for")
    }
}
