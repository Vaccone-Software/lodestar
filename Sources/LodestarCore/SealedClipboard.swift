import Foundation
import Stoic
import StoicSealed
import StoicStore

/// The clipboard history on disk, sealed: the index journal, the blobs and
/// thumbnails beside it, the state of the key, the migration of an older
/// history in, compaction (which is what makes a deletion real) and the clear.
///
/// **One thread at a time.** The store that owns this calls it from its io
/// queue only; blob and thumbnail reads (`files`) are the exception and are
/// pure functions of a path and a key, so any thread may make them.
///
/// ## Key states (`Vault.RingName.clipboard`)
///
/// - ring present: normal;
/// - custody **unavailable** (locked keychain, a refused prompt): the history is
///   *paused for this launch* (`OpenResult.unavailable`): nothing is read,
///   written, deleted or migrated, and `Vault.Ring.retry()` asks again when the
///   screen unlocks. A key that cannot be asked for is not a key that is gone;
/// - ring **missing** and sealed data exists: the history cannot be read.
///   `v2/` moves to `clipboard-unreadable-YYYY-MM-DD/` (inside the clipboard
///   folder; never deleted), a new ring is made and the history starts fresh,
///   and `Opened.movedAside` says so once;
/// - ring missing and nothing sealed: the ring is made.
public final class SealedClipboard: @unchecked Sendable {
    public let root: URL
    public let files: ClipboardFiles
    let ring: Vault.Ring
    let fileSystem: any FileSystem

    private var journal: SealedJournal?
    /// What the log holds past the snapshot, for deciding when to fold it.
    private var snapshotBytes = 0
    private var recordsSinceSnapshot = 0
    /// Deletes and replacements since the snapshot: their keys are still in
    /// records that open, until a fold rotates the ring's key.
    private var removalsSinceSnapshot = 0
    /// Some of what the journal holds did not open or decode: what is not
    /// readable is never folded away, and nothing is garbage collected.
    private var degraded = false

    public init(root: URL, ring: Vault.Ring, fileSystem: any FileSystem = OwnerOnlyFileSystem()) {
        self.root = root
        self.files = ClipboardFiles(root: root)
        self.ring = ring
        self.fileSystem = fileSystem
    }

    // MARK: - Opening

    public struct Unavailable: Error, Equatable {
        public var words: String
        /// Whether asking again could change the answer without the person
        /// doing something (a keychain that was merely locked).
        public var retryable: Bool
        /// The keychain is why: what the person is told is "the keychain
        /// didn't open", and not a disk's trouble.
        public var keychain = false
    }

    public struct Opened {
        /// Newest first.
        public var entries: [ClipEntry]
        /// The folder `v2/` was moved into because its key was gone or it was damaged.
        public var movedAside: String?
        /// An older history was taken in, and what that did.
        public var migration: MigrationReport?
        /// A v1 index that would not decode was set aside (its new name).
        public var quarantined: String?
        /// Sealed values that did not open: shown anyway, never folded away.
        public var unreadable: Int
        public var orphansRemoved: Int
        public var seconds: Double
    }

    public enum OpenResult {
        case ready(Opened)
        case unavailable(Unavailable)
    }

    public func open() -> OpenResult {
        let started = Date()
        SealedDirectory.ensure(root.path, fileSystem: fileSystem)
        var movedAside: String?

        // 1. The key. Nothing is touched before it is known.
        let keyring: Keyring
        switch settleKey(movedAside: &movedAside) {
        case .failure(let unavailable): return .unavailable(unavailable)
        case .success(let ring): keyring = ring
        }

        // 2. An older history, taken in before the index is opened.
        var migration: MigrationReport?
        var quarantined: String?
        let v1 = ClipboardV1Reader.read(root)
        if case .undecodable = v1 {
            // As every build has: the index is set aside, said out loud, and
            // the files under items/ are not touched.
            let aside = Quarantine.setAside(ClipboardV1.indexFile(root))
            quarantined = aside.lastPathComponent
            Log.error("clipboard: index did not decode — quarantined at \(aside.lastPathComponent)")
        } else if case .unreadable = v1 {
            Log.error("clipboard: index unreadable — left as it is, nothing deleted, nothing migrated")
        }
        if case .found(let snapshot) = v1, !hasSealedData() {
            // The first run of the sealed build over a history: v2.migrating
            // is built, verified, and renamed into place.
            switch ClipboardMigration.migrate(self, v1: snapshot, keyring: keyring) {
            case .success(let report): migration = report
            case .failure(let failure):
                Log.error("clipboard: the history could not be sealed — \(failure.words); nothing was removed")
                return .unavailable(Unavailable(words: failure.words, retryable: false))
            }
        }

        // 3. The index.
        let state: ClipboardIndexState
        let unreadable: Int
        switch openJournal(keyring: keyring, movedAside: &movedAside) {
        case .failure(let unavailable): return .unavailable(unavailable)
        case .success(let opened): (state, unreadable) = opened
        }
        var current = state

        // 4. A v1 history beside a sealed one: an older build ran in between
        // (or a migration was cut short after the rename).
        if case .found(let snapshot) = v1, migration == nil {
            switch ClipboardMigration.merge(self, v1: snapshot, into: &current) {
            case .success(let report): migration = report
            case .failure(let failure):
                // The sealed history is intact and v1 is untouched: say so, and go on.
                Log.error("clipboard: the older files could not be merged — \(failure.words); left as they are")
            }
        }

        // 5. What nothing names (a blob whose record never landed).
        var orphans = 0
        if !degraded { orphans = files.collectGarbage(keeping: Set(current.entries.map(\.storage))) }
        if orphans > 0 { Log.info("clipboard: removed \(orphans) files no clip names") }

        return .ready(Opened(entries: current.entries, movedAside: movedAside, migration: migration, quarantined: quarantined,
                             unreadable: unreadable, orphansRemoved: orphans,
                             seconds: Date().timeIntervalSince(started)))
    }

    /// Whether `v2/` holds anything sealed: a journal with records or a
    /// snapshot, or any blob.
    func hasSealedData() -> Bool {
        let names = RecordFiles.names(in: files.base.path, fileSystem: fileSystem)
        if names.contains(where: { $0.hasPrefix("index.sj.snapshot") }) { return true }
        if let size = (try? FileManager.default.attributesOfItem(atPath: files.indexPath))?[.size] as? Int, size > 0 { return true }
        return !RecordFiles.names(in: files.items.path, fileSystem: fileSystem).isEmpty
    }

    private func settleKey(movedAside: inout String?) -> Result<Keyring, Unavailable> {
        if hasSealedData() {
            if let existing = ring.existing() { return .success(existing) }
            switch ring.availability {
            case .paused(let why):
                return .failure(Unavailable(words: why.words, retryable: why.retryable, keychain: true))
            case .keyLost:
                return .failure(Unavailable(words: "the clipboard key is not available", retryable: false, keychain: true))
            case .ready, .unopened:
                // The custody answered "nothing there", and sealed files need it.
                guard let folder = moveAside(reason: "the clipboard key is gone") else {
                    return .failure(Unavailable(words: "the unreadable history could not be moved aside", retryable: false))
                }
                movedAside = folder
            }
        }
        if let made = ring.keyring() { return .success(made) }
        switch ring.availability {
        case .paused(let why): return .failure(Unavailable(words: why.words, retryable: why.retryable, keychain: true))
        default: return .failure(Unavailable(words: "the clipboard key could not be made", retryable: false, keychain: true))
        }
    }

    /// `v2/` into `clipboard-unreadable-YYYY-MM-DD/`. Never deletes.
    private func moveAside(reason: String) -> String? {
        let stamp = RecordFiles.dateStamp(Date())
        var name = "clipboard-unreadable-\(stamp)"
        var attempt = 1
        while (try? fileSystem.exists(root.appendingPathComponent(name).path)) == true {
            attempt += 1
            name = "clipboard-unreadable-\(stamp)-\(attempt)"
        }
        do {
            try fileSystem.rename(from: files.base.path, to: root.appendingPathComponent(name).path)
            try fileSystem.syncDirectory(root.path)
            SealedDirectory.makePrivate(root.appendingPathComponent(name).path)
            Log.error("clipboard: \(reason) — the sealed history was moved to \(name) and a new one is started; nothing deleted")
            return name
        } catch {
            Log.error("clipboard: could not move the unreadable history aside (\(error))")
            return nil
        }
    }

    /// Open the journal and replay it. Damage that cannot be read around, or a
    /// history none of which opens, moves `v2/` aside the way a lost key does.
    private func openJournal(keyring: Keyring, movedAside: inout String?) -> Result<(ClipboardIndexState, Int), Unavailable> {
        for attempt in 0..<2 {
            files.prepare(fileSystem: fileSystem)
            do {
                let opened = try SealedJournal.open(at: files.indexPath, context: ClipboardSealed.indexContext, keyring: keyring,
                                                    fileSystem: fileSystem, options: ClipboardSealed.journalOptions)
                let replay = try opened.replay()
                let folded = ClipboardIndexState.fold(replay)
                let nothingOpens = !replay.failures.isEmpty && replay.snapshot == nil && replay.records.isEmpty
                if attempt == 0, nothingOpens, replay.failures.allSatisfy({ if case .unknownKey = $0.error { true } else { false } }) {
                    try? opened.close()
                    guard let folder = moveAside(reason: "none of the sealed history opens with the clipboard key") else {
                        return .failure(Unavailable(words: "the unreadable history could not be moved aside", retryable: false))
                    }
                    movedAside = folder
                    continue
                }
                SealedFailures.note(replay.failures, file: "clipboard index")
                let unreadable = replay.failures.count + folded.malformed
                degraded = unreadable > 0
                journal = opened
                snapshotBytes = folded.snapshotBytes
                recordsSinceSnapshot = folded.records
                removalsSinceSnapshot = folded.removals
                return .success((folded.state, unreadable))
            } catch {
                if attempt == 0, case .store(let store) = error, store.kind == .corrupt {
                    guard let folder = moveAside(reason: "the sealed history is damaged") else {
                        return .failure(Unavailable(words: "the damaged history could not be moved aside", retryable: false))
                    }
                    movedAside = folder
                    continue
                }
                if case .keyring(.custody(let reason)) = error {
                    return .failure(Unavailable(words: "the keychain failed (\(reason))", retryable: false, keychain: true))
                }
                return .failure(Unavailable(words: "the history could not be opened (\(error))", retryable: false))
            }
        }
        return .failure(Unavailable(words: "the history could not be opened", retryable: false))
    }

    // MARK: - Appending, folding

    public enum Appended: Equatable {
        case appended
        /// Not opened (paused, or cleared): nothing was written.
        case closed
        case failed(String)
    }

    /// The operations, as one batch: one write and one full sync, all of them
    /// or, after a crash, none. **The blobs they name are complete before
    /// this is called**: the caller writes them first.
    @discardableResult
    public func append(_ ops: [ClipboardOp]) -> Appended {
        guard !ops.isEmpty else { return .appended }
        guard let journal else { return .closed }
        let encoded = ops.compactMap { ClipboardIndexState.encode($0) }
        guard encoded.count == ops.count else { return .failed("an operation could not be encoded") }
        do {
            try journal.append(batch: encoded)
            recordsSinceSnapshot += encoded.count
            for op in ops {
                switch op {
                case .delete, .replace: removalsSinceSnapshot += 1
                default: break
                }
            }
            return .appended
        } catch {
            return .failed("\(error)")
        }
    }

    /// A delete or an edit has been recorded and not yet folded away: the
    /// clip's key can still be opened by the ring. Known again at the next
    /// launch, so a delete that was cut short by a crash is finished.
    public var removalsOwed: Bool { journal != nil && removalsSinceSnapshot > 0 }

    /// Time to fold the log into a snapshot: past about 500 records, or past
    /// twice the snapshot's size (with a floor, so a small history is not
    /// folded for every copy).
    public var needsCompaction: Bool {
        guard let journal else { return false }
        return recordsSinceSnapshot > 500 || journal.byteCount > 2 * max(snapshotBytes, 64 << 10)
    }

    public enum Compacted: Equatable {
        case compacted(records: Int, bytes: Int)
        case closed
        /// Some sealed values do not open: a snapshot built from the rest
        /// would destroy them, so nothing was done.
        case refused(unreadable: Int)
        /// The snapshot is durable and the log is empty, and the old keys
        /// could not be retired: the shredding is not done (the next
        /// compaction finishes it).
        case notShredded(String)
        case failed(String)
    }

    /// Fold the log into a snapshot, **rotating the ring's key**: every record
    /// written before, and with them every per-clip key a deleted clip had,
    /// is unopenable by anyone afterwards. Off the main thread.
    @discardableResult
    public func compact(rotatingKey: Bool = true) -> Compacted {
        guard let journal else { return .closed }
        do {
            let replay = try journal.replay()
            let folded = ClipboardIndexState.fold(replay)
            let unreadable = replay.failures.count + folded.malformed
            if unreadable > 0 {
                degraded = true
                SealedFailures.note(replay.failures, file: "clipboard index")
                return .refused(unreadable: unreadable)
            }
            guard let snapshot = folded.state.snapshot() else { return .failed("the index could not be encoded") }
            do {
                try journal.compact(snapshot: snapshot, rotatingKey: rotatingKey)
            } catch SealedStoreError.compactedButNotShredded(let error) {
                snapshotBytes = snapshot.count
                recordsSinceSnapshot = 0
                return .notShredded("\(error)")
            }
            snapshotBytes = snapshot.count
            recordsSinceSnapshot = 0
            removalsSinceSnapshot = 0
            return .compacted(records: folded.records, bytes: snapshot.count)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Close the journal (the file and, if any, its lock).
    public func close() {
        try? journal?.close()
        journal = nil
    }

    // MARK: - Clearing

    /// Everything the history is, gone: the journal closed, `v2/`, a migration
    /// in progress, whatever an older build left (plaintext), and what was
    /// moved aside; then **the ring destroyed**, so that anything that
    /// survives on a disk's blocks is noise. The next write makes a new ring.
    /// Returns whether the ring was destroyed (false when the custody could
    /// not be asked: the old key stays, harmlessly, with nothing under it).
    @discardableResult
    public func clear() -> Bool {
        close()
        Self.removeEverything(in: root, fileSystem: fileSystem)
        snapshotBytes = 0
        recordsSinceSnapshot = 0
        removalsSinceSnapshot = 0
        degraded = false
        return ring.destroy()
    }

    /// The files of every layout a clear must reach, the clear flag excepted.
    public static func removeEverything(in root: URL, fileSystem: any FileSystem) {
        for name in RecordFiles.names(in: root.path, fileSystem: fileSystem)
        where name == "v2" || name == "v2.migrating" || name == "items" || name == "thumbs" || name == "index.json"
            || name.hasPrefix("index.json.") || name.hasPrefix("clipboard-unreadable-") {
            try? fileSystem.removeTree(root.appendingPathComponent(name).path)
        }
        try? fileSystem.syncDirectory(root.path)
    }

    // MARK: - What is there, for the report

    public struct Inventory: Equatable {
        public var sealedClips: Int?
        public var blobs: Int
        public var plaintextFiles: [String]
        public var asideFolders: [String]
        public var quarantines: [String]
    }

    /// Counts of what is on disk, by name: never a byte of a clip.
    public static func inventory(root: URL, fileSystem: any FileSystem = OwnerOnlyFileSystem()) -> Inventory {
        let files = ClipboardFiles(root: root)
        let top = RecordFiles.names(in: root.path, fileSystem: fileSystem)
        return Inventory(
            sealedClips: nil,
            blobs: RecordFiles.names(in: files.items.path, fileSystem: fileSystem).count,
            plaintextFiles: ClipboardV1.plaintextFiles(root),
            asideFolders: top.filter { $0.hasPrefix("clipboard-unreadable-") }.sorted(),
            quarantines: top.filter { $0.hasPrefix("index.json.corrupt-") }.sorted())
    }
}
