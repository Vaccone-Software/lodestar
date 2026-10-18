import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The words of a draft in flight are sealed under the clipboard ring, written
/// only while its key is ready, sealed again when a compaction retires the old
/// key, and read from either form.
final class DraftStashTests: XCTestCase {
    private var directory: URL!
    private var custody: InMemoryKeyCustody!
    private var vault: Vault!
    private var allowed = true

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        custody = InMemoryKeyCustody()
        vault = Vault(custody: custody, directory: directory)
        allowed = true
        _ = vault.ring(.clipboard).keyring()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stash(_ vault: Vault? = nil, allowed gate: @escaping @Sendable () -> Bool = { true }) -> DraftStash {
        DraftStash(directory: directory, ring: (vault ?? self.vault).ring(.clipboard), allowed: gate)
    }

    func testTheWordsAreSealedOnDiskAndComeBackAfterACrash() throws {
        let words = "DRAFT-WORDS-IN-FLIGHT the quick brown fox"
        let first = stash()
        first.write(words)
        let bytes = try Data(contentsOf: first.url)
        XCTAssertNil(bytes.range(of: Data("DRAFT-WORDS".utf8)), "no plaintext on disk")
        XCTAssertTrue(Sealing.isSealed([UInt8](bytes)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? Int, 0o600)
        // The process dies; the next launch recovers.
        XCTAssertEqual(stash().recover(), .text(words))
    }

    func testACleanCloseRemovesItEvenWhileTheKeyIsUnavailable() throws {
        let first = stash()
        first.write("words")
        let locked = Vault(custody: LockedCustody(copying: custody), directory: directory)
        let second = stash(locked)
        XCTAssertEqual(second.recover(), .unavailable, "sealed, and the key cannot be asked: left, not removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        second.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path), "a stale stash must not outlive a clean close")
        XCTAssertEqual(stash().recover(), .none)
    }

    func testNothingIsWrittenWhileTheHistorysKeyIsNotReady() throws {
        let gated = stash(allowed: { false })
        gated.write("these words are not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gated.url.path), "no plaintext fallback, and no sealed file without a key")
        XCTAssertEqual(stash().recover(), .none)
    }

    func testAnOlderBuildsPlaintextStashIsRecoveredAndRemoved() throws {
        let file = directory.appendingPathComponent(DraftStash.name)
        try Data("legacy plaintext words".utf8).write(to: file)
        let s = stash()
        XCTAssertEqual(s.recover(), .text("legacy plaintext words"))
        s.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSealedAgainAfterACompactionRetiresTheKeyItWasSealedUnder() throws {
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        let s = stash()
        s.write("the words in flight")
        XCTAssertEqual(stash().recover(), .text("the words in flight"))
        // A compaction of the history: the ring rotates and the old key goes.
        let old = ring.keyIDs
        _ = try ring.rotate()
        _ = try ring.retire(ids: old)
        XCTAssertEqual(stash().recover(), .unreadable, "sealed under a key that is gone")
        s.reseal()
        XCTAssertEqual(stash().recover(), .text("the words in flight"), "and again under the new one")
    }
}
