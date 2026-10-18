import Foundation
import StoicSealed
import StoicStore

/// What a v1 index was, when it was looked at.
enum ClipboardV1State {
    case absent
    /// The file is there and could not be read at all.
    case unreadable
    /// The file is there and is not an index.
    case undecodable
    case found(ClipboardV1Reader.Snapshot)
}

enum ClipboardV1Reader {
    struct Snapshot {
        /// The SHA-256 of the file as read: how a migration knows an index has been taken in.
        var digest: String
        var clips: [Clipboard.Clip]
    }

    static func read(_ root: URL) -> ClipboardV1State {
        let url = ClipboardV1.indexFile(root)
        switch ClipboardV1.read(url) {
        case .missing: return .absent
        case .unreadable: return .unreadable
        case .bytes(let data):
            guard let decoded = try? JSONDecoder().decode(ClipboardV1.Index.self, from: data) else { return .undecodable }
            return .found(Snapshot(digest: ClipboardV1.digest(of: data), clips: decoded.clips))
        }
    }
}

/// What taking an older history in did.
public struct MigrationReport: Equatable {
    public enum Kind: Equatable {
        /// `v2.migrating` was built from `index.json`, `items/` and `thumbs/`, and renamed to `v2`.
        case migrated
        /// An older build had run beside a sealed history; its clips are merged in.
        case merged
        /// Everything of the older history was already in; only its files were left to remove.
        case finished
    }

    public var kind: Kind
    public var clips = 0
    /// Plaintext bytes sealed.
    public var bytes: Int64 = 0
    /// Files the index names that were not there (as a read of one that is not there always was).
    public var missingFiles = 0
    /// Files that are there and could not be read: left where they are, never removed.
    public var unreadableFiles = 0
    /// Clips of the older history that the sealed one already had, newer or as new.
    public var superseded = 0
    /// Cards of the sealed history that a newer copy in the older one replaced.
    public var replaced = 0
    /// Keepsakes of the older history whose place was taken, and are now ordinary clips.
    public var pinsDropped = 0
    /// Files of the older history removed, once everything was verified.
    public var removedFiles = 0
    /// What is still there of it.
    public var left: [String] = []
    public var seconds = 0.0

    var words: String {
        "\(kind) \(clips) clips, \(bytes / 1_000_000) MB sealed in \(String(format: "%.1f", seconds)) s; "
            + "\(missingFiles) files were missing, \(unreadableFiles) unreadable, \(removedFiles) removed, \(left.count) left"
    }
}

struct MigrationFailure: Error {
    var words: String
}

/// What sealing one clip's files counted, merged into the report by the caller
/// (clips are sealed on several threads at once).
struct ImportStats {
    var bytes: Int64 = 0
    var missing = 0
    var unreadable = 0
    var leave: Set<String> = []

    mutating func add(_ other: ImportStats) {
        bytes += other.bytes
        missing += other.missing
        unreadable += other.unreadable
        leave.formUnion(other.leave)
    }
}

/// v1 → v2. See `SealedClipboard` for the key states and the layout.
///
/// **The rule: plaintext is removed only after everything it held is sealed,
/// read back and compared.** For each clip the sealed blob (and thumbnail) is
/// written under a fresh key, `fsync`ed, opened again and compared with the
/// bytes that were read from the old files; only then is its record appended.
/// A clip whose old files are missing or unreadable keeps its card with what
/// could be read, as it always has (`try?` reads), and is counted.
///
/// The fresh migration builds `v2.migrating/`, folds it into a snapshot,
/// syncs, renames it to `v2`, syncs the parent, and only then removes the old
/// files (the index last). The crash table, by what is on disk at the next launch:
///
/// | on disk | meaning | next launch |
/// |---|---|---|
/// | v1, `v2.migrating` (partial or whole), no `v2` | died while building | `v2.migrating` is discarded, the migration is redone |
/// | v1, `v2` (a migration's, with its `imported` record), `index.json` as it was | died after the rename | the digest is in `v2`: only the old files are removed |
/// | v1 partly removed, `v2`, `index.json` still there | died while removing | likewise (the index goes last, so a partial removal is still recognised) |
/// | v1, `v2` that holds history, `index.json` not in `v2`'s imports | an older build ran in between | merged (below) |
/// | `v2` only | done | nothing |
///
/// **The merge** (v2 and v1 both there, v1 not yet taken in): the older
/// build's clips are *newer data*. Each clip of the old index that `v2` does
/// not have, or has with an older `created`, is sealed in (verified as above)
/// and takes its place by age; one that `v2` has with the same or a newer
/// `created` is left out (**the newer copy of a clip wins whole**: the id is
/// the content's hash, and a re-copy's rich forms may differ). A keepsake of
/// the old index keeps its place only if that place is free in `v2` (or the
/// card it replaces held one, which stays); otherwise it is an ordinary clip.
/// A card of `v2` that a newer copy replaced is deleted, and the compaction
/// that follows rotates the key, so it is gone for real. The `imported` record
/// (the old index's digest) is appended last, which makes a repeat harmless.
enum ClipboardMigration {
    // MARK: Fresh

    static func migrate(_ clipboard: SealedClipboard, v1 snapshot: ClipboardV1Reader.Snapshot, keyring: Keyring)
        -> Result<MigrationReport, MigrationFailure> {
        let started = Date()
        let root = clipboard.root
        let fileSystem = clipboard.fileSystem
        let staging = ClipboardFiles(root: root, folder: "v2.migrating")
        var report = MigrationReport(kind: .migrated)
        var leave: Set<String> = []
        var phases: [(String, Double)] = []

        // A staging folder from a run that died is discarded: v1 is intact, so it is redone.
        try? fileSystem.removeTree(staging.base.path)
        staging.prepare(fileSystem: fileSystem)
        func abandon(_ words: String) -> Result<MigrationReport, MigrationFailure> {
            try? fileSystem.removeTree(staging.base.path)
            return .failure(MigrationFailure(words: words))
        }

        let journal: SealedJournal
        do throws(SealedStoreError) {
            journal = try SealedJournal.open(at: staging.indexPath, context: ClipboardSealed.indexContext, keyring: keyring,
                                             fileSystem: fileSystem, options: ClipboardSealed.journalOptions)
        } catch {
            return abandon("the new index could not be made (\(error))")
        }

        Log.info("clipboard: sealing the older history", ["clips": snapshot.clips.count])
        // The staging journal needs no records: everything is folded straight
        // into its snapshot (one full sync, not one per batch of records).
        var state = ClipboardIndexState()
        do {
            // Sealed, fsynced and read back on several threads at once (each
            // file's sync waits on the drive, and they overlap).
            let entries = try importAll(snapshot.clips, from: root, into: staging, report: &report, leave: &leave)
            phases.append(("sealed and verified", Date().timeIntervalSince(started)))
            // In the old order; a clip the old index listed twice is one clip (the later place wins).
            var seen = Set<String>()
            state.entries = entries.reversed().filter { seen.insert($0.clip.id).inserted }.reversed()
            report.clips = entries.count
            state.apply(.imported(digest: snapshot.digest))
            guard let folded = state.snapshot() else { throw MigrationFailure(words: "the index could not be encoded") }
            try journal.compact(snapshot: folded, rotatingKey: false)
            try journal.close()
            // The blobs were each `fsync`ed before their record; the journal's
            // own full sync has flushed the drive's cache behind all of them.
            for directory in [staging.items, staging.thumbs, staging.base] { try fileSystem.syncDirectory(directory.path) }
            // A `v2` with nothing sealed in it (a fresh start that has had no
            // copy yet) is in the way of the rename, and holds nothing.
            if clipboard.files.base.path != staging.base.path, !clipboard.hasSealedData() {
                try? fileSystem.removeTree(clipboard.files.base.path)
            }
            phases.append(("folded and synced", Date().timeIntervalSince(started)))
            try fileSystem.rename(from: staging.base.path, to: clipboard.files.base.path)
            try fileSystem.syncDirectory(root.path)
            phases.append(("published", Date().timeIntervalSince(started)))
        } catch {
            try? journal.close()
            return abandon("\(error)")
        }

        // Only now: what the sealed copy replaces.
        finish(clipboard, leave: leave, report: &report)
        report.seconds = Date().timeIntervalSince(started)
        phases.append(("old files removed", report.seconds))
        Log.info("clipboard: migrated the history — \(report.words)",
                 ["phases": phases.map { "\($0.0) \(String(format: "%.1f", $0.1)) s" }.joined(separator: ", ")])
        return .success(report)
    }

    // MARK: Merge

    static func merge(_ clipboard: SealedClipboard, v1 snapshot: ClipboardV1Reader.Snapshot, into state: inout ClipboardIndexState)
        -> Result<MigrationReport, MigrationFailure> {
        let started = Date()
        var report = MigrationReport(kind: .merged)
        var leave: Set<String> = []

        // Already in, and only its files are left: remove them.
        if state.imported.contains(snapshot.digest) {
            report.kind = .finished
            finish(clipboard, leave: leave, report: &report)
            report.seconds = Date().timeIntervalSince(started)
            Log.info("clipboard: finished taking the older history in — \(report.words)")
            return .success(report)
        }

        var taken = Set(state.entries.compactMap(\.clip.pinnedSlot))
        var ops: [ClipboardOp] = []
        var displaced: [String] = []
        do {
            // Oldest first, so that what is put among the others lands by age.
            for clip in snapshot.clips.reversed() {
                let existing = state.entries.first { $0.clip.id == clip.id }
                if let existing, existing.clip.created >= clip.created {
                    report.superseded += 1
                    continue
                }
                var local = ImportStats()
                var entry = try importClip(clip, from: clipboard.root, into: clipboard.files, stats: &local)
                report.bytes += local.bytes
                report.missingFiles += local.missing
                report.unreadableFiles += local.unreadable
                leave.formUnion(local.leave)
                if let existing {
                    // The card a newer copy replaces keeps what the hand did to it.
                    entry.clip.pinnedSlot = existing.clip.pinnedSlot
                    entry.clip.keptName = existing.clip.keptName
                    displaced.append(existing.storage)
                    report.replaced += 1
                } else if let slot = clip.pinnedSlot {
                    if (1...Clipboard.pinSlots).contains(slot), !taken.contains(slot) {
                        taken.insert(slot)
                    } else {
                        entry.clip.pinnedSlot = nil
                        entry.clip.keptName = nil
                        report.pinsDropped += 1
                    }
                }
                let op = ClipboardOp.ordered(entry)
                state.apply(op)
                ops.append(op)
                report.clips += 1
            }
            ops.append(.imported(digest: snapshot.digest))
            state.apply(.imported(digest: snapshot.digest))
        } catch {
            return .failure(MigrationFailure(words: "\(error)"))
        }
        switch clipboard.append(ops) {
        case .appended: break
        case .closed: return .failure(MigrationFailure(words: "the sealed history is not open"))
        case .failed(let why): return .failure(MigrationFailure(words: why))
        }
        // A card a newer copy replaced is deleted for real: its blob goes, and
        // the compaction retires the key that was in its record.
        clipboard.files.remove(storages: displaced)
        if !displaced.isEmpty { clipboard.compact(rotatingKey: true) }
        finish(clipboard, leave: leave, report: &report)
        report.seconds = Date().timeIntervalSince(started)
        Log.info("clipboard: merged the older build's history — \(report.words)")
        return .success(report)
    }

    // MARK: One clip

    /// Seal one clip's v1 files, and read them back. Throws when the sealed
    /// copy is not byte for byte what the old files held.
    /// Every clip, in parallel, in the order given. The first failure stops the rest.
    private static func importAll(_ clips: [Clipboard.Clip], from root: URL, into files: ClipboardFiles,
                                  report: inout MigrationReport, leave: inout Set<String>) throws -> [ClipEntry] {
        let lock = NSLock()
        var entries = [ClipEntry?](repeating: nil, count: clips.count)
        var failure: Error?
        var stats = ImportStats()
        var done = 0
        let chunk = 16
        let chunks = (clips.count + chunk - 1) / chunk
        var next = 0
        // Four at a time: a clip can be 20 MB, and each worker holds a few copies of it.
        DispatchQueue.concurrentPerform(iterations: min(4, max(1, chunks))) { _ in
            while true {
                let index: Int? = lock.withLock {
                    guard failure == nil, next < chunks else { return nil }
                    defer { next += 1 }
                    return next
                }
                guard let index else { return }
                var local = ImportStats()
                for position in (index * chunk)..<min(clips.count, (index + 1) * chunk) {
                    do {
                        let entry = try importClip(clips[position], from: root, into: files, stats: &local)
                        lock.withLock { entries[position] = entry }
                    } catch {
                        lock.withLock { failure = failure ?? error }
                        return
                    }
                }
                lock.withLock {
                    stats.add(local)
                    done += min(clips.count, (index + 1) * chunk) - index * chunk
                    if done / 1000 != (done - chunk) / 1000 {
                        Log.info("clipboard: sealing the older history", ["done": done, "of": clips.count])
                    }
                }
            }
        }
        if let failure { throw failure }
        report.bytes += stats.bytes
        report.missingFiles += stats.missing
        report.unreadableFiles += stats.unreadable
        leave.formUnion(stats.leave)
        return entries.compactMap { $0 }
    }

    /// Seal one clip's v1 files, and read them back. Throws when the sealed
    /// copy is not byte for byte what the old files held.
    private static func importClip(_ clip: Clipboard.Clip, from root: URL, into files: ClipboardFiles,
                                   stats: inout ImportStats) throws -> ClipEntry {
        var items: [ClipboardContent.Item] = []
        // `expected`: the index says this file exists (an image has no plain
        // form, and its absence is not a loss).
        func read(_ url: URL, expected: Bool = true) -> Data? {
            switch ClipboardV1.read(url) {
            case .bytes(let data):
                stats.bytes += Int64(data.count)
                return data
            case .missing:
                if expected { stats.missing += 1 }
                return nil
            case .unreadable:
                stats.unreadable += 1
                stats.leave.insert(url.path)
                return nil
            }
        }
        for (item, types) in clip.itemTypes.enumerated() {
            var natives: [(type: String, data: Data)] = []
            for (offset, type) in types.enumerated() {
                if let data = read(ClipboardV1.nativeFile(root, id: clip.id, item: item, offset: offset)) {
                    natives.append((type, data))
                }
            }
            let plain = read(ClipboardV1.plainFile(root, id: clip.id, item: item), expected: clip.kind == .text && types.isEmpty)
            items.append(.init(plain: plain, natives: natives))
        }
        var thumbnail: Data?
        switch ClipboardV1.read(ClipboardV1.thumbFile(root, id: clip.id)) {
        case .bytes(let data): thumbnail = data
        case .missing: break
        case .unreadable:
            stats.unreadable += 1
            stats.leave.insert(ClipboardV1.thumbFile(root, id: clip.id).path)
        }

        let storage = ClipboardSealed.newStorage()
        let key = SealingKey.generate()
        try files.writeBlob(storage: storage, key: key, items: items, sync: true)
        guard case .items(let back) = files.readBlob(storage: storage, key: key), ClipboardContent.sameBytes(back, items) else {
            throw MigrationFailure(words: "a sealed clip did not read back as it was")
        }
        if let thumbnail {
            try files.writeThumb(storage: storage, key: key, png: thumbnail, sync: true)
            guard files.readThumb(storage: storage, key: key) == thumbnail else {
                throw MigrationFailure(words: "a sealed thumbnail did not read back as it was")
            }
        }
        return ClipEntry(clip: clip, storage: storage, blobKey: Data(key.exportedForWrapping()))
    }

    // MARK: Removing the old files

    /// Remove what an older build wrote, the index last. Whatever could not be
    /// read stays, and is named.
    private static func finish(_ clipboard: SealedClipboard, leave: Set<String>, report: inout MigrationReport) {
        let root = clipboard.root
        let fileSystem = clipboard.fileSystem
        var removed = 0
        for folder in [ClipboardV1.items(root), ClipboardV1.thumbs(root)] {
            for name in RecordFiles.names(in: folder.path, fileSystem: fileSystem) {
                let path = folder.appendingPathComponent(name).path
                if leave.contains(path) { continue }
                if (try? fileSystem.removeTree(path)) != nil { removed += 1 }
            }
            // Empty now, unless something was left.
            rmdir(folder.path)
        }
        for name in RecordFiles.names(in: root.path, fileSystem: fileSystem) where name.hasPrefix("index.json.corrupt-") {
            if (try? fileSystem.removeTree(root.appendingPathComponent(name).path)) != nil { removed += 1 }
        }
        if (try? fileSystem.remove(ClipboardV1.indexFile(root).path)) != nil { removed += 1 }
        try? fileSystem.syncDirectory(root.path)
        report.removedFiles = removed
        report.left = ClipboardV1.plaintextFiles(root)
    }
}
