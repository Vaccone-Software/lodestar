import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// A stash sealed under a key that cannot be asked for is words from a crashed
/// run, left until they can be read and handed over. Nothing a draft does in
/// the meantime, a close or a new write, may be what ends them. Every stash
/// here lives in a directory of its own, under an in-memory custody.
final class DraftStashStrandedTests: XCTestCase {
    private var directory: URL!
    private var custody: InMemoryKeyCustody!
    private let words = "STRANDED-WORDS from the run that crashed"

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stranded-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        _ = vault.ring(.clipboard).keyring()
        DraftStash(directory: directory, ring: vault.ring(.clipboard), allowed: { true }).write(words)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// The next launch with the keychain locked: the stash, the key that opens it, and what it handed over.
    private func lockedLaunch() -> (stash: DraftStash, keychain: LockedCustody, ring: Vault.Ring, delivered: Delivered) {
        let keychain = LockedCustody(copying: custody)
        let ring = Vault(custody: keychain, directory: directory).ring(.clipboard)
        let delivered = Delivered()
        return (DraftStash(directory: directory, ring: ring, allowed: { true }, handOver: { delivered.add($0) }),
                keychain, ring, delivered)
    }

    private func bytes(_ stash: DraftStash) throws -> Data { try Data(contentsOf: stash.url) }

    private func fresh() -> DraftStash {
        DraftStash(directory: directory, ring: Vault(custody: custody, directory: directory).ring(.clipboard), allowed: { true })
    }

    func testACloseWhileTheKeyIsAwayLeavesTheStrandedWords() {
        let launch = lockedLaunch()
        XCTAssertEqual(launch.stash.recover(), .unavailable)
        launch.stash.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.stash.url.path), "a draft closing is not the words being recovered")
        launch.keychain.unlock()
        XCTAssertTrue(launch.ring.retry())
        XCTAssertEqual(launch.stash.recover(), .text(words), "and the key, back, opens them")
    }

    func testAWriteWhileTheKeyIsAwayLeavesTheFileAndTheKeyReturningHandsItOverOnce() throws {
        let launch = lockedLaunch()
        XCTAssertEqual(launch.stash.recover(), .unavailable)
        let before = try bytes(launch.stash)
        launch.stash.write("a new draft, half a second in")
        launch.stash.write("a new draft, a second in")
        XCTAssertEqual(try bytes(launch.stash), before, "the stranded words are not replaced")
        XCTAssertEqual(launch.delivered.all, [])
        launch.stash.keyMayHaveReturned()
        XCTAssertEqual(launch.delivered.all, [], "the key is still away: harmless, and tried again")

        launch.keychain.unlock()
        XCTAssertTrue(launch.ring.retry())
        launch.stash.keyMayHaveReturned()
        XCTAssertEqual(launch.delivered.all, [words], "handed over")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.stash.url.path), "and the file is theirs no longer")
        launch.stash.keyMayHaveReturned()
        launch.stash.write("a third draft")
        XCTAssertEqual(launch.delivered.all, [words], "once")
        XCTAssertEqual(fresh().recover(), .text("a third draft"))
    }

    func testAWriteOnceTheKeyIsBackHandsTheStrandedWordsOverAndThenWritesTheNewOnes() {
        let launch = lockedLaunch()
        XCTAssertEqual(launch.stash.recover(), .unavailable)
        launch.keychain.unlock()
        XCTAssertTrue(launch.ring.retry())
        launch.stash.write("a new draft, half a second in")
        XCTAssertEqual(launch.delivered.all, [words], "the stranded words come first, once")
        XCTAssertEqual(fresh().recover(), .text("a new draft, half a second in"), "and the new words are what a later launch recovers")
        launch.stash.write("a new draft, a second in")
        XCTAssertEqual(launch.delivered.all, [words])
    }

    func testStrandedWordsAreClearedOnceHandedOverAndTheNextCloseRemovesTheNextDraft() {
        let launch = lockedLaunch()
        XCTAssertEqual(launch.stash.recover(), .unavailable)
        launch.keychain.unlock()
        XCTAssertTrue(launch.ring.retry())
        launch.stash.keyMayHaveReturned()
        launch.stash.write("the next draft")
        launch.stash.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.stash.url.path), "no longer stranded: a close removes")
        XCTAssertEqual(launch.delivered.all, [words])
    }

    func testAResealWhileStrandedLeavesTheWordsAndOnceTheKeyIsBackHandsThemOverFirst() throws {
        let launch = lockedLaunch()
        XCTAssertEqual(launch.stash.recover(), .unavailable)
        launch.stash.write("a draft that could not be stashed")
        let before = try bytes(launch.stash)
        launch.stash.reseal()
        XCTAssertEqual(try bytes(launch.stash), before, "a compaction does not replace what it cannot read")
        XCTAssertEqual(launch.delivered.all, [])

        launch.keychain.unlock()
        XCTAssertTrue(launch.ring.retry())
        launch.stash.reseal()
        XCTAssertEqual(launch.delivered.all, [words])
        XCTAssertEqual(fresh().recover(), .text("a draft that could not be stashed"))
    }

    func testARetryWhenNothingIsStrandedDoesNothing() throws {
        let stash = fresh()
        stash.keyMayHaveReturned()
        XCTAssertEqual(stash.recover(), .text(words), "an instance that never found stranded words reads nothing and removes nothing")
    }

    func testARecoveryThatFindsTextNothingOrAnUnreadableFileLeavesTheStashNotStranded() throws {
        let text = fresh()
        XCTAssertEqual(text.recover(), .text(words))
        text.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.url.path), "the launch recovered and cleared them")
        XCTAssertEqual(text.recover(), .none)
        text.write("words")
        text.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.url.path))

        // Sealed under a key that is gone: unreadable, not unavailable.
        let vault = Vault(custody: custody, directory: directory)
        let sealed = DraftStash(directory: directory, ring: vault.ring(.clipboard), allowed: { true })
        sealed.write("sealed under an old key")
        let kept = try XCTUnwrap(vault.ring(.clipboard).held)
        let old = kept.keyIDs
        _ = try kept.rotate()
        _ = try kept.retire(ids: old)
        XCTAssertEqual(sealed.recover(), .unreadable)
        sealed.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.url.path), "unreadable is not stranded: a close removes it")
    }
}
