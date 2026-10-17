import Foundation
import StoicSealed
import StoicStore

/// A log of JSONL lines (the behavioral ring and the health log), sealed.
///
/// A log file `events.jsonl` is one `SealedJournal`, `events.sj`, sealed
/// with the context `("lodestar.events", "events")` (the file's stem; a
/// shard is `events-2026-08.sj` and says so in its context). What it holds:
///
/// ```text
/// record  = kind:u8 | body
/// 0x01    lines      body = the lines of one flush, each ending in "\\n"
/// 0x02    imported   body = sha256(file as stored):32 | lines
///                    a whole plaintext file taken in; its lines end in "\\n"
///                    whether the file's last one did or not
///
/// snapshot (after a compaction) =
///   version:u8 (1) | n:u32 | n × sha256:32 | the lines that remain
/// ```
///
/// Reading is the lines in order: the snapshot's, then each record's.
/// Lines are never decoded to be moved: a kind or a field this build does
/// not know travels as the bytes it is, and a line that is not JSON is kept
/// (the reader skips it, as it always did). A sealed *record* that fails to
/// open is not a line that fails to decode: it is counted and logged
/// (`SealedFailures`), and the reader says the log is not whole.
///
/// The digests are how a plaintext file taken in by migration is told from
/// one an older build wrote afterwards: a file whose digest is already in
/// the journal was taken in and only needs removing; any other is new, and
/// is appended after what is there.
enum LineCodec {
    static let batch: UInt8 = 1
    static let imported: UInt8 = 2
    static let snapshotVersion: UInt8 = 1
    static let digestSize = 32

    static let options = Journal.Options(maxRecordSize: 256 << 20)

    /// Lines as bytes, each ending in a newline: an unterminated last line
    /// (a write torn by a crash) is terminated, so what follows it in the
    /// journal is a line of its own.
    static func terminated(_ bytes: [UInt8]) -> [UInt8] {
        guard let last = bytes.last, last != 0x0A else { return bytes }
        return bytes + [0x0A]
    }

    static func batchRecord(_ lines: [UInt8]) -> [UInt8] { [batch] + lines }
    static func importRecord(digest: [UInt8], lines: [UInt8]) -> [UInt8] { [imported] + digest + lines }

    struct Decoded {
        var lines: [UInt8] = []
        var digests: Set<[UInt8]> = []
        var malformed = 0
    }

    static func decode(_ replay: SealedJournal.Replay) -> Decoded {
        var decoded = Decoded()
        if let snapshot = replay.snapshot {
            if !decodeSnapshot(snapshot.bytes, into: &decoded) { decoded.malformed += 1 }
        }
        for record in replay.records {
            let bytes = record.bytes
            switch bytes.first {
            case batch:
                decoded.lines.append(contentsOf: bytes.dropFirst())
            case imported:
                guard bytes.count >= 1 + digestSize else {
                    decoded.malformed += 1
                    continue
                }
                decoded.digests.insert(Array(bytes[1..<(1 + digestSize)]))
                decoded.lines.append(contentsOf: bytes.dropFirst(1 + digestSize))
            default:
                decoded.malformed += 1
            }
        }
        return decoded
    }

    static func encodeSnapshot(lines: [UInt8], digests: Set<[UInt8]>) -> [UInt8] {
        var out: [UInt8] = [snapshotVersion]
        out.append(contentsOf: DayFile.leBytes(UInt32(digests.count)))
        for digest in digests.sorted(by: { $0.lexicographicallyPrecedes($1) }) { out.append(contentsOf: digest) }
        out.append(contentsOf: lines)
        return out
    }

    private static func decodeSnapshot(_ bytes: [UInt8], into decoded: inout Decoded) -> Bool {
        guard bytes.first == snapshotVersion, bytes.count >= 5 else { return false }
        let count = Int(DayFile.readLE(bytes, 1, UInt32.self))
        var offset = 5
        for _ in 0..<count {
            guard offset + digestSize <= bytes.count else { return false }
            decoded.digests.insert(Array(bytes[offset..<(offset + digestSize)]))
            offset += digestSize
        }
        decoded.lines.append(contentsOf: bytes[offset...])
        return true
    }
}

/// What a log holds, however it is stored.
struct LineContents {
    /// Every line, each ending in a newline: the sealed journal's, then the
    /// plaintext remnants not yet taken in.
    var bytes = Data()
    /// The journal exists and no key can be asked for it.
    var unavailable = false
    /// Sealed values or files that would not open or decode; the log is not whole.
    var failures = 0
    var imported: Set<[UInt8]> = []

    var whole: Bool { !unavailable && failures == 0 }
}

enum LineStore {
    static let purpose = "lodestar.events"

    /// `events.jsonl` and `events-2026-08.jsonl` name their sealed journal
    /// `events.sj` and `events-2026-08.sj`; the stem is the context's id.
    static func journalPath(forPlaintext url: URL) -> String {
        url.deletingPathExtension().appendingPathExtension("sj").path
    }

    static func context(forPlaintext url: URL) -> SealContext {
        SealContext(purpose, url.deletingPathExtension().lastPathComponent)
    }

    /// The log at `plaintext` (its legacy name): sealed lines, then the
    /// plaintext remnants an older build wrote or migration has not taken
    /// in yet, none counted twice.
    static func read(plaintext url: URL, ring: Vault.Ring?, fileSystem: any FileSystem) -> LineContents {
        var contents = LineContents()
        switch SealedRead.replay(
            at: journalPath(forPlaintext: url), context: context(forPlaintext: url), ring: ring,
            fileSystem: fileSystem, options: LineCodec.options
        ) {
        case .absent:
            break
        case .unavailable:
            contents.unavailable = true
        case .failed:
            contents.failures += 1
        case .opened(let replay):
            let decoded = LineCodec.decode(replay)
            contents.failures += replay.failures.count + decoded.malformed
            contents.bytes = Data(decoded.lines)
            contents.imported = decoded.digests
        }
        if let stored = try? fileSystem.readAll(url.path), !stored.isEmpty,
           !contents.imported.contains(Digest.sha256(stored)) {
            contents.bytes.append(contentsOf: LineCodec.terminated(stored))
        }
        return contents
    }

    /// The lines of a buffer, as the reader sees them: split on newlines,
    /// empty ones skipped.
    static func lines(_ bytes: Data) -> [Data] {
        bytes.split(separator: 0x0A).map { Data($0) }
    }
}

/// One log file's sealed journal, held open by its writer.
///
/// Not thread-safe by itself: the owning log calls it on its own queue.
final class LineJournal {
    let plaintext: URL
    let ring: Vault.Ring
    let fileSystem: any FileSystem
    private var journal: SealedJournal?

    init(plaintext: URL, ring: Vault.Ring, fileSystem: any FileSystem) {
        self.plaintext = plaintext
        self.ring = ring
        self.fileSystem = fileSystem
    }

    var path: String { LineStore.journalPath(forPlaintext: plaintext) }
    private var context: SealContext { LineStore.context(forPlaintext: plaintext) }

    enum Failure: Error { case paused, failed(String) }

    func open() throws -> SealedJournal {
        if let journal { return journal }
        guard let keyring = ring.keyring() else { throw Failure.paused }
        SealedDirectory.ensure(SealedPath.directory(of: path), fileSystem: fileSystem)
        do {
            let opened = try SealedJournal.open(
                at: path, context: context, keyring: keyring, fileSystem: fileSystem, options: LineCodec.options)
            journal = opened
            return opened
        } catch {
            throw Failure.failed("\(error)")
        }
    }

    func close() {
        if let journal { try? journal.close() }
        journal = nil
    }

    /// Append one flush's lines (each ending in a newline).
    func append(lines: Data) throws {
        do {
            try open().append(LineCodec.batchRecord([UInt8](lines)))
        } catch let failure as Failure {
            throw failure
        } catch {
            // A journal that failed an append may or may not hold the record;
            // it is reopened (and its end re-read) at the next flush.
            close()
            throw Failure.failed("\(error)")
        }
    }

    /// Replace everything the journal holds with `lines`, keeping the
    /// digests of the plaintext files already taken in. The caller has
    /// read the journal whole (nothing failed to open) and appended nothing since.
    func replace(with lines: Data, digests: Set<[UInt8]>) throws {
        do {
            try open().compact(snapshot: LineCodec.encodeSnapshot(lines: [UInt8](lines), digests: digests))
        } catch let failure as Failure {
            throw failure
        } catch {
            close()
            throw Failure.failed("\(error)")
        }
    }

    // MARK: Migrating

    /// Take the plaintext file at `plaintext` into this journal: appended with
    /// its digest, read back from disk and compared with what the file held,
    /// and only then removed. Resumable: a crash leaves the file, or the file
    /// and its sealed copy (found by digest, and only removed). Returns the
    /// bytes taken in, or nil when there was no file.
    func migratePlaintext(decodedCount: (Data) -> Int) throws -> Int? {
        guard (try? fileSystem.exists(plaintext.path)) == true else { return nil }
        let stored = try fileSystem.readAll(plaintext.path)
        if stored.isEmpty {
            try fileSystem.remove(plaintext.path)
            try fileSystem.syncDirectory(SealedPath.directory(of: plaintext.path))
            return 0
        }
        let digest = Digest.sha256(stored)
        let lines = LineCodec.terminated(stored)
        let journal = try open()
        let before = try replayForMigration()
        if !before.digests.contains(digest) {
            do {
                try journal.append(LineCodec.importRecord(digest: digest, lines: lines))
            } catch {
                close()
                throw error
            }
        }
        guard try verify(digest: digest, lines: lines, decodedCount: decodedCount) else {
            throw Failure.failed("did not read back as it was written")
        }
        try fileSystem.remove(plaintext.path)
        try fileSystem.syncDirectory(SealedPath.directory(of: plaintext.path))
        return stored.count
    }

    private func replayForMigration() throws -> LineCodec.Decoded {
        guard let keyring = ring.keyring() else { throw Failure.paused }
        let replay = try SealedJournal.readOnlyReplay(
            at: path, context: context, keyring: keyring, fileSystem: fileSystem, options: LineCodec.options)
        return LineCodec.decode(replay)
    }

    private func verify(digest: [UInt8], lines: [UInt8], decodedCount: (Data) -> Int) throws -> Bool {
        guard let keyring = ring.keyring() else { throw Failure.paused }
        let replay = try SealedJournal.readOnlyReplay(
            at: path, context: context, keyring: keyring, fileSystem: fileSystem, options: LineCodec.options)
        guard replay.failures.isEmpty else { return false }
        let want = Data(lines)
        for record in replay.records where record.bytes.first == LineCodec.imported {
            guard record.bytes.count >= 1 + LineCodec.digestSize,
                  Array(record.bytes[1..<(1 + LineCodec.digestSize)]) == digest else { continue }
            let body = Data(record.bytes.dropFirst(1 + LineCodec.digestSize))
            return body == want && decodedCount(body) == decodedCount(want)
        }
        // Folded into a snapshot by a compaction since, which may have moved
        // its months to their shards: the digest is the proof that this very
        // file was taken in whole, and the lines were checked when it was.
        return LineCodec.decode(replay).digests.contains(digest)
    }
}
