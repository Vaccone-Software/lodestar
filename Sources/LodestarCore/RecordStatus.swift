import Foundation
import StoicStore

/// What `lodestar diagnose` and Settings say about the sealed records: the
/// state of each key, how much is sealed, how much is still plaintext and
/// being migrated, and whether everything that is sealed opens. Counts and
/// words only, never a path inside a record or a byte of content.
public enum RecordStatus {
    public struct Report: Equatable {
        public enum Key: Equatable {
            /// The ring is held (or can be read) and works.
            case ready
            /// Nothing is sealed yet and no ring has been needed.
            case none
            case paused(String)
            /// No ring, sealed files need it. For the health record: refused until the person starts a new one.
            case lost
        }

        public var key: Key
        /// Days (health) or log months and files (logbook) that are sealed.
        public var sealedFiles: Int
        /// Plaintext files an earlier build left, not yet sealed.
        public var plaintextFiles: Int
        /// Sealed values that did not open when checked (-1 when not checked).
        public var unreadable: Int
        /// A folder where unreadable files were moved aside, if one is there.
        public var movedAside: [String]
        public var days: Int?
    }

    /// The health record's report. `verify` opens everything sealed (the
    /// whole record is read: seconds for years of it).
    public static func health(vault: Vault, directory: URL, verify: Bool = true,
                              fileSystem: any FileSystem = PosixFileSystem()) -> Report {
        let ring = vault.ring(.health)
        let sealed = RecordFiles.sealed(of: .health, in: directory.path, fileSystem: fileSystem)
        let plain = RecordFiles.plaintext(of: .health, in: directory.path, fileSystem: fileSystem)
        let key = keyState(ring, sealedCount: sealed.count)
        var days = Set<String>()
        for prefix in [KeyStore.subdirectory, PointerStore.subdirectory] {
            let folder = directory.appendingPathComponent(prefix, isDirectory: true)
            days.formUnion(DayStore.sealedDays(prefix: prefix, in: folder.path, fileSystem: fileSystem))
        }
        var unreadable = -1
        if verify, case .ready = key {
            unreadable = 0
            for prefix in [KeyStore.subdirectory, PointerStore.subdirectory] {
                let folder = directory.appendingPathComponent(prefix, isDirectory: true)
                for day in DayStore.sealedDays(prefix: prefix, in: folder.path, fileSystem: fileSystem) {
                    let read = DayStore.read(prefix: prefix, purpose: DayStore.purpose, day: day, in: folder, ring: ring,
                                             fileSystem: fileSystem)
                    unreadable += read.failures + (read.unavailable ? 1 : 0)
                }
            }
            unreadable += unreadableLogs(base: ObservationStore.healthLogBase, in: directory, ring: ring, fileSystem: fileSystem)
            for name in ["era.json", "blind.json"] {
                if case .unreadable = SealedValueFile(url: directory.appendingPathComponent(name), ring: ring,
                                                      fileSystem: fileSystem).read() { unreadable += 1 }
            }
        }
        return Report(key: key, sealedFiles: sealed.count, plaintextFiles: plain.count, unreadable: unreadable,
                      movedAside: movedAside("health-unreadable-", in: directory, fileSystem: fileSystem), days: days.count)
    }

    public static func logbook(vault: Vault, directory: URL, verify: Bool = true,
                               fileSystem: any FileSystem = PosixFileSystem()) -> Report {
        let ring = vault.ring(.logbook)
        let sealed = RecordFiles.sealed(of: .logbook, in: directory.path, fileSystem: fileSystem)
        let plain = RecordFiles.plaintext(of: .logbook, in: directory.path, fileSystem: fileSystem)
        let key = keyState(ring, sealedCount: sealed.count)
        var unreadable = -1
        if verify, case .ready = key {
            unreadable = unreadableLogs(base: "events", in: directory, ring: ring, fileSystem: fileSystem)
            for name in ["observations.json", "rollups.json"] {
                if case .unreadable = SealedValueFile(url: directory.appendingPathComponent(name), ring: ring,
                                                      fileSystem: fileSystem).read() { unreadable += 1 }
            }
        }
        return Report(key: key, sealedFiles: sealed.count, plaintextFiles: plain.count, unreadable: unreadable,
                      movedAside: movedAside("logbook-unreadable-", in: directory, fileSystem: fileSystem), days: nil)
    }

    private static func keyState(_ ring: Vault.Ring, sealedCount: Int) -> Report.Key {
        if ring.held != nil { return .ready }
        switch ring.availability {
        case .ready: return .ready
        case .paused(let why): return .paused(why.words)
        case .keyLost: return .lost
        case .unopened:
            // Not yet settled (a command-line process): ask, read-only.
            if ring.existing() != nil { return .ready }
            switch ring.availability {
            case .paused(let why): return .paused(why.words)
            default: return sealedCount > 0 ? .lost : .none
            }
        }
    }

    private static func unreadableLogs(base: String, in directory: URL, ring: Vault.Ring, fileSystem: any FileSystem) -> Int {
        var total = 0
        var stems: Set<String> = []
        for name in RecordFiles.names(in: directory.path, fileSystem: fileSystem)
        where name.hasSuffix(RecordFiles.journalSuffix) && (name == base + ".sj" || name.hasPrefix(base + "-")) {
            stems.insert(String(name.dropLast(RecordFiles.journalSuffix.count)))
        }
        for stem in stems {
            let contents = LineStore.read(plaintext: directory.appendingPathComponent(stem + ".jsonl"), ring: ring,
                                          fileSystem: fileSystem)
            total += contents.failures + (contents.unavailable ? 1 : 0)
        }
        return total
    }

    private static func movedAside(_ prefix: String, in directory: URL, fileSystem: any FileSystem) -> [String] {
        RecordFiles.names(in: directory.path, fileSystem: fileSystem).filter { $0.hasPrefix(prefix) }.sorted()
    }

    // MARK: - Words

    /// The lines `diagnose` prints for the health record.
    public static func healthLines(_ report: Report) -> [String] {
        var lines: [String] = []
        let unit = report.days.map { "\($0) day\($0 == 1 ? "" : "s")" } ?? "\(report.sealedFiles) files"
        switch report.key {
        case .ready:
            lines.append("health record: sealed, \(unit)" + (report.plaintextFiles > 0 ? "; migrating \(report.plaintextFiles) files" : ""))
        case .none:
            lines.append("health record: " + (report.plaintextFiles > 0
                ? "not sealed yet — \(report.plaintextFiles) files waiting to be sealed" : "nothing recorded yet"))
        case .paused(let why):
            lines.append("health record: PAUSED for this launch — \(why). Nothing is read, written or deleted; it is tried again at the next launch")
        case .lost:
            lines.append("health record: THE KEY IS GONE — \(report.sealedFiles) sealed files cannot be opened. Nothing was deleted. "
                + "Settings → Observations → \"Start a new health record\" moves them into a dated health-unreadable folder and starts again")
        }
        if report.unreadable > 0 { lines.append("  ⚠ \(report.unreadable) sealed values did not open (altered, or sealed under another key)") }
        for folder in report.movedAside { lines.append("  unreadable files from an earlier record are kept in \(folder)") }
        return lines
    }

    public static func logbookLines(_ report: Report) -> [String] {
        var lines: [String] = []
        switch report.key {
        case .ready:
            lines.append("logbook: sealed, \(report.sealedFiles) files" + (report.plaintextFiles > 0 ? "; migrating \(report.plaintextFiles) files" : ""))
        case .none:
            lines.append("logbook: " + (report.plaintextFiles > 0 ? "not sealed yet — \(report.plaintextFiles) files waiting to be sealed" : "nothing recorded yet"))
        case .paused(let why):
            lines.append("logbook: PAUSED for this launch — \(why). Nothing is read, written or deleted")
        case .lost:
            lines.append("logbook: the key is gone — the unreadable files are moved aside and a new logbook starts when Lodestar next runs")
        }
        if report.unreadable > 0 { lines.append("  ⚠ \(report.unreadable) sealed values did not open") }
        for folder in report.movedAside { lines.append("  ⚠ the logbook's key was gone: its unreadable files are in \(folder); a new logbook was started") }
        return lines
    }
}
