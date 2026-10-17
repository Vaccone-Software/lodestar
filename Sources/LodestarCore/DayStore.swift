import Foundation
import StoicSealed
import StoicStore

/// One local day of a raw record (the keys, the pointer), sealed.
///
/// A day is one `SealedJournal`, `<prefix>-YYYY-MM-DD.sj`, sealed under the
/// health ring with the context `("lodestar.days", prefix, day)`. What it
/// holds is the same stream of **segments** the plaintext day files were:
/// a segment is a `DayFile` header and the rows written under it, and a new
/// one opens whenever the build, the format or the keyboards attached would
/// make the header lie about the rows after it. A flush appends one
/// journal record per run of rows (one `fullSync` for the flush):
///
/// ```text
/// record  = kind:u8 | body
/// 0x01    segment start   body = DayFile header (bodyOffset bytes) | rows…
/// 0x02    rows            body = rows…, appended to the current segment
/// 0x03    imported        body = sha256(file as stored):32 | segment (header | rows)
///                         a whole segment taken in from a plaintext file
///
/// snapshot (a closed day, after compaction) =
///   version:u8 (1) | n:u32 | n × sha256:32 | m:u32 | m × (length:u32 | deflated segment)
///   little-endian; a deflated segment is the segment's bytes through
///   zlib's raw DEFLATE (`Data.compressed(using: .zlib)`), the recipe the
///   plaintext `.bin.z` files documented; compressed first, sealed after.
/// ```
///
/// A segment is the concatenation of its start record's body and every
/// rows record after it, so the stream is exactly what the file held,
/// byte for byte (`export` writes it back).
///
/// **Imports** are how plaintext files migrate without ever repeating or
/// losing a row: the digest of the file's bytes is recorded in the same
/// record as the segment, so after a crash between "sealed" and "plaintext
/// removed" the next run finds the digest, checks, and only removes. The
/// digests survive compaction in the snapshot.
///
/// Everything below runs on the owning store's queue; a keystroke never
/// reaches it.
enum DayCodec {
    static let segmentStart: UInt8 = 1
    static let rows: UInt8 = 2
    static let imported: UInt8 = 3
    static let snapshotVersion: UInt8 = 1
    static let digestSize = 32

    /// The record size every reader and writer of a day journal agrees on
    /// (it is part of what a frame is valid as): far above any day.
    static let options = Journal.Options(maxRecordSize: 256 << 20)

    static func start(header: [UInt8], rows: [UInt8]) -> [UInt8] { [segmentStart] + header + rows }
    static func rowsRecord(_ rows: [UInt8]) -> [UInt8] { [DayCodec.rows] + rows }
    static func importRecord(digest: [UInt8], segment: [UInt8]) -> [UInt8] { [imported] + digest + segment }

    /// What a replay holds, as segments.
    struct Decoded {
        /// Deflated segments folded into a snapshot, closed for good.
        var closed: [[UInt8]] = []
        /// Segments written since, whole.
        var open: [[UInt8]] = []
        var digests: Set<[UInt8]> = []
        /// Records that were not what the format says (counted, never dropped silently).
        var malformed = 0
    }

    static func decode(_ replay: SealedJournal.Replay) -> Decoded {
        var decoded = Decoded()
        if let snapshot = replay.snapshot {
            if !decodeSnapshot(snapshot.bytes, into: &decoded) { decoded.malformed += 1 }
        }
        for record in replay.records {
            let bytes = record.bytes
            guard let kind = bytes.first else {
                decoded.malformed += 1
                continue
            }
            switch kind {
            case segmentStart:
                decoded.open.append(Array(bytes.dropFirst()))
            case rows:
                guard !decoded.open.isEmpty else {
                    decoded.malformed += 1
                    continue
                }
                decoded.open[decoded.open.count - 1].append(contentsOf: bytes.dropFirst())
            case imported:
                guard bytes.count >= 1 + digestSize else {
                    decoded.malformed += 1
                    continue
                }
                decoded.digests.insert(Array(bytes[1..<(1 + digestSize)]))
                decoded.open.append(Array(bytes.dropFirst(1 + digestSize)))
            default:
                decoded.malformed += 1
            }
        }
        return decoded
    }

    static func encodeSnapshot(deflated: [[UInt8]], digests: Set<[UInt8]>) -> [UInt8] {
        var out: [UInt8] = [snapshotVersion]
        out.append(contentsOf: DayFile.leBytes(UInt32(digests.count)))
        for digest in digests.sorted(by: { $0.lexicographicallyPrecedes($1) }) { out.append(contentsOf: digest) }
        out.append(contentsOf: DayFile.leBytes(UInt32(deflated.count)))
        for blob in deflated {
            out.append(contentsOf: DayFile.leBytes(UInt32(blob.count)))
            out.append(contentsOf: blob)
        }
        return out
    }

    static func decodeSnapshot(_ bytes: [UInt8], into decoded: inout Decoded) -> Bool {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return Int(DayFile.readLE(bytes, offset, UInt32.self))
        }
        guard bytes.first == snapshotVersion else { return false }
        offset = 1
        guard let digestCount = u32() else { return false }
        for _ in 0..<digestCount {
            guard offset + digestSize <= bytes.count else { return false }
            decoded.digests.insert(Array(bytes[offset..<(offset + digestSize)]))
            offset += digestSize
        }
        guard let count = u32() else { return false }
        for _ in 0..<count {
            guard let length = u32(), offset + length <= bytes.count else { return false }
            decoded.closed.append(Array(bytes[offset..<(offset + length)]))
            offset += length
        }
        return offset == bytes.count
    }

    static func deflate(_ bytes: [UInt8]) -> [UInt8]? {
        (try? (Data(bytes) as NSData).compressed(using: .zlib)).map { [UInt8]($0 as Data) }
    }

    static func inflate(_ bytes: [UInt8]) -> [UInt8]? {
        (try? (Data(bytes) as NSData).decompressed(using: .zlib)).map { [UInt8]($0 as Data) }
    }
}

/// What a day holds, however it is stored.
struct DayContents {
    /// Whole segments (header first): the sealed journal's, in order, then
    /// the plaintext remnants not yet taken in.
    var segments: [[UInt8]] = []
    /// The journal exists and no key can be asked for it.
    var unavailable = false
    /// Sealed values, files or records that would not open or decode: never
    /// read as empty.
    var failures = 0
    /// Plaintext files already taken in, by digest (so they are not read twice).
    var imported: Set<[UInt8]> = []
    /// The first segments, deflated as a closed day stored them (the same
    /// bytes a `.bin.z` file held): `segments` begins with these, inflated.
    var closed: [[UInt8]] = []
}

enum DayStore {
    /// What the day journals are sealed for.
    static let purpose = "lodestar.days"

    static func journalName(prefix: String, day: String) -> String { "\(prefix)-\(day).sj" }

    static func context(purpose: String, prefix: String, day: String) -> SealContext {
        SealContext(purpose, prefix, day)
    }

    /// The days that have a sealed journal.
    static func sealedDays(prefix: String, in directory: String, fileSystem: any FileSystem) -> [String] {
        var days: Set<String> = []
        for name in RecordFiles.names(in: directory, fileSystem: fileSystem)
        where name.hasPrefix(prefix + "-") && name.hasSuffix(RecordFiles.journalSuffix) {
            let day = String(name.dropFirst(prefix.count + 1).dropLast(RecordFiles.journalSuffix.count))
            if day.count == 10 { days.insert(day) }
        }
        return days.sorted()
    }

    /// Every day with a sealed journal or a plaintext file, oldest first.
    static func days(prefix: String, in directory: URL, fileSystem: any FileSystem) -> [String] {
        let sealed = sealedDays(prefix: prefix, in: directory.path, fileSystem: fileSystem)
        let plain = DayFile.days(prefix: prefix, in: directory, fileSystem: fileSystem)
        return Array(Set(sealed).union(plain)).sorted()
    }

    /// One day, sealed and plaintext, with the plaintext files already
    /// taken into the journal left out.
    static func read(
        prefix: String, purpose: String, day: String, in directory: URL, ring: Vault.Ring?,
        fileSystem: any FileSystem
    ) -> DayContents {
        var contents = DayContents()
        let path = directory.appendingPathComponent(journalName(prefix: prefix, day: day)).path
        switch SealedRead.replay(
            at: path, context: context(purpose: purpose, prefix: prefix, day: day), ring: ring,
            fileSystem: fileSystem, options: DayCodec.options
        ) {
        case .absent:
            break
        case .unavailable:
            contents.unavailable = true
        case .failed:
            contents.failures += 1
        case .opened(let replay):
            let decoded = DayCodec.decode(replay)
            contents.failures += replay.failures.count + decoded.malformed
            for blob in decoded.closed {
                if let raw = DayCodec.inflate(blob) {
                    contents.segments.append(raw)
                    contents.closed.append(blob)
                } else {
                    contents.failures += 1
                }
            }
            contents.segments.append(contentsOf: decoded.open)
            contents.imported = decoded.digests
        }
        for segment in DayFile.segments(prefix: prefix, in: directory, fileSystem: fileSystem) where segment.day == day {
            guard let stored = try? fileSystem.readAll(segment.url.path) else { continue }
            if contents.imported.contains(Digest.sha256(stored)) { continue }
            let raw = segment.compressed ? DayCodec.inflate(stored) : stored
            guard let raw, DayFile.readHeader(Data(raw)) != nil else {
                contents.failures += 1
                continue
            }
            contents.segments.append(raw)
        }
        return contents
    }
}

/// The writer of one store's day journals.
///
/// Not thread-safe by itself: every call is made on the owning store's queue.
final class DayWriter {
    let prefix: String
    let purpose: String
    let directory: URL
    let ring: Vault.Ring
    let fileSystem: any FileSystem
    /// How many bytes of a body are whole rows, for stores whose rows vary
    /// in length (a pointer reach carries its samples); nil for fixed-size rows.
    let wholeLength: (([UInt8]) -> Int)?

    /// A day's open journal, and whether the next rows may join its last
    /// segment: the header they would have, as its fingerprint.
    private final class OpenDay {
        let journal: SealedJournal
        var continuing: String?
        var imported: Set<[UInt8]>
        init(journal: SealedJournal, continuing: String?, imported: Set<[UInt8]>) {
            self.journal = journal
            self.continuing = continuing
            self.imported = imported
        }
    }

    private var open: [String: OpenDay] = [:]

    init(prefix: String, purpose: String, directory: URL, ring: Vault.Ring, fileSystem: any FileSystem,
         wholeLength: (([UInt8]) -> Int)? = nil) {
        self.prefix = prefix
        self.purpose = purpose
        self.directory = directory
        self.ring = ring
        self.fileSystem = fileSystem
        self.wholeLength = wholeLength
    }

    func path(day: String) -> String {
        directory.appendingPathComponent(DayStore.journalName(prefix: prefix, day: day)).path
    }

    private func context(day: String) -> SealContext {
        DayStore.context(purpose: purpose, prefix: prefix, day: day)
    }

    // MARK: Opening

    private enum OpenError: Error { case paused, failed(String) }

    private func openDay(_ day: String) throws -> OpenDay {
        if let known = open[day] { return known }
        guard let keyring = ring.keyring() else { throw OpenError.paused }
        SealedDirectory.ensure(directory.path, fileSystem: fileSystem)
        do {
            let journal = try SealedJournal.open(
                at: path(day: day), context: context(day: day), keyring: keyring, fileSystem: fileSystem,
                options: DayCodec.options)
            let replay = try journal.replay()
            let decoded = DayCodec.decode(replay)
            SealedFailures.note(replay.failures, file: DayStore.journalName(prefix: prefix, day: day))
            var continuing: String?
            // The last segment takes more rows only when everything in the
            // journal opened and it is whole to its end. Otherwise the next
            // rows open a segment of their own.
            if replay.failures.isEmpty, decoded.malformed == 0, let last = decoded.open.last,
               let header = DayFile.readHeader(Data(last)), header.recordSize > 0, last.count >= header.bodyOffset {
                let body = Array(last.dropFirst(header.bodyOffset))
                let whole = wholeLength.map { $0(body) == body.count } ?? (body.count % Int(header.recordSize) == 0)
                if whole { continuing = header.fingerprint }
            }
            return OpenDay(journal: journal, continuing: continuing, imported: decoded.digests)
        } catch {
            throw OpenError.failed("\(error)")
        }
    }

    private func remember(_ day: String, _ opened: OpenDay) { open[day] = opened }

    func closeAll() {
        for (_, day) in open { try? day.journal.close() }
        open = [:]
    }

    private func forget(_ day: String) {
        if let known = open.removeValue(forKey: day) { try? known.journal.close() }
    }

    // MARK: Appending

    /// One run of rows under a header, for one day.
    struct Run {
        var header: DayFile.Header
        var rows: [UInt8]
    }

    enum AppendResult { case written, paused, failed }

    /// Append the runs of one day: each continues the day's last segment when
    /// the header it would have is the one that segment has and the segment
    /// ends whole, and opens a new one otherwise. One journal append (one
    /// sync) for all of them.
    func append(day: String, runs: [Run]) -> AppendResult {
        guard !runs.isEmpty else { return .written }
        do {
            let opened: OpenDay
            if let known = open[day] {
                opened = known
            } else {
                opened = try openDay(day)
                remember(day, opened)
            }
            var records: [[UInt8]] = []
            var continuing = opened.continuing
            for run in runs {
                let fingerprint = run.header.fingerprint
                if continuing == fingerprint {
                    records.append(DayCodec.rowsRecord(run.rows))
                } else {
                    records.append(DayCodec.start(header: [UInt8](DayFile.encode(run.header)), rows: run.rows))
                    continuing = fingerprint
                }
            }
            try opened.journal.append(batch: records)
            opened.continuing = continuing
            return .written
        } catch OpenError.paused {
            return .paused
        } catch {
            // A journal that failed an append may or may not hold the record;
            // it is reopened (and its end re-read) at the next flush.
            forget(day)
            Log.error("\(prefix): could not append to the \(day) journal (\(error))")
            return .failed
        }
    }

    // MARK: Closing days

    /// Every day before `current` whose journal still has records is folded
    /// into one snapshot of deflated segments (compressed, then sealed): what
    /// compressing a closed day's files was. A day with anything that does
    /// not open is left as it is.
    func closeDays(before current: String) {
        for day in DayStore.sealedDays(prefix: prefix, in: directory.path, fileSystem: fileSystem) where day < current {
            guard let size = logSize(of: path(day: day)), size > 0 else { continue }
            do {
                let opened: OpenDay
                if let known = open[day] { opened = known } else { opened = try openDay(day) }
                let replay = try opened.journal.replay()
                let decoded = DayCodec.decode(replay)
                guard replay.failures.isEmpty, decoded.malformed == 0 else {
                    Log.error("\(prefix): the \(day) journal has values that do not open — not compacted")
                    forget(day)
                    continue
                }
                var deflated = decoded.closed
                var packed = true
                for segment in decoded.open {
                    if let blob = DayCodec.deflate(segment) { deflated.append(blob) } else { packed = false }
                }
                guard packed else {
                    Log.error("\(prefix): the \(day) journal could not be deflated — not compacted")
                    forget(day)
                    continue
                }
                try opened.journal.compact(snapshot: DayCodec.encodeSnapshot(deflated: deflated, digests: decoded.digests))
                forget(day)
            } catch OpenError.paused {
                return
            } catch {
                Log.error("\(prefix): could not compact the \(day) journal (\(error))")
                forget(day)
            }
        }
    }

    private func logSize(of path: String) -> Int? {
        guard (try? fileSystem.exists(path)) == true, let file = try? fileSystem.open(path, mode: .read) else { return nil }
        defer { _ = try? fileSystem.close(file) }
        return try? fileSystem.size(of: file)
    }

    // MARK: Migrating plaintext

    typealias Migration = RecordMigration

    /// Take every plaintext day file of this store into its journal: the
    /// segment is appended with the digest of the file, read back from disk
    /// and compared byte for byte with what the file held, and only then is
    /// the file removed. Resumable at every step: a crash leaves the file, or
    /// the file and its sealed copy (found by digest and only removed, never
    /// appended twice), never neither. The same path merges plaintext an
    /// older build wrote after this one sealed the day.
    func migrate(decodedCount: (([UInt8]) -> Int)? = nil) -> Migration {
        var outcome = Migration()
        let plain = DayFile.segments(prefix: prefix, in: directory, fileSystem: fileSystem)
        guard !plain.isEmpty else { return outcome }
        for segment in plain {
            let name = segment.url.lastPathComponent
            do {
                let stored = try fileSystem.readAll(segment.url.path)
                let digest = Digest.sha256(stored)
                guard let raw = segment.compressed ? DayCodec.inflate(stored) : stored,
                      DayFile.readHeader(Data(raw)) != nil
                else {
                    // Not a day file this build can read: left exactly as it is.
                    outcome.remaining += 1
                    outcome.failed.append(name)
                    Log.error("\(prefix): \(name) is not a readable day file — left as it is")
                    continue
                }
                let opened: OpenDay
                if let known = open[segment.day] {
                    opened = known
                } else {
                    opened = try openDay(segment.day)
                    remember(segment.day, opened)
                }
                if !opened.imported.contains(digest) {
                    do {
                        try opened.journal.append(DayCodec.importRecord(digest: digest, segment: raw))
                    } catch {
                        forget(segment.day)
                        throw error
                    }
                    opened.imported.insert(digest)
                    // An import is a segment of its own: the next rows must not join it.
                    opened.continuing = nil
                }
                guard try verified(day: segment.day, digest: digest, raw: raw, decodedCount: decodedCount) else {
                    outcome.remaining += 1
                    outcome.failed.append(name)
                    Log.error("\(prefix): \(name) did not read back from the journal as it was written — the plaintext was kept")
                    continue
                }
                try fileSystem.remove(segment.url.path)
                try fileSystem.syncDirectory(directory.path)
                outcome.files += 1
                outcome.bytes += Int64(stored.count)
            } catch OpenError.paused {
                outcome.paused = true
                outcome.remaining += 1
                // Every other file is as paused as this one.
                outcome.remaining += plain.filter { $0.url.path > segment.url.path }.count
                return outcome
            } catch {
                outcome.remaining += 1
                outcome.failed.append(name)
                Log.error("\(prefix): could not take \(name) into its journal (\(error)) — the plaintext was kept")
            }
        }
        return outcome
    }

    /// The segment with this digest, read back from the file on disk (not
    /// from memory), is these bytes, and decodes to as many rows.
    private func verified(day: String, digest: [UInt8], raw: [UInt8], decodedCount: (([UInt8]) -> Int)?) throws -> Bool {
        guard let keyring = ring.keyring() else { throw OpenError.paused }
        let replay = try SealedJournal.readOnlyReplay(
            at: path(day: day), context: context(day: day), keyring: keyring, fileSystem: fileSystem,
            options: DayCodec.options)
        guard replay.failures.isEmpty else { return false }
        // The record is either still a record (its body carries the digest) or
        // was folded into a snapshot by a compaction that ran since: there the
        // segment is a deflated blob, possibly with rows that joined it after.
        for record in replay.records where record.bytes.first == DayCodec.imported {
            guard record.bytes.count >= 1 + DayCodec.digestSize,
                  Array(record.bytes[1..<(1 + DayCodec.digestSize)]) == digest else { continue }
            let body = Array(record.bytes.dropFirst(1 + DayCodec.digestSize))
            if body != raw { return false }
            if let decodedCount, decodedCount(body) != decodedCount(raw) { return false }
            return true
        }
        if let snapshot = replay.snapshot {
            var decoded = DayCodec.Decoded()
            guard DayCodec.decodeSnapshot(snapshot.bytes, into: &decoded), decoded.digests.contains(digest) else { return false }
            return decoded.closed.contains { blob in DayCodec.inflate(blob).map { $0.starts(with: raw) } ?? false }
        }
        return false
    }
}
