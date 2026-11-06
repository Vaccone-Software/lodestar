import Foundation
import StoicStore

/// The health record read whole, for a process that only reads it
/// (`lodestar health`): every month of the health log, the archive months
/// an earlier ring retired, and what could not be opened, said rather than
/// read as empty. Nothing is written, repaired or migrated; a journal the
/// running app is appending to is read as it stands.
public enum HealthRecord {
    public struct Contents {
        /// Every health event, oldest first, each once.
        public var events: [ObservationEvent] = []
        /// The files that did not open: the key was unavailable, or values
        /// in them did not decrypt. Nonempty means `events` is not the
        /// whole record.
        public var problems: [String] = []
    }

    public static func read(in data: URL, ring: Vault.Ring,
                            fileSystem: any FileSystem = PosixFileSystem()) -> Contents {
        var out = Contents()
        var logged: [Data] = []
        for stem in RecordFiles.lineStems(base: ObservationStore.healthLogBase, in: data, fileSystem: fileSystem) {
            let contents = LineStore.read(plaintext: data.appendingPathComponent(stem + ".jsonl"), ring: ring,
                                          fileSystem: fileSystem)
            if !contents.whole { out.problems.append(problem(stem, unavailable: contents.unavailable, failures: contents.failures)) }
            logged += LineStore.lines(contents.bytes)
        }
        // An archive month and the log can both hold a line, when a
        // retirement stopped between its two writes: the same line twice is
        // one event. Never the same instant and kind: one quarter hour's
        // clicks are one event per app, all stamped at its start.
        let inLog = Set(logged)
        var archived: [Data] = []
        for name in RecordFiles.healthArchives(in: data, fileSystem: fileSystem) {
            let sealed = SealedValueFile(url: data.appendingPathComponent(name + RecordFiles.archiveSealedSuffix),
                                         ring: ring, fileSystem: fileSystem)
            var packed: [UInt8]?
            switch sealed.read() {
            case .value(let bytes, _): packed = bytes
            case .absent: packed = try? fileSystem.readAll(data.appendingPathComponent(name).path)
            case .unavailable: out.problems.append("\(name): the key is unavailable")
            case .unreadable(let why): out.problems.append("\(name): did not open (\(why))")
            }
            guard let packed else { continue }
            guard let lines = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data else {
                out.problems.append("\(name): did not inflate")
                continue
            }
            archived += LineStore.lines(lines).filter { !inLog.contains($0) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        out.events = (archived + logged).compactMap { try? decoder.decode(ObservationEvent.self, from: $0) }
            .sorted { $0.t < $1.t }
        return out
    }

    /// One health day of the raw press record, each press with the roster id
    /// of the keyboard its `keyboard` index names in its segment's header
    /// (nil when the index is 0, unattributed, or past the roster).
    public static func presses(day: String, in data: URL, ring: Vault.Ring,
                               fileSystem: any FileSystem = PosixFileSystem())
        -> (presses: [(press: KeyPress, keyboard: String?)], problem: String?) {
        let directory = data.appendingPathComponent(KeyStore.subdirectory, isDirectory: true)
        let read = KeyStore.read(day: day, in: directory, ring: ring, fileSystem: fileSystem)
        let rows = read.segments.flatMap { segment in
            segment.presses.map { press -> (press: KeyPress, keyboard: String?) in
                let roster = segment.header.roster
                let index = press.keyboard - 1
                return (press, roster.indices.contains(index) ? roster[index] : nil)
            }
        }.sorted { $0.press.down < $1.press.down }
        let problem = read.status.clean ? nil
            : Self.problem("\(KeyStore.subdirectory) \(day)", unavailable: read.status.unavailable, failures: read.status.failures)
        return (rows, problem)
    }

    /// The health days the raw press record holds, oldest first.
    public static func pressDays(in data: URL, fileSystem: any FileSystem = PosixFileSystem()) -> [String] {
        KeyStore.days(in: data.appendingPathComponent(KeyStore.subdirectory, isDirectory: true), fileSystem: fileSystem)
    }

    private static func problem(_ what: String, unavailable: Bool, failures: Int) -> String {
        "\(what): " + (unavailable ? "the key is unavailable" : "\(failures) values did not open")
    }
}
