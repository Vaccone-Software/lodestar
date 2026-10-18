import Foundation
import Stoic
import StoicApple
import StoicSealed
import StoicSealedKeychain
import StoicStore
import Synchronization

/// Where the keys of the sealed records live, and what each state of them
/// means for the data.
///
/// The health record, the logbook, the clipboard history and the state file
/// are sealed at rest (`StoicSealed`,
/// design/24 of Stoic): AES-256-GCM under a key ring each, the rings kept in
/// the **login keychain** (Lodestar is Developer ID signed with no
/// application identifier, so the data-protection keychain refuses it with
/// `missingEntitlement`). A ring is never beside the data it seals, and it
/// follows the person's backups the way the login keychain does.
///
/// The one rule: **a key that cannot be asked for is not a key that is
/// gone.** A locked keychain, a refused prompt, a differently signed build
/// that the system asks about and the person turns down, all leave the ring
/// where it is. What each state does:
///
/// - **ready**: the ring is held; the store reads and writes sealed files.
/// - **paused** (custody unavailable, or the ring is damaged or newer than
///   this build): *for this launch* the store reads nothing, writes nothing
///   sealed, deletes nothing and migrates nothing. It is tried again at the
///   next launch (and when the screen unlocks, if the keychain was merely
///   locked). Never a reason to create a ring: a new one would orphan
///   everything sealed under the real one.
/// - **no ring and nothing sealed**: the first run, or the day after a
///   clear. The ring is made.
/// - **no ring and sealed files exist**: the key is gone. For the *health
///   record*, which nothing can recompute, the store refuses (`keyLost`),
///   deletes nothing, and says so until the person asks to start a new
///   record, which moves the unreadable files into a dated folder (never
///   deletes them) and makes a new ring. For the *logbook*, which is derived
///   behavioral data, the unreadable files are moved aside the same way and
///   a new ring is made, with one log line and a note in `diagnose`. For the
///   *clipboard history* the store applies the same policy itself, before it
///   asks for a key to write with (`SealedClipboard`): `v2/` moves into
///   `clipboard-unreadable-YYYY-MM-DD/` (inside the clipboard folder), a new
///   ring is made, and the person is told once. For the *state file*
///   (breaths, parked windows, frecency: `StateStore`) the unreadable files
///   are moved aside the same way (`state-unreadable-YYYY-MM-DD/`), a new
///   ring is made, and the store says so once (`bootWarning`); breaths are
///   the person's own, so nothing is deleted, but a store that refused until
///   asked would leave the walk, the editor's consent and every address
///   asking again.
///
/// Tests and a test run's scratch home use `InMemoryKeyCustody`; the real
/// keychain is refused under `TestRun` (`Vault.system`).
public final class Vault: Sendable {
    /// One key ring per record. A ring is the unit of destruction: clearing
    /// the health record destroys the health ring and nothing else.
    public enum RingName: String, CaseIterable, Sendable {
        case health
        case logbook
        /// The clipboard history's index journal, and the draft in flight. The
        /// blobs and thumbnails are sealed under keys of their own, which live
        /// inside the sealed index records (`SealedClipboard`).
        case clipboard
        /// `state.sealed` and its backup: breaths, parked windows, frecency,
        /// the walk and the meetings' record. A ring of its own, not the
        /// logbook's: the ring is the unit of destruction, and *deleting the
        /// logbook destroys its key*, which would make the breaths unreadable
        /// with it.
        case state

        /// The custody item this ring is kept in.
        public var custodyName: String { "lodestar.ring.\(rawValue)" }
    }

    /// The service the login keychain files the rings under.
    public static let keychainService = "com.vaccone.lodestar"

    public let directory: URL
    public let fileSystem: any FileSystem
    private let rings: [RingName: Ring]

    public init(custody: any KeyCustody, directory: URL, fileSystem: any FileSystem = OwnerOnly.fileSystem) {
        self.directory = directory
        self.fileSystem = fileSystem
        var made: [RingName: Ring] = [:]
        for name in RingName.allCases {
            made[name] = Ring(name: name, custody: custody, directory: directory.path, fileSystem: fileSystem)
        }
        rings = made
    }

    /// The login keychain, for the app and its command-line tool. Refused
    /// under a test run: a test that reached the real keychain could create,
    /// read or destroy the key of a person's actual record.
    public static func system(directory: URL = Paths.data) throws -> Vault {
        guard !TestRun.active else { throw VaultError.realKeychainUnderTest }
        let secrets = KeychainSecretStore(loginKeychainService: keychainService)
        return Vault(custody: SecretStoreCustody(TestGuardedSecrets(secrets)), directory: directory)
    }

    public func ring(_ name: RingName) -> Ring { rings[name]! }

    /// What `eraseAllKeys` did to one ring's item.
    public struct Erasure: Sendable, Equatable {
        public let ring: RingName
        /// Nil when the item is gone (or there was none); otherwise why it
        /// is still in the keychain.
        public let failure: String?

        public var erased: Bool { failure == nil }
    }

    /// Delete every key Lodestar keeps in the custody, one item per ring,
    /// for `lodestar uninstall --purge`: the data a key opens is being
    /// removed, so the key has no use left, and a Mac that has had Lodestar
    /// removed should not keep a secret of its own in the keychain. Goes
    /// straight to the custody and opens no ring, so a damaged or newer ring
    /// is removed too. **Not for the main thread** (the keychain may wait).
    ///
    /// Every ring is tried whatever the others did; a ring the custody would
    /// not delete is named in the result, never skipped silently. Deleting an
    /// item that is not there is a success.
    public func eraseAllKeys() -> [Erasure] {
        RingName.allCases.map { Erasure(ring: $0, failure: ring($0).erase()) }
    }

    /// Decide every ring's state, off the main thread (`Ring.settle`).
    public func settle() {
        for name in RingName.allCases where name != .clipboard { ring(name).settle() }
    }

    // MARK: - A ring

    /// One ring of the vault: lazily opened, remembered for the launch.
    public final class Ring: Sendable {
        public enum Availability: Sendable, Equatable {
            /// Nobody has asked for the key yet.
            case unopened
            case ready
            /// The custody cannot be asked, or the ring cannot be used:
            /// nothing is read, written, deleted or migrated until the next
            /// launch (or `retry`, when the reason was a lock).
            case paused(Pause)
            /// No ring, and sealed files that need one. Health only: refused
            /// until the person starts a new record.
            case keyLost
        }

        public enum Pause: Sendable, Equatable {
            case custody(CustodyError)
            case unusableRing(String)

            /// Whether asking again could change the answer without the
            /// person doing something: a lock lifts, a refusal does not.
            public var retryable: Bool {
                switch self {
                case .custody(let error): error.retryDecision == .retry
                case .unusableRing: false
                }
            }

            public var words: String {
                switch self {
                case .custody(.unavailable(.locked)): "the login keychain is locked"
                case .custody(.unavailable(.accessDenied)): "the login keychain refused access"
                case .custody(.unavailable(.userCancelled)): "the keychain prompt was cancelled"
                case .custody(.unavailable(.interactionNotAllowed)): "the keychain cannot ask right now"
                case .custody(.unavailable(.serviceUnavailable)): "the keychain did not answer"
                case .custody(let other): "the keychain failed (\(other))"
                case .unusableRing(let why): why
                }
            }
        }

        public let name: RingName
        private let custody: any KeyCustody
        private let directory: String
        private let fileSystem: any FileSystem

        private struct State {
            var availability = Availability.unopened
            var keyring: Keyring?
            /// Where unreadable logbook (or state) files were moved when the
            /// key was missing, for `diagnose`.
            var movedAside: String?
            var loggedPause = false
        }

        private let state = Mutex(State())
        /// Serialises the slow part (the custody may prompt) without holding
        /// the state lock, so a reader of `availability` never waits on a
        /// prompt.
        private let opening = Mutex<Void>(())

        fileprivate init(name: RingName, custody: any KeyCustody, directory: String, fileSystem: any FileSystem) {
            self.name = name
            self.custody = custody
            self.directory = directory
            self.fileSystem = fileSystem
        }

        public var availability: Availability { state.withLock { $0.availability } }

        /// Where the unreadable logbook (or state) went when its key was missing.
        public var movedAside: String? { state.withLock { $0.movedAside } }

        // MARK: Asking

        /// The ring to write with, made if this is the first run. Nil when
        /// paused or refused. **Not for the main thread**: the first call
        /// may wait on a keychain prompt.
        public func keyring() -> Keyring? {
            open(.write)
        }

        /// The ring to read with, never made and never acted on: a reader
        /// (the command line, a report) must not create a key or move a
        /// file. Nil when there is none, or paused.
        public func existing() -> Keyring? {
            open(.read)
        }

        /// Decide the key's state at launch, off the main thread: ask the
        /// custody once, and apply the policy for a ring that is missing
        /// while sealed files need it (see the type's note). Makes no ring
        /// where there is nothing sealed: the first ring is made by the first
        /// thing that has something to seal.
        public func settle() {
            _ = open(.settle)
        }

        /// The ring if it is already held, without asking the custody.
        public var held: Keyring? { state.withLock { $0.keyring } }

        private enum Mode { case read, settle, write }

        private func open(_ mode: Mode) -> Keyring? {
            if let held { return held }
            return opening.withLock { _ -> Keyring? in
                switch availability {
                case .ready: return held
                case .paused, .keyLost: return nil
                case .unopened: break
                }
                do throws(KeyringError) {
                    let opened = try Keyring.open(name: name.custodyName, custody: custody, ifMissing: .fail)
                    become(.ready, keyring: opened.keyring)
                    return opened.keyring
                } catch {
                    switch error {
                    case .missing:
                        guard mode != .read else { return nil }
                        return missing(creatingIfEmpty: mode == .write)
                    case .custody(let reason):
                        pause(.custody(reason))
                    case .corrupt:
                        pause(.unusableRing("the \(name.rawValue) key ring in the keychain is damaged and was left as it is"))
                    case .unsupportedVersion:
                        pause(.unusableRing("the \(name.rawValue) key ring in the keychain is from a newer Lodestar and was left as it is"))
                    default:
                        pause(.unusableRing("the \(name.rawValue) key ring could not be opened (\(error))"))
                    }
                    return nil
                }
            }
        }

        /// No ring is in the custody (it answered "nothing there"). Decide
        /// by the data, never by the custody's silence.
        private func missing(creatingIfEmpty: Bool) -> Keyring? {
            let sealed = RecordFiles.sealed(of: name, in: directory, fileSystem: fileSystem)
            if sealed.isEmpty {
                return creatingIfEmpty ? created() : nil
            }
            switch name {
            case .health, .clipboard:
                become(.keyLost, keyring: nil)
                Log.error("vault: the \(name.rawValue) key is gone and \(sealed.count) sealed files need it — paused, nothing deleted",
                          ["ring": name.rawValue, "files": sealed.count])
                return nil
            case .logbook, .state:
                let folder = "\(name.rawValue)-unreadable"
                let moved = RecordFiles.moveAside(sealed, in: directory, folder: folder, fileSystem: fileSystem)
                state.withLock { $0.movedAside = moved }
                Log.error("vault: the \(name.rawValue) key is gone — \(sealed.count) sealed files moved aside, starting a new \(name == .state ? "state" : "logbook")",
                          ["ring": name.rawValue, "files": sealed.count, "folder": moved ?? "(could not move)"])
                guard moved != nil else {
                    // Nothing was moved: do not make a ring over files
                    // that still need the old one.
                    become(.keyLost, keyring: nil)
                    return nil
                }
                return created()
            }
        }

        private func created() -> Keyring? {
            do throws(KeyringError) {
                let opened = try Keyring.open(name: name.custodyName, custody: custody, ifMissing: .create)
                become(.ready, keyring: opened.keyring)
                return opened.keyring
            } catch {
                if case .custody(let reason) = error {
                    pause(.custody(reason))
                } else {
                    pause(.unusableRing("a \(name.rawValue) key ring could not be made (\(error))"))
                }
                return nil
            }
        }

        private func become(_ availability: Availability, keyring: Keyring?) {
            state.withLock {
                $0.availability = availability
                $0.keyring = keyring
            }
        }

        private func pause(_ reason: Pause) {
            let first = state.withLock { state -> Bool in
                state.availability = .paused(reason)
                state.keyring = nil
                defer { state.loggedPause = true }
                return !state.loggedPause
            }
            if first {
                Log.error("vault: the \(name.rawValue) record is paused for this launch — \(reason.words); nothing is read, written or deleted",
                          ["ring": name.rawValue])
            }
        }

        // MARK: Changing

        /// Ask again after a pause whose reason can lift (a locked keychain
        /// that has been unlocked). A refusal stays refused until the next
        /// launch. True when the state went back to unopened.
        @discardableResult
        public func retry() -> Bool {
            state.withLock { state in
                guard case .paused(let reason) = state.availability, reason.retryable else { return false }
                state.availability = .unopened
                state.loggedPause = false
                return true
            }
        }

        /// The key is destroyed (`Keyring.destroy`): everything sealed under
        /// it is unreadable for ever. Done after the files are removed, as the
        /// last step of clearing a record; the next write makes a new ring.
        /// False when the custody could not be asked, in which case the old
        /// key stays where it is (harmless: no data is left under it).
        @discardableResult
        public func destroy() -> Bool {
            opening.withLock { _ -> Bool in
                let ring = held
                state.withLock { $0 = State(availability: .unopened, keyring: nil, movedAside: nil, loggedPause: false) }
                if let ring {
                    do throws(KeyringError) {
                        try ring.destroy()
                        return true
                    } catch {
                        Log.warning("vault: the \(name.rawValue) key could not be destroyed (\(error)) — left in the keychain",
                                    ["ring": name.rawValue])
                        return false
                    }
                }
                // Not held: ask for it, to destroy it. Never create one to do so.
                do throws(KeyringError) {
                    let opened = try Keyring.open(name: name.custodyName, custody: custody, ifMissing: .fail)
                    try opened.keyring.destroy()
                    return true
                } catch {
                    if case .missing = error { return true }
                    Log.warning("vault: the \(name.rawValue) key could not be destroyed (\(error)) — left in the keychain",
                                ["ring": name.rawValue])
                    return false
                }
            }
        }

        /// The ring's item is deleted from the custody without opening it,
        /// whatever state it is in (`Vault.eraseAllKeys`). Nil when it is
        /// gone or was never there; otherwise the reason it is not. The ring
        /// is forgotten in this process either way it succeeds: a failed
        /// delete leaves the held key and the state as they were.
        func erase() -> String? {
            opening.withLock { _ -> String? in
                do throws(CustodyError) {
                    try custody.delete(name: name.custodyName)
                } catch {
                    Log.warning("vault: the \(name.rawValue) key could not be deleted (\(error)) — left in the keychain",
                                ["ring": name.rawValue])
                    return "\(Pause.custody(error).words)"
                }
                state.withLock { $0 = State(availability: .unopened, keyring: nil, movedAside: nil, loggedPause: false) }
                return nil
            }
        }

        /// The person's explicit choice after the health key was lost: the
        /// sealed files that nothing can open move into
        /// `health-unreadable-YYYY-MM-DD/` (never deleted), and the next
        /// write makes a new ring. Returns the folder.
        @discardableResult
        public func startNewRecord(now: Date = Date()) -> String? {
            opening.withLock { _ -> String? in
                guard case .keyLost = availability else { return nil }
                let sealed = RecordFiles.sealed(of: name, in: directory, fileSystem: fileSystem)
                guard let folder = RecordFiles.moveAside(sealed, in: directory, folder: "\(name.rawValue)-unreadable",
                                                         fileSystem: fileSystem, now: now)
                else {
                    Log.error("vault: could not move the unreadable \(name.rawValue) files aside — nothing changed",
                              ["ring": name.rawValue])
                    return nil
                }
                state.withLock { $0 = State(availability: .unopened, keyring: nil, movedAside: nil, loggedPause: false) }
                Log.info("vault: a new \(name.rawValue) record was started; the unreadable files are in \(folder)",
                         ["ring": name.rawValue, "files": sealed.count])
                return folder
            }
        }
    }
}

public enum VaultError: Error, Sendable, CustomStringConvertible {
    case realKeychainUnderTest

    public var description: String {
        switch self {
        case .realKeychainUnderTest:
            "a test run may not use the real keychain: build the Vault with InMemoryKeyCustody"
        }
    }
}

/// A secret store that refuses every call under a test run: the second lock
/// on the same door. `Vault.system` already refuses to be built, and whatever
/// else builds a custody over the keychain still never reaches it from a test
/// (`SecretStoreCustody` reads this as the keychain refusing access).
struct TestGuardedSecrets: SecretStore {
    let secrets: any SecretStore

    init(_ secrets: any SecretStore) { self.secrets = secrets }

    func get(_ key: String) throws(SecretStoreError) -> Data? {
        try refuseUnderTests()
        return try secrets.get(key)
    }

    func set(_ value: Data, for key: String) throws(SecretStoreError) {
        try refuseUnderTests()
        try secrets.set(value, for: key)
    }

    func delete(_ key: String) throws(SecretStoreError) {
        try refuseUnderTests()
        try secrets.delete(key)
    }

    private func refuseUnderTests() throws(SecretStoreError) {
        if TestRun.active { throw .authenticationFailed }
    }
}
