import Foundation
import StoicSealed
import StoicStore
import Synchronization
@testable import LodestarCore

/// Every test of a sealed record builds its keys here: a vault whose custody
/// is in memory, over a scratch directory. The real keychain is refused under
/// a test run (`VaultTests`), so a test that forgot this could not reach it.
///
/// One vault per directory for the life of the process, so two stores a test
/// opens on one directory share keys the way two launches share a keychain.
enum SealedFixture {
    private static let vaults = Mutex<[String: Vault]>([:])

    static func vault(_ directory: URL) -> Vault {
        vaults.withLock { table in
            if let known = table[directory.path] { return known }
            let made = Vault(custody: InMemoryKeyCustody(), directory: directory)
            table[directory.path] = made
            return made
        }
    }

    /// A vault of its own over `directory`, with a custody the test holds
    /// (to fail it, to lose the key), replacing any shared one.
    static func vault(_ directory: URL, custody: any KeyCustody) -> Vault {
        let made = Vault(custody: custody, directory: directory)
        vaults.withLock { $0[directory.path] = made }
        return made
    }

    /// A log in the logbook (or the health record, `.health`) of the directory it sits in.
    static func eventLog(_ file: URL, ring: Vault.RingName = .logbook) -> EventLog {
        let vault = vault(file.deletingLastPathComponent())
        return EventLog(file: file, ring: vault.ring(ring), archiveRing: vault.ring(.health))
    }

    /// What a log holds, as the text of its lines (sealed and plaintext remnants alike).
    static func text(of file: URL, ring: Vault.RingName = .logbook) -> String {
        let vault = vault(file.deletingLastPathComponent())
        return String(decoding: LineStore.read(plaintext: file, ring: vault.ring(ring), fileSystem: PosixFileSystem()).bytes,
                      as: UTF8.self)
    }
}


/// A keychain that is locked for every ring until `unlock()`: what a locked
/// login keychain says to everyone who asks, however many rings ask first.
final class LockedCustody: KeyCustody {
    private let base: InMemoryKeyCustody
    private let locked = Mutex(true)

    /// The same keys as `custody`, behind a lock.
    init(copying custody: InMemoryKeyCustody) {
        var items: [String: [UInt8]] = [:]
        for name in custody.names { items[name] = custody.contents(of: name) }
        base = InMemoryKeyCustody(items)
    }

    func unlock() { locked.withLock { $0 = false } }

    private func check() throws(CustodyError) {
        if locked.withLock({ $0 }) { throw .unavailable(.locked) }
    }

    func load(name: String) throws(CustodyError) -> [UInt8]? { try check(); return try base.load(name: name) }
    func store(_ bytes: [UInt8], name: String) throws(CustodyError) { try check(); try base.store(bytes, name: name) }
    func delete(name: String) throws(CustodyError) { try check(); try base.delete(name: name) }
}
