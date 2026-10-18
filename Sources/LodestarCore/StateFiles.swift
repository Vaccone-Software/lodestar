import Foundation
import StoicSealed
import StoicStore

/// The disk half of the state store: what is read, taken in, written and
/// backed up, as functions of the files and the ring, with no memory of their
/// own, so they run on a background queue while the store itself stays on the
/// main thread (`StateStore`).
///
/// **Two forms of one file.** `state.sealed` (and its backup `state.sealed.bak`)
/// is the state sealed under the `state` ring, one `SealedValueFile` value under
/// the context `("lodestar.file", "state")`, the same for both so a backup is
/// a copy. `state.json` (and `state.json.bak`) is what a build older than the
/// sealing wrote. The sealed form has a name of its own so that an older build
/// does not misread it (it finds no state and starts empty); the plaintext
/// form is *taken in*, never merely read:
///
/// 1. the plaintext is decoded (`StateMigrations.lift` as ever);
/// 2. if a sealed state exists, the two are merged (`PersistedState.merging`),
///    which is how a launch after a downgrade keeps what both builds knew;
/// 3. the result is written sealed, **read back, and compared byte for byte**
///    with what was written;
/// 4. only then are the plaintext files removed, and the backup becomes a sealed
///    copy of the same bytes.
///
/// Interrupted anywhere, the plaintext is still there and the next launch does
/// it again (the merge is idempotent). A plaintext file that does not decode is
/// moved aside, never deleted.
struct StateFiles: Sendable {
    /// The plaintext file's path: the name the store is made with.
    let plain: URL
    let ring: Vault.Ring
    let fileSystem: any FileSystem

    static let name = "state"

    /// `state.sealed` beside `state.json`: the same name with the sealed extension.
    var sealedURL: URL { plain.deletingPathExtension().appendingPathExtension("sealed") }
    var plainBackup: URL { plain.appendingPathExtension("bak") }
    private var sealedBackupURL: URL { sealedURL.appendingPathExtension("bak") }

    private var sealed: SealedValueFile { SealedValueFile(url: sealedURL, name: Self.name, ring: ring, fileSystem: fileSystem) }
    private var sealedBackup: SealedValueFile {
        SealedValueFile(url: sealedBackupURL, name: Self.name, ring: ring, fileSystem: fileSystem)
    }

    // MARK: Coding

    static func decode(_ bytes: [UInt8]) -> PersistedState? {
        try? JSONDecoder().decode(PersistedState.self, from: StateMigrations.lift(Data(bytes)))
    }

    /// Sorted keys, so the same state is the same bytes; not pretty-printed,
    /// as nobody reads the plaintext any more.
    static func encode(_ state: PersistedState) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)).map { [UInt8]($0) }
    }

    // MARK: Opening

    struct Opened: Sendable {
        enum Outcome: Sendable {
            /// The state to run with (empty when there was none).
            case ready(PersistedState)
            /// The key cannot be had, in words. Nothing was read or changed.
            case paused(String)
        }

        var outcome: Outcome
        /// What the person is told, if anything.
        var warning: String?
    }

    private func pauseReason() -> String {
        if case .paused(let why) = ring.availability { return why.words }
        return "its key cannot be asked for"
    }

    private func exists(_ url: URL) -> Bool { (try? fileSystem.exists(url.path)) == true }

    /// Decide the key (the vault's policy for a ring that is missing while
    /// sealed files need it: they are moved aside and a new ring is made),
    /// read the state, take in what an earlier build left, and back it up.
    /// **Not for the main thread**: the first ask of the custody may wait on a
    /// prompt.
    func open() -> Opened {
        ring.settle()
        switch ring.availability {
        case .paused(let why): return Opened(outcome: .paused(why.words))
        case .keyLost: return Opened(outcome: .paused("the state key is gone and its files could not be moved aside"))
        case .ready, .unopened: break
        }
        var warning = ring.movedAside.map {
            "the key to your saved state was gone: it is kept in \($0), and Lodestar started a new one (your breaths are in that folder, sealed)"
        }

        var loaded: PersistedState?
        /// The bytes `loaded` was read from, as they sit in the sealed file.
        var cleanBytes: [UInt8]?
        var needsWrite = false

        // 1. The sealed state.
        var corrupt = false
        switch sealed.read() {
        case .unavailable:
            return Opened(outcome: .paused(pauseReason()))
        case .value(let bytes, let isSealed):
            if let state = Self.decode(bytes) {
                loaded = state
                cleanBytes = bytes
                // Plaintext at the sealed name is nothing this build writes: seal it.
                needsWrite = !isSealed
            } else {
                corrupt = true
            }
        case .unreadable:
            corrupt = true
        case .absent:
            break
        }

        // 2. A damaged sealed state: the evidence is copied aside, the backup tried.
        if corrupt {
            let evidence = Quarantine.setAside(sealedURL, keepOriginal: true)
            Log.error("state: corrupt, quarantined", ["at": evidence.lastPathComponent])
            if case .value(let bytes, _) = sealedBackup.read(), let recovered = Self.decode(bytes) {
                loaded = recovered
                needsWrite = true
                warning = "state was corrupted — restored from backup (\(recovered.breaths.count) breaths)"
                Log.error("state: restored from backup", ["breaths": recovered.breaths.count])
            } else {
                warning = "state was corrupted and no backup existed — starting fresh (kept \(evidence.lastPathComponent))"
                Log.error("state: no usable backup — starting fresh")
            }
        } else if loaded == nil, case .value(let bytes, _) = sealedBackup.read(), let recovered = Self.decode(bytes) {
            // The state file is gone and its backup is not: never start empty beside a backup.
            loaded = recovered
            needsWrite = true
            warning = "state was missing — restored from backup (\(recovered.breaths.count) breaths)"
            Log.error("state: missing, restored from backup", ["breaths": recovered.breaths.count])
        }

        // 3. What an earlier build left in the clear. Both files are taken in,
        // and neither is touched until the sealed form has been verified.
        var damaged: String?
        var plaintextToRemove: [URL] = []
        var tookMain = false
        if exists(plain) {
            switch takeInPlain(plain, into: &loaded) {
            case .taken:
                tookMain = true
                plaintextToRemove.append(plain)
                needsWrite = true
            case .unreadable:
                // Starting from nothing beside a file that could not be read would
                // let its older contents overwrite newer ones at the next launch.
                return Opened(outcome: .paused("the state file an earlier build wrote could not be read"))
            case .undecodable(let evidence):
                damaged = evidence
            }
        }
        if exists(plainBackup) {
            if tookMain {
                // A generation older than the file just taken in: nothing in it that is not there.
                plaintextToRemove.append(plainBackup)
            } else if let recovered = Self.read(plainBackup, fileSystem) {
                loaded = loaded.map { $0.merging(newer: recovered) } ?? recovered
                needsWrite = true
                plaintextToRemove.append(plainBackup)
                if let evidence = damaged {
                    warning = "state was corrupted — restored from backup (\(recovered.breaths.count) breaths; the damaged file is kept as \(evidence))"
                    Log.error("state: restored from the plaintext backup", ["breaths": recovered.breaths.count])
                }
                damaged = nil
            }
        }
        if let evidence = damaged {
            // A damaged plaintext state and nothing to put in its place.
            warning = "state was corrupted and no backup existed — starting fresh (kept \(evidence))"
        }

        // 4. Seal what was taken in, verify it, and only then let go of the plaintext.
        var state = loaded ?? PersistedState()
        state.version = Lodestar.stateVersion
        if needsWrite, let bytes = Self.encode(state) {
            switch sealed.write(bytes) {
            case .paused:
                return Opened(outcome: .paused(pauseReason()))
            case .failed(let why):
                // Nothing is lost: the plaintext is where it was and this launch
                // runs on the state in memory; the next save tries again.
                Log.error("state: the sealed state could not be written — breaths stay as they were on disk", ["error": why])
            case .written:
                if case .value(let back, sealed: true) = sealed.read(), back == bytes, Self.decode(back) != nil {
                    Log.info("state: sealed", ["bytes": bytes.count, "tookInPlaintext": !plaintextToRemove.isEmpty])
                    writeBackup(bytes)
                    for url in plaintextToRemove { remove(url) }
                } else {
                    Log.error("state: the sealed state did not read back as written — the plaintext is kept")
                }
            }
        } else if let bytes = cleanBytes {
            // The last-known-good generation: one backup per boot, so a future
            // corruption always has somewhere to fall back to.
            writeBackup(bytes)
        }
        return Opened(outcome: .ready(state), warning: warning)
    }

    private enum PlainOutcome {
        /// Decoded and merged into `loaded`.
        case taken
        /// Could not be read at all: left where it is.
        case unreadable
        /// Readable bytes that are not a state: moved aside under this name.
        case undecodable(String)
    }

    private func takeInPlain(_ url: URL, into loaded: inout PersistedState?) -> PlainOutcome {
        let raw: [UInt8]
        do {
            raw = try fileSystem.readAll(url.path)
        } catch {
            Log.error("state: the earlier state file could not be read (\(error)) — left as it is")
            return .unreadable
        }
        guard let state = Self.decode(raw) else {
            let evidence = Quarantine.setAside(url)
            Log.error("state: the earlier state file is corrupt, set aside", ["at": evidence.lastPathComponent])
            return .undecodable(evidence.lastPathComponent)
        }
        loaded = loaded.map { $0.merging(newer: state) } ?? state
        return .taken
    }

    private static func read(_ url: URL, _ fileSystem: any FileSystem) -> PersistedState? {
        (try? fileSystem.readAll(url.path)).flatMap(decode)
    }

    /// The backup is replaced, never removed and then recreated: written
    /// beside, synced, and renamed over, so `state.sealed.bak` is at every
    /// instant the old generation or the new one whole.
    private func writeBackup(_ bytes: [UInt8]) {
        switch sealedBackup.write(bytes) {
        case .written: Paths.excludeFromBackup(sealedBackupURL)
        case .paused, .failed: Log.error("state: the backup could not be written")
        }
        Paths.excludeFromBackup(sealedURL)
    }

    /// The plaintext is gone once its sealed form is verified. A file that cannot
    /// be removed is moved aside instead, so that a later launch does not merge it
    /// in over a newer state; if it can be neither, it is said.
    private func remove(_ url: URL) {
        do {
            try fileSystem.remove(url.path)
        } catch {
            Log.error("state: could not remove the earlier plaintext \(url.lastPathComponent) (\(error)) — setting it aside")
            if !FileManager.default.fileExists(atPath: Quarantine.setAside(url).path) {
                Log.error("state: the earlier plaintext \(url.lastPathComponent) is still in place")
            }
        }
    }

    // MARK: Writing

    func write(_ bytes: [UInt8]) -> SealedValueFile.Written {
        sealed.write(bytes)
    }

    // MARK: Reading, for anyone who is not the store

    /// The state as a reader that must change nothing sees it: the sealed
    /// file, or the plaintext one if nothing has been sealed yet. Never makes
    /// a key, moves a file, writes a backup or merges.
    func peek() -> StateStore.Reading {
        switch sealed.read() {
        case .value(let bytes, let isSealed):
            return Self.decode(bytes).map { .state($0, sealed: isSealed) } ?? .unreadable
        case .unavailable: return .unavailable
        case .unreadable: return .unreadable
        case .absent:
            guard exists(plain) else { return .absent }
            return Self.read(plain, fileSystem).map { .state($0, sealed: false) } ?? .unreadable
        }
    }
}

extension StateStore {
    /// What a process that must not write (the command line: `diagnose`,
    /// `observations`) may know of the state.
    public enum Reading {
        case absent
        /// Sealed under the key, or (`sealed: false`) still the plaintext an earlier build wrote.
        case state(PersistedState, sealed: Bool)
        /// The key cannot be asked for: not an empty state.
        case unavailable
        case unreadable

        public var state: PersistedState? {
            if case .state(let state, _) = self { state } else { nil }
        }
    }

    public static func read(file: URL = StateStore.defaultFile, vault: Vault,
                            fileSystem: any FileSystem = OwnerOnly.fileSystem) -> Reading {
        StateFiles(plain: file, ring: vault.ring(.state), fileSystem: fileSystem).peek()
    }
}

// MARK: - Merging two states of one person

extension PersistedState {
    /// This state with what `newer` knows laid over it. The two are states of
    /// one person that diverged: a build older than the sealing ran and wrote a
    /// plaintext state beside the sealed one, or the state changed while the
    /// keychain was away. `newer` is the one that began from *nothing* and
    /// recorded only what happened since, so a value it holds is a more recent
    /// answer than the one here, and a value it lacks says nothing.
    ///
    /// **Idempotent**: merging the same `newer` twice is merging it once, which
    /// is what lets a launch that was cut short after sealing and before removing
    /// the plaintext simply run again. That is why counts take the larger and
    /// dates the later, rather than adding.
    func merging(newer: PersistedState) -> PersistedState {
        var out = self
        out.version = max(version ?? 0, newer.version ?? 0)

        // Breaths: by address; the newer record of an address replaces the older.
        let replaced = Set(newer.breaths.map(\.path))
        out.breaths = breaths.filter { !replaced.contains($0.path) } + newer.breaths
        if let latest = newer.latestBreath, out.breaths.contains(where: { $0.path == latest }) {
            out.latestBreath = latest
        }

        // Parked windows are the ones of one boot: whichever side parked any
        // is the one that knows, and an empty map is not a statement.
        if !newer.parked.isEmpty {
            out.parked = newer.parked
            out.parkedSession = newer.parkedSession
        }

        var usage = self.usage ?? [:]
        for (bundle, record) in newer.usage ?? [:] {
            if let known = usage[bundle] {
                usage[bundle] = UsageRecord(count: max(known.count, record.count), last: max(known.last, record.last))
            } else {
                usage[bundle] = record
            }
        }
        out.usage = usage.isEmpty ? self.usage : usage

        out.walkStep = newer.walkStep ?? walkStep
        out.walkCompletedVersion = newer.walkCompletedVersion ?? walkCompletedVersion
        out.walkDoor = newer.walkDoor ?? walkDoor
        // Consent was given once, when it was first given.
        out.editorConsentAt = [editorConsentAt, newer.editorConsentAt].compactMap { $0 }.min()

        let spent = Set(meetingSpent ?? []).union(newer.meetingSpent ?? [])
        out.meetingSpent = spent.isEmpty ? meetingSpent : spent.sorted()

        // A suggestion's wait counts from the first time it stood.
        var standing = coachStandingSince ?? [:]
        for (key, date) in newer.coachStandingSince ?? [:] { standing[key] = min(standing[key] ?? date, date) }
        out.coachStandingSince = standing.isEmpty ? coachStandingSince : standing

        // A lesson the hand completed stays completed; otherwise the newer record.
        var lessons = curriculum ?? [:]
        for (key, record) in newer.curriculum ?? [:] {
            if let known = lessons[key], known.completedAt != nil, record.completedAt == nil { continue }
            lessons[key] = record
        }
        out.curriculum = lessons.isEmpty ? curriculum : lessons
        return out
    }
}
