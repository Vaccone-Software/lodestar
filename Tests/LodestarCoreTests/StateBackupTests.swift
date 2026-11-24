import XCTest
@testable import LodestarCore

/// The state store's last-known-good copy is replaced, never removed and
/// remade, so there is no instant at which a crash finds no backup. Both are
/// sealed: the backup opens to the same bytes as the state, though the
/// ciphertexts differ (a fresh nonce each).
final class StateBackupTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("state.json") }
    private var sealed: URL { SealedFixture.sealedState(file) }
    private var backup: URL { sealed.appendingPathExtension("bak") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-statebak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testALoadLeavesABackupThatOpensToTheStateAndNothingElse() throws {
        let first = SealedFixture.stateStore(file)
        first.save()
        let second = SealedFixture.stateStore(file)
        second.load()
        XCTAssertEqual(try XCTUnwrap(SealedFixture.openedState(backup)), try XCTUnwrap(SealedFixture.openedState(sealed)))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["state.sealed", "state.sealed.bak"], "no temporary left behind, and no plaintext")
    }

    func testTheBackupFollowsTheStateAtTheNextBoot() throws {
        let store = SealedFixture.stateStore(file)
        store.save()
        store.load()
        let stale = try XCTUnwrap(SealedFixture.openedState(backup))
        // Still a valid state, but not the same bytes.
        let grown = try XCTUnwrap(SealedFixture.openedState(sealed)) + [0x0A, 0x0A]
        XCTAssertEqual(StateFiles(plain: file, ring: SealedFixture.vault(directory).ring(.state),
                                  fileSystem: OwnerOnly.fileSystem).write(grown), .written)
        _ = SealedFixture.stateStore(file)
        XCTAssertNotEqual(try XCTUnwrap(SealedFixture.openedState(backup)), stale)
        XCTAssertEqual(try XCTUnwrap(SealedFixture.openedState(backup)), try XCTUnwrap(SealedFixture.openedState(sealed)))
    }

    func testThereIsNeverAMomentWithoutABackupWhileItIsRefreshed() throws {
        let seed = SealedFixture.stateStore(file)
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
        for _ in 0..<60 { _ = SealedFixture.stateStore(file) }
        stop.lock(); done = true; stop.unlock()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(missing, 0, "removeItem-then-copyItem left a window with no backup")
    }
}
