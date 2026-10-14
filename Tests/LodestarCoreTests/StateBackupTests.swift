import XCTest
@testable import LodestarCore

/// The state store's last-known-good copy is replaced, never removed and
/// remade, so there is no instant at which a crash finds no backup.
final class StateBackupTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("state.json") }
    private var backup: URL { directory.appendingPathComponent("state.json.bak") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-statebak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testALoadLeavesABackupIdenticalToTheStateAndNothingElse() throws {
        let first = StateStore(file: file)
        first.save()
        let second = StateStore(file: file)
        second.load()
        XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: file))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["state.json", "state.json.bak"], "no temporary left behind")
    }

    func testTheBackupFollowsTheStateAtTheNextBoot() throws {
        let store = StateStore(file: file)
        store.save()
        store.load()
        let stale = try Data(contentsOf: backup)
        // Still a valid state, but not the same bytes.
        try (try Data(contentsOf: file) + Data("\n\n".utf8)).write(to: file)
        StateStore(file: file).load()
        XCTAssertNotEqual(try Data(contentsOf: backup), stale)
        XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: file))
    }

    func testThereIsNeverAMomentWithoutABackupWhileItIsRefreshed() throws {
        let seed = StateStore(file: file)
        seed.save()
        seed.load()
        var missing = 0
        let stop = NSLock()
        var done = false
        let watcher = DispatchQueue(label: "watch")
        let finished = expectation(description: "watcher")
        watcher.async {
            while true {
                stop.lock(); let over = done; stop.unlock()
                if over { break }
                if !FileManager.default.fileExists(atPath: self.backup.path) { missing += 1 }
            }
            finished.fulfill()
        }
        for _ in 0..<60 { StateStore(file: file).load() }
        stop.lock(); done = true; stop.unlock()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(missing, 0, "removeItem-then-copyItem left a window with no backup")
    }
}
