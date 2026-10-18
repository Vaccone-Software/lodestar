import StoicApple
import StoicSealed
import StoicSealedKeychain
import StoicStore
import XCTest
@testable import LodestarCore

/// What each state of a key means for the data it seals. The safety core:
/// a key that cannot be asked for is never a key that is gone, and nothing
/// is ever deleted because a read failed.
final class VaultTests: XCTestCase {
    private var directory: URL!
    private let fs = PosixFileSystem()
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func press(_ seconds: Double) -> KeyPress {
        KeyPress(down: Date(timeIntervalSince1970: 1_700_000_000 + seconds), hold: 0.09, hand: .left, kind: .letter,
                 shift: false, chord: false, gesture: false, lens: false, repeated: false, keyboardType: 40)
    }

    private func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    /// A sealed health record under `custody`: one day of two presses.
    @discardableResult
    private func sealedHealth(custody: InMemoryKeyCustody) -> String {
        let vault = Vault(custody: custody, directory: directory)
        let store = KeyStore(directory: directory.appendingPathComponent("keys"), installID: "i", timeZone: utc,
                             ring: vault.ring(.health))
        store.append(press(0))
        store.append(press(1))
        store.flushSync()
        store.close()
        return KeyStore.day(of: press(0).down, calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }())
    }

    // MARK: The real keychain

    func testTheRealKeychainIsRefusedUnderATestRun() {
        XCTAssertThrowsError(try Vault.system(directory: directory)) { error in
            XCTAssertTrue("\(error)".contains("test run"), "\(error)")
        }
    }

    func testTheKeychainAdapterRefusesAnyCallUnderATestRun() {
        let custody = SecretStoreCustody(TestGuardedSecrets(InMemorySecretStore()))
        XCTAssertThrowsError(try custody.load(name: "x"))
        XCTAssertThrowsError(try custody.store([1], name: "x"))
        XCTAssertThrowsError(try custody.delete(name: "x"))
    }

    // MARK: Present, missing, unavailable

    func testAMissingRingWithNothingSealedIsMade() {
        let custody = InMemoryKeyCustody()
        let ring = Vault(custody: custody, directory: directory).ring(.health)
        XCTAssertNotNil(ring.keyring())
        XCTAssertEqual(ring.availability, .ready)
        XCTAssertEqual(custody.names, ["lodestar.ring.health"], "the health ring, and no other")
    }

    func testSettleMakesNoRingWhereNothingIsSealed() {
        let custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        vault.settle()
        XCTAssertTrue(custody.names.isEmpty, "the first ring is made by the first thing that has something to seal")
        XCTAssertEqual(vault.ring(.health).availability, .unopened)
    }

    func testAnUnavailableCustodyPausesAndCreatesNothing() {
        let reasons: [CustodyError.Reason] = [.locked, .accessDenied, .userCancelled, .interactionNotAllowed, .serviceUnavailable]
        for reason in reasons {
            let custody = InMemoryKeyCustody()
            custody.failNext(with: .unavailable(reason), on: .load)
            let ring = Vault(custody: custody, directory: directory).ring(.health)
            XCTAssertNil(ring.keyring(), "\(reason)")
            XCTAssertEqual(ring.availability, .paused(.custody(.unavailable(reason))))
            XCTAssertTrue(custody.names.isEmpty, "a ring that may exist is never replaced by a new one")
            XCTAssertFalse(custody.calls.contains { $0.operation == .store }, "\(reason): nothing was written")
            // Paused for the launch: the custody works now, and it is not asked again.
            XCTAssertNil(ring.keyring())
            XCTAssertTrue(custody.names.isEmpty)
        }
    }

    func testOnlyALockCanBeRetriedARefusalCannot() {
        for (reason, retryable) in [(CustodyError.Reason.locked, true), (.interactionNotAllowed, true),
                                    (.serviceUnavailable, true), (.accessDenied, false), (.userCancelled, false)] {
            let custody = InMemoryKeyCustody()
            custody.failNext(with: .unavailable(reason), on: .load)
            let ring = Vault(custody: custody, directory: directory).ring(.logbook)
            XCTAssertNil(ring.keyring())
            XCTAssertEqual(ring.retry(), retryable, "\(reason)")
            XCTAssertEqual(ring.keyring() != nil, retryable, "\(reason)")
        }
    }

    func testADamagedRingIsLeftAsItIsAndPauses() {
        let custody = InMemoryKeyCustody(["lodestar.ring.health": [1, 2, 3]])
        let ring = Vault(custody: custody, directory: directory).ring(.health)
        XCTAssertNil(ring.keyring())
        guard case .paused(.unusableRing) = ring.availability else { return XCTFail("\(ring.availability)") }
        XCTAssertEqual(custody.contents(of: "lodestar.ring.health"), [1, 2, 3])
    }

    // MARK: A lost health key

    func testAHealthKeyThatIsGoneRefusesAndDeletesNothing() throws {
        sealedHealth(custody: InMemoryKeyCustody())
        let before = names("keys")
        XCTAssertEqual(before.count, 1)

        let custody = InMemoryKeyCustody() // the key did not travel
        let vault = Vault(custody: custody, directory: directory)
        vault.settle()
        XCTAssertEqual(vault.ring(.health).availability, .keyLost)
        XCTAssertNil(vault.ring(.health).keyring())
        XCTAssertTrue(custody.names.isEmpty, "no new ring over data the old one sealed")
        XCTAssertEqual(names("keys"), before, "nothing deleted")

        // A store on the refused ring drops its presses and writes nothing.
        let installAsked = Locked(false)
        let store = KeyStore(directory: directory.appendingPathComponent("keys"),
                             installID: { installAsked.set(true); return "i" }(), timeZone: utc, ring: vault.ring(.health))
        _ = installAsked
        store.append(press(5))
        store.flushSync()
        XCTAssertEqual(store.dropped, 1)
        XCTAssertEqual(names("keys"), before)
        XCTAssertFalse(RecordStatus.healthLines(RecordStatus.health(vault: vault, directory: directory)).isEmpty)
        XCTAssertTrue(RecordStatus.healthLines(RecordStatus.health(vault: vault, directory: directory))[0].contains("THE KEY IS GONE"))
    }

    func testStartingANewHealthRecordMovesTheFilesAsideAndMakesAKey() throws {
        sealedHealth(custody: InMemoryKeyCustody())
        let custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        vault.settle()
        let ring = vault.ring(.health)
        let folder = try XCTUnwrap(ring.startNewRecord(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(folder, "health-unreadable-2023-11-14")
        XCTAssertEqual(names("keys"), [], "the folder is where the unreadable day went")
        XCTAssertEqual(names(folder + "/keys").count, 1, "moved, never deleted")
        XCTAssertNotNil(ring.keyring())
        XCTAssertEqual(custody.names, ["lodestar.ring.health"])
        // Only an explicit act from the refused state: a ready ring does not move anything.
        XCTAssertNil(ring.startNewRecord())
    }

    func testStartingANewRecordTwiceInADayMakesTwoFolders() throws {
        for _ in 0..<2 {
            sealedHealth(custody: InMemoryKeyCustody())
            let vault = Vault(custody: InMemoryKeyCustody(), directory: directory)
            vault.settle()
            XCTAssertNotNil(vault.ring(.health).startNewRecord(now: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("health-unreadable") }.count, 2)
    }

    // MARK: A lost logbook key

    func testALogbookKeyThatIsGoneMovesTheFilesAsideAndStartsFresh() throws {
        let first = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let log = EventLog(file: directory.appendingPathComponent("events.jsonl"), ring: first.ring(.logbook))
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 1_700_000_000), kind: .verb)
        event.verb = "graph"
        log.append(event)
        log.flush()
        log.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sj").path))
        // And a plaintext file an earlier build wrote, which the lost key says nothing about.
        try Data("plain\n".utf8).write(to: directory.appendingPathComponent("observations.json"))

        let custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        vault.settle()
        let ring = vault.ring(.logbook)
        XCTAssertEqual(ring.availability, .ready, "a logbook is derived: it starts again")
        XCTAssertEqual(custody.names, ["lodestar.ring.logbook"])
        let aside = try XCTUnwrap(ring.movedAside)
        XCTAssertTrue(aside.hasPrefix("logbook-unreadable-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(aside).appendingPathComponent("events.sj").path),
                      "moved, not deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sj").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("observations.json").path),
                      "plaintext is not what the lost key sealed")
        let fresh = EventLog(file: directory.appendingPathComponent("events.jsonl"), ring: ring)
        XCTAssertTrue(fresh.readAll().isEmpty)
        fresh.append(event)
        fresh.flush()
        XCTAssertEqual(fresh.readAll().count, 1)
        XCTAssertTrue(RecordStatus.logbookLines(RecordStatus.logbook(vault: vault, directory: directory)).joined().contains("logbook-unreadable"))
    }

    // MARK: Destroying

    func testDestroyingARingShredsItAndTheNextWriteMakesANewOne() throws {
        let custody = InMemoryKeyCustody()
        let ring = Vault(custody: custody, directory: directory).ring(.health)
        let key = try XCTUnwrap(ring.keyring()).keyIDs
        XCTAssertTrue(ring.destroy())
        XCTAssertTrue(custody.names.isEmpty)
        XCTAssertEqual(ring.availability, .unopened)
        let next = try XCTUnwrap(ring.keyring())
        XCTAssertNotEqual(next.keyIDs, key, "a new key, not the old one")
    }

    // MARK: Erasing every key (uninstall --purge)

    func testErasingEveryKeyRemovesEachRingsItemAndNothingElse() throws {
        let custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        for name in Vault.RingName.allCases { XCTAssertNotNil(vault.ring(name).keyring(), "\(name)") }
        custody.put([9], name: "someone-elses-item")
        XCTAssertEqual(custody.names.filter { $0.hasPrefix("lodestar.ring.") }.count, Vault.RingName.allCases.count)

        let result = vault.eraseAllKeys()

        XCTAssertEqual(result.map(\.ring), Vault.RingName.allCases)
        XCTAssertTrue(result.allSatisfy(\.erased), "\(result)")
        XCTAssertEqual(custody.names, ["someone-elses-item"], "every ring is gone and only the rings")
        for name in Vault.RingName.allCases {
            XCTAssertEqual(vault.ring(name).availability, .unopened, "\(name)")
            XCTAssertNil(vault.ring(name).held, "\(name): the key is not held on after it is deleted")
        }
    }

    func testTheItemsAreNamedByTheRingsSoNoRingCanBeLeftOut() {
        XCTAssertEqual(Set(Vault.RingName.allCases.map(\.custodyName)),
                       ["lodestar.ring.health", "lodestar.ring.logbook", "lodestar.ring.clipboard", "lodestar.ring.state"],
                       "a ring added here is a keychain item the purge must know")
    }

    func testErasingWhereNothingWasMadeSucceeds() {
        let custody = InMemoryKeyCustody()
        let result = Vault(custody: custody, directory: directory).eraseAllKeys()
        XCTAssertTrue(result.allSatisfy(\.erased))
        XCTAssertEqual(custody.calls.filter { $0.operation == .delete }.count, Vault.RingName.allCases.count)
    }

    func testADamagedRingItemIsErasedWithoutBeingOpened() {
        let custody = InMemoryKeyCustody(["lodestar.ring.logbook": [1, 2, 3]])
        let result = Vault(custody: custody, directory: directory).eraseAllKeys()
        XCTAssertTrue(result.allSatisfy(\.erased))
        XCTAssertTrue(custody.names.isEmpty)
        XCTAssertTrue(custody.calls.allSatisfy { $0.operation == .delete }, "nothing was loaded: a ring that will not open is still removed")
    }

    func testAKeyTheKeychainWillNotDeleteIsReportedAndTheOthersAreStillErased() throws {
        let custody = InMemoryKeyCustody()
        let vault = Vault(custody: custody, directory: directory)
        for name in Vault.RingName.allCases { XCTAssertNotNil(vault.ring(name).keyring()) }
        // The first delete is refused, as a keychain the person said no to would.
        custody.failNext(with: .unavailable(.accessDenied), on: .delete)

        let result = vault.eraseAllKeys()

        let failed = result.filter { !$0.erased }
        XCTAssertEqual(failed.map(\.ring), [Vault.RingName.allCases[0]], "\(result)")
        XCTAssertTrue(try XCTUnwrap(failed.first?.failure).contains("refused access"), "the reason is in the person's words")
        XCTAssertEqual(custody.names, [Vault.RingName.allCases[0].custodyName], "the others did not wait on it")
        XCTAssertNotNil(vault.ring(Vault.RingName.allCases[0]).held, "a key that is still in the keychain is still held")
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    var current: Value { lock.lock(); defer { lock.unlock() }; return value }
}
