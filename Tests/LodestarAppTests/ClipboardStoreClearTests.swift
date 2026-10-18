import StoicApple
import StoicSealed
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Clearing the history destroys the ring and removes the files, and the
/// command-line clear does it without opening anything. Pins go with the
/// rest, as they always have.
final class ClipboardStoreClearTests: XCTestCase {
    private var directory: URL!
    private var custody: InMemoryKeyCustody!
    private var vault: Vault!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-clear-\(UUID().uuidString)", isDirectory: true)
        custody = InMemoryKeyCustody()
        vault = SealedFixture.vault(directory, custody: custody)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fill(_ store: ClipboardStore, count: Int = 40) {
        for n in 0..<count {
            let data = Data(repeating: UInt8(n), count: 20_000)
            store.record(id: ClipboardStore.identity(for: data), kind: .text,
                         items: [.init(plain: data, natives: [("public.html", data)])],
                         imageData: nil, preview: "clip \(n)", sourceBundleID: nil, sourceAppName: nil)
        }
        store.flushIO()
    }

    func testClearingAndWaitingLeavesNothingOnDiskAndNoKeyWhenItReturns() throws {
        let store = SealedFixture.clipboardStore(directory)
        fill(store)
        _ = store.pin(store.clips[3].id)
        store.saveNow()
        store.flushIO()
        XCTAssertEqual(store.clips.count, 40)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"])

        XCTAssertTrue(store.clearAllAndWait())

        // Nothing here waits for the store: this is what a process that
        // exits at once leaves behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], "no v2, no items, no index")
        XCTAssertEqual(custody.names, [], "the ring is destroyed")
        XCTAssertEqual(store.clips.count, 0)
        XCTAssertEqual(store.pins.count, 0, "pins go with the rest")
        // A later launch finds nothing, and the next copy makes a new ring.
        let again = SealedFixture.clipboardStore(directory)
        XCTAssertEqual(again.clips.count, 0)
        fill(again, count: 2)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"])
        again.close()
    }

    func testACopyAfterAClearOpensANewHistoryAndIsKept() throws {
        let store = SealedFixture.clipboardStore(directory)
        fill(store, count: 3)
        store.clearAllAndWait()
        XCTAssertEqual(custody.names, [], "no ring until something is copied")
        fill(store, count: 1)
        store.waitUntilOpen()
        store.flushIO()
        XCTAssertEqual(store.clips.count, 1, "queued while it opened, applied after")
        store.close()
        XCTAssertEqual(SealedFixture.clipboardStore(directory).clips.count, 1)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"])
    }

    func testTheCommandLineClearWorksOnTheFilesAndTheKeyWithoutOpeningTheHistory() throws {
        let store = SealedFixture.clipboardStore(directory)
        fill(store, count: 5)
        store.close()
        XCTAssertEqual(ClipboardStore.clearOnDisk(root: directory, vault: vault), .cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(custody.names, [])
    }

    func testNothingIsClearedWhileTheKeyCannotBeAskedFor() throws {
        let store = SealedFixture.clipboardStore(directory)
        fill(store, count: 5)
        store.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let locked = LockedCustody(copying: custody)
        let lockedVault = SealedFixture.vault(directory, custody: locked)
        guard case .refused(let why) = ClipboardStore.clearOnDisk(root: directory, vault: lockedVault) else { return XCTFail() }
        XCTAssertTrue(why.contains("locked"), why)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)

        // And the running store, paused, refuses too.
        let paused = ClipboardStore(root: directory, vault: lockedVault)
        paused.waitUntilOpen()
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.clearAll())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }
}
