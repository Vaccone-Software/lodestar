import Foundation
import StoicSealed
import StoicStore

/// Which files in the data directory belong to which sealed record, in
/// which form, by name. One place, so the key policy (what is sealed and
/// needs the ring), the migration (what is still plaintext and does not),
/// the size accounting and the clear all read the same list.
///
/// The **sealed forms**:
///
/// - a journal is `<name>.sj`, with its sidecars `<name>.sj.snapshot`,
///   `<name>.sj.snapshot-lost`, `<name>.sj.lock` and `<name>.sj.corrupt-N`
///   (Stoic's `Journal`); its name ends in `.sj`, never in what an older
///   build reads, so an older build ignores it instead of misreading it
///   (`keys-2026-10-17.sj`, `events-2026-08.sj`, `health-events.sj`);
/// - a sealed whole file keeps its name when it was JSON before
///   (`era.json`, `blind.json`, `observations.json`, `rollups.json`) and is
///   told from a plaintext one by its first four bytes;
/// - the state file is `state.sealed` (and `state.sealed.bak`, and a
///   `state.sealed.corrupt-<stamp>` copy set aside), never `state.json`: an
///   older build that runs against the folder finds no state of its own to
///   misread, starts with nothing, and writes a plaintext `state.json` that the
///   next launch of this one merges in and removes (`StateStore`);
/// - a health archive month, which was `health-2026-08.jsonl.z`, is
///   `health-2026-08.jsonl.z.sealed`.
public enum RecordFiles {
    public static let journalSuffix = ".sj"
    public static let archiveSealedSuffix = ".sealed"

    /// The names that make up one sealed journal.
    static let journalSidecars = [".snapshot", ".snapshot-lost", ".lock"]

    /// Whether a (base) name is a sealed journal or one of its sidecars:
    /// `x.sj`, `x.sj.snapshot`, `x.sj.corrupt-3`, …
    static func isJournalFile(_ name: String) -> Bool {
        name.hasSuffix(journalSuffix) || name.contains(journalSuffix + ".")
    }

    /// `x.sj` for any member of its family.
    static func journalPath(ofFamilyMember name: String) -> String {
        guard let range = name.range(of: journalSuffix + ".") else { return name }
        return String(name[..<range.lowerBound]) + journalSuffix
    }

    static func names(in directory: String, fileSystem: any FileSystem) -> [String] {
        (try? fileSystem.list(directory: directory)) ?? []
    }

    static func isSealedFile(_ path: String, fileSystem: any FileSystem) -> Bool {
        guard let file = try? fileSystem.open(path, mode: .read) else { return false }
        defer { _ = try? fileSystem.close(file) }
        guard let head = try? fileSystem.read(file, at: 0, count: 4) else { return false }
        return Sealing.isSealed(head)
    }

    private static let healthDirectories = [KeyStore.subdirectory, PointerStore.subdirectory]
    private static let healthWholeFiles = ["era.json", "blind.json", Person.file]
    private static let logbookWholeFiles = ["observations.json", "rollups.json"]

    /// The state file's two forms.
    public static let stateSealedName = "state.sealed"
    public static let statePlaintextNames = ["state.json", "state.json.bak"]

    /// `state.sealed`, its backup, and the copies set aside, by name.
    private static func isStateSealedName(_ name: String) -> Bool {
        name == stateSealedName || name.hasPrefix(stateSealedName + ".")
    }

    private static func isHealthLogName(_ name: String) -> Bool {
        name.hasPrefix(ObservationStore.healthLogBase + ".") || name.hasPrefix(ObservationStore.healthLogBase + "-")
    }

    private static func isLogbookLogName(_ name: String) -> Bool {
        name == "events" + journalSuffix || (name.hasPrefix("events-") && isJournalFile(name))
            || (name.hasPrefix("events.") && isJournalFile(name))
    }

    private static func isHealthArchive(_ name: String) -> Bool {
        name.hasPrefix("health-") && !isHealthLogName(name)
            && (name.hasSuffix(".jsonl.z") || name.hasSuffix(".jsonl.z" + archiveSealedSuffix))
    }

    /// Relative paths (to `directory`) of the sealed files of `ring`.
    public static func sealed(of ring: Vault.RingName, in directory: String, fileSystem: any FileSystem) -> [String] {
        var found: [String] = []
        let top = names(in: directory, fileSystem: fileSystem)
        switch ring {
        case .health:
            for sub in healthDirectories {
                for name in names(in: directory + "/" + sub, fileSystem: fileSystem) where isJournalFile(name) {
                    found.append(sub + "/" + name)
                }
            }
            for name in top {
                if isHealthLogName(name), isJournalFile(name) { found.append(name) }
                if isHealthArchive(name), name.hasSuffix(archiveSealedSuffix) { found.append(name) }
            }
            for name in healthWholeFiles where top.contains(name) {
                if isSealedFile(directory + "/" + name, fileSystem: fileSystem) { found.append(name) }
            }
        case .logbook:
            for name in top where isLogbookLogName(name) { found.append(name) }
            for name in logbookWholeFiles where top.contains(name) {
                if isSealedFile(directory + "/" + name, fileSystem: fileSystem) { found.append(name) }
            }
        case .state:
            for name in top where isStateSealedName(name) {
                if isSealedFile(directory + "/" + name, fileSystem: fileSystem) { found.append(name) }
            }
        case .clipboard:
            break
        }
        return found.sorted()
    }

    /// Relative paths of the files an earlier build wrote in the clear and
    /// that migration has not yet sealed and removed.
    public static func plaintext(of ring: Vault.RingName, in directory: String, fileSystem: any FileSystem) -> [String] {
        var found: [String] = []
        let top = names(in: directory, fileSystem: fileSystem)
        switch ring {
        case .health:
            for sub in healthDirectories {
                for name in names(in: directory + "/" + sub, fileSystem: fileSystem)
                where name.hasSuffix(".bin") || name.hasSuffix(".bin.z") {
                    found.append(sub + "/" + name)
                }
            }
            for name in top {
                if isHealthLogName(name), name.hasSuffix(".jsonl") { found.append(name) }
                if isHealthArchive(name), name.hasSuffix(".jsonl.z") { found.append(name) }
            }
            for name in healthWholeFiles where top.contains(name) {
                if !isSealedFile(directory + "/" + name, fileSystem: fileSystem) { found.append(name) }
            }
        case .logbook:
            for name in top where name.hasPrefix("events") && name.hasSuffix(".jsonl")
                && !isHealthLogName(name) {
                found.append(name)
            }
            for name in logbookWholeFiles where top.contains(name) {
                if !isSealedFile(directory + "/" + name, fileSystem: fileSystem) { found.append(name) }
            }
        case .state:
            for name in statePlaintextNames where top.contains(name) { found.append(name) }
        case .clipboard:
            break
        }
        return found.sorted()
    }

    /// Move `relative` paths under `directory` into a new
    /// `<folder>-YYYY-MM-DD/` there, keeping their layout. Never deletes.
    /// Returns the folder's name, or nil if anything could not be moved
    /// (what was moved stays moved; the rest stays where it is).
    static func moveAside(
        _ relative: [String], in directory: String, folder: String, fileSystem: any FileSystem, now: Date = Date()
    ) -> String? {
        let stamp = dateStamp(now)
        var name = "\(folder)-\(stamp)"
        var attempt = 1
        while (try? fileSystem.exists(directory + "/" + name)) == true {
            attempt += 1
            name = "\(folder)-\(stamp)-\(attempt)"
        }
        let target = directory + "/" + name
        do {
            try fileSystem.createDirectory(target)
            SealedDirectory.makePrivate(target)
            for path in relative {
                let destination = target + "/" + path
                let parent = SealedPath.directory(of: destination)
                if parent != target {
                    try fileSystem.createDirectory(parent)
                    SealedDirectory.makePrivate(parent)
                }
                try fileSystem.rename(from: directory + "/" + path, to: destination)
            }
            try fileSystem.syncDirectory(directory)
            return name
        } catch {
            Log.error("records: could not move files aside (\(error))", ["folder": name])
            return nil
        }
    }

    /// Remove a sealed journal and everything that belongs to it: its
    /// snapshot, a snapshot being written, the tombstone, the lock, and the
    /// copies a compaction over damage keeps (`SealedJournal.remove`, which
    /// knows the list). A journal that is still open, or that another process
    /// holds, is refused and left whole, and said.
    static func removeJournal(_ path: String, fileSystem: any FileSystem) {
        do {
            try SealedJournal.remove(at: path, fileSystem: fileSystem)
        } catch {
            Log.error("records: could not remove a journal (\(error))", ["file": SealedPath.name(of: path)])
        }
    }

    static func dateStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Directories the sealed records live in are the owner's alone.
enum SealedDirectory {
    /// `0700`, for a directory that may be new or may have been made `0755`
    /// by an earlier build. Best effort: a path the real file system does not
    /// know (a simulated one) is left alone.
    static func makePrivate(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Create `path` (and parents) and make it private.
    static func ensure(_ path: String, fileSystem: any FileSystem) {
        _ = try? fileSystem.createDirectory(path)
        makePrivate(path)
    }
}

/// `/`-separated path arithmetic on the strings the file system speaks.
enum SealedPath {
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// What one pass of taking plaintext files into their sealed form did.
public struct RecordMigration: Equatable, Sendable {
    /// Plaintext files sealed (or found sealed already) and removed.
    public var files = 0
    public var bytes: Int64 = 0
    /// Plaintext files still there: the ring is paused, or the file could not be taken in.
    public var remaining = 0
    public var paused = false
    public var failed: [String] = []

    public init() {}

    public static func + (lhs: RecordMigration, rhs: RecordMigration) -> RecordMigration {
        var sum = RecordMigration()
        sum.files = lhs.files + rhs.files
        sum.bytes = lhs.bytes + rhs.bytes
        sum.remaining = lhs.remaining + rhs.remaining
        sum.paused = lhs.paused || rhs.paused
        sum.failed = lhs.failed + rhs.failed
        return sum
    }

    public static func += (lhs: inout RecordMigration, rhs: RecordMigration) { lhs = lhs + rhs }
}
