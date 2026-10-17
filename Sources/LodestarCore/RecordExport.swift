import Foundation
import StoicStore

/// `lodestar health export <dir>` (and `--logbook`): the sealed record
/// decrypted back to the plaintext formats it was kept in, so a person's own
/// scripts, which read `keys/keys-DAY.bin.z` with `zlib.decompress(data, -15)`,
/// keep working.
///
/// What it writes, under `<dir>`, files `0600` and the folders `0700`:
///
/// - health: `keys/keys-DAY.bin`, `keys-DAY.N.bin` (an open segment) and
///   `keys-DAY.N.bin.z` (a closed one: the deflated bytes the sealed day
///   holds, which are the bytes a `.bin.z` always was), the same under
///   `pointer/`; `health-events.jsonl` and `health-events-YYYY-MM.jsonl`;
///   `health-YYYY-MM.jsonl.z`; `era.json`; `blind.json`.
/// - logbook: `events.jsonl` and `events-YYYY-MM.jsonl`, `observations.json`,
///   `rollups.json`.
///
/// It reads with the same readers as everything else (never repairing a
/// journal the app is appending to), and a record that does not open is
/// reported, never written as an empty file. It writes nothing into the data
/// directory, and refuses to write into a folder that is not empty, so an
/// export never overwrites one.
public enum RecordExport {
    public struct Report: Equatable {
        public var written: [(path: String, bytes: Int)] = []
        /// What could not be read: the key is unavailable, or a value did not open.
        public var problems: [String] = []
        public var ok: Bool { problems.isEmpty }

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.problems == rhs.problems && lhs.written.map(\.path) == rhs.written.map(\.path)
                && lhs.written.map(\.bytes) == rhs.written.map(\.bytes)
        }
    }

    public enum Refusal: Error, CustomStringConvertible {
        case notEmpty(String)
        case cannotCreate(String)

        public var description: String {
            switch self {
            case .notEmpty(let path): "\(path) is not empty: export writes into a new or empty folder"
            case .cannotCreate(let path): "could not create \(path)"
            }
        }
    }

    public static func export(logbook: Bool, from data: URL, to destination: URL, vault: Vault,
                              fileSystem: any FileSystem = PosixFileSystem()) throws -> Report {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? ["?"]).isEmpty else {
                throw Refusal.notEmpty(destination.path)
            }
        } else {
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch { throw Refusal.cannotCreate(destination.path) }
        }
        var report = Report()
        func put(_ bytes: [UInt8], _ relative: String) {
            let target = destination.appendingPathComponent(relative)
            let folder = target.deletingLastPathComponent()
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.createFile(atPath: target.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600]) {
                report.written.append((relative, bytes.count))
            } else {
                report.problems.append("could not write \(relative)")
            }
        }
        if logbook {
            let ring = vault.ring(.logbook)
            lines(base: "events", in: data, ring: ring, fileSystem: fileSystem, put: put, problem: { report.problems.append($0) })
            for name in ["observations.json", "rollups.json"] {
                whole(name, in: data, ring: ring, fileSystem: fileSystem, put: put, problem: { report.problems.append($0) })
            }
        } else {
            let ring = vault.ring(.health)
            days(prefix: KeyStore.subdirectory, sub: KeyStore.subdirectory, in: data, ring: ring, fileSystem: fileSystem,
                 put: put, problem: { report.problems.append($0) })
            days(prefix: PointerStore.subdirectory, sub: PointerStore.subdirectory, in: data, ring: ring, fileSystem: fileSystem,
                 put: put, problem: { report.problems.append($0) })
            lines(base: ObservationStore.healthLogBase, in: data, ring: ring, fileSystem: fileSystem, put: put,
                  problem: { report.problems.append($0) })
            archives(in: data, ring: ring, fileSystem: fileSystem, put: put, problem: { report.problems.append($0) })
            for name in ["era.json", "blind.json"] {
                whole(name, in: data, ring: ring, fileSystem: fileSystem, put: put, problem: { report.problems.append($0) })
            }
        }
        return report
    }

    private typealias Put = ([UInt8], String) -> Void
    private typealias Problem = (String) -> Void

    private static func days(prefix: String, sub: String, in data: URL, ring: Vault.Ring, fileSystem: any FileSystem,
                             put: Put, problem: Problem) {
        let directory = data.appendingPathComponent(sub, isDirectory: true)
        for day in DayStore.days(prefix: prefix, in: directory, fileSystem: fileSystem) {
            let contents = DayStore.read(prefix: prefix, purpose: DayStore.purpose, day: day, in: directory,
                                         ring: ring, fileSystem: fileSystem)
            if contents.unavailable || contents.failures > 0 {
                problem("\(prefix) \(day): \(contents.unavailable ? "the key is unavailable" : "\(contents.failures) values did not open") — not exported")
                continue
            }
            for (index, segment) in contents.segments.enumerated() {
                let stem = index == 0 ? "\(prefix)-\(day)" : "\(prefix)-\(day).\(index)"
                if index < contents.closed.count {
                    put(contents.closed[index], "\(sub)/\(stem).bin.z")
                } else {
                    put(segment, "\(sub)/\(stem).bin")
                }
            }
        }
    }

    /// `events.jsonl` and `events-YYYY-MM.jsonl` (or the health log's).
    private static func lines(base: String, in data: URL, ring: Vault.Ring, fileSystem: any FileSystem,
                              put: Put, problem: Problem) {
        var stems: Set<String> = []
        for name in RecordFiles.names(in: data.path, fileSystem: fileSystem) {
            guard name == base + ".sj" || name == base + ".jsonl"
                    || (name.hasPrefix(base + "-") && (name.hasSuffix(".sj") || name.hasSuffix(".jsonl")))
            else { continue }
            let stem = name.hasSuffix(".sj") ? String(name.dropLast(3)) : String(name.dropLast(6))
            if stem == base || EventLog.shardMonth(of: data.appendingPathComponent(stem + ".jsonl")) != nil { stems.insert(stem) }
        }
        for stem in stems.sorted() {
            let contents = LineStore.read(plaintext: data.appendingPathComponent(stem + ".jsonl"), ring: ring,
                                          fileSystem: fileSystem)
            guard contents.whole else {
                problem("\(stem): \(contents.unavailable ? "the key is unavailable" : "\(contents.failures) values did not open") — not exported")
                continue
            }
            put([UInt8](contents.bytes), "\(stem).jsonl")
        }
    }

    private static func archives(in data: URL, ring: Vault.Ring, fileSystem: any FileSystem, put: Put, problem: Problem) {
        for name in RecordFiles.names(in: data.path, fileSystem: fileSystem).sorted()
        where name.hasPrefix("health-") && name.hasSuffix(".jsonl.z" + RecordFiles.archiveSealedSuffix) {
            let plain = String(name.dropLast(RecordFiles.archiveSealedSuffix.count))
            switch SealedValueFile(url: data.appendingPathComponent(name), ring: ring, fileSystem: fileSystem).read() {
            case .value(let packed, _): put(packed, plain)
            case .absent: break
            case .unavailable: problem("\(name): the key is unavailable — not exported")
            case .unreadable(let why): problem("\(name): did not open (\(why)) — not exported")
            }
        }
    }

    private static func whole(_ name: String, in data: URL, ring: Vault.Ring, fileSystem: any FileSystem,
                              put: Put, problem: Problem) {
        switch SealedValueFile(url: data.appendingPathComponent(name), ring: ring, fileSystem: fileSystem).read() {
        case .value(let bytes, _): put(bytes, name)
        case .absent: break
        case .unavailable: problem("\(name): the key is unavailable — not exported")
        case .unreadable(let why): problem("\(name): did not open (\(why)) — not exported")
        }
    }
}
