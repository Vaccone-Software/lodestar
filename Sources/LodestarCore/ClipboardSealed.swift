import Foundation
import StoicSealed
import StoicStore

/// What a sealed clipboard history is made of: the **entries** the index
/// holds, the **operations** its journal records, the **container** a blob
/// file holds, and the contexts everything is sealed under. Pure; the disk
/// work is `SealedClipboard`.
///
/// ```text
/// clipboard/
///   v2/
///     index.sj            SealedJournal, ring `clipboard`, context ("lodestar.clipboard.index")
///     index.sj.snapshot   (and Stoic's other sidecars)
///     items/<storage>     one sealed file per clip: every item and representation,
///                         under the clip's own key, context ("lodestar.clipboard.blob", storage)
///     thumbs/<storage>    the clip's thumbnail (a PNG), same key, context ("lodestar.clipboard.thumb", storage)
/// ```
///
/// `storage` is 16 random bytes in hex and `blobKey` a per-clip `SealingKey`
/// (`exportedForWrapping()`); **both exist only inside sealed records**, so a
/// file name says nothing of what is in it, and a clip is made unrecoverable
/// by dropping its record and compacting with a key rotation (the clip's key
/// was in a record the rotation made unreadable).
public enum ClipboardSealed {
    public static let indexPurpose = "lodestar.clipboard.index"
    public static let blobPurpose = "lodestar.clipboard.blob"
    public static let thumbPurpose = "lodestar.clipboard.thumb"

    public static var indexContext: SealContext { SealContext(indexPurpose) }
    public static func blobContext(_ storage: String) -> SealContext { SealContext(blobPurpose, storage) }
    public static func thumbContext(_ storage: String) -> SealContext { SealContext(thumbPurpose, storage) }

    /// Every reader and writer of the index agrees on this: the record size
    /// is part of what a frame is valid as. The snapshot is the whole index
    /// (a few megabytes), so it is far above what an operation needs.
    public static let journalOptions = Journal.Options(maxRecordSize: 64 << 20)

    /// A fresh storage name: 16 random bytes, in hex.
    public static func newStorage() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }

    /// Whether `name` is a storage name this build makes (so that nothing
    /// else a person or a tool dropped in `items/` is ever mistaken for one
    /// and removed).
    public static func isStorageName(_ name: String) -> Bool {
        name.utf8.count == 32 && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

// MARK: - The container

/// What one pasteboard item holds, as it is stored and put back: the plain
/// text form, and every richer form the source app offered beside it.
public enum ClipboardContent {
    public struct Item {
        public var plain: Data?
        public var natives: [(type: String, data: Data)]

        public init(plain: Data?, natives: [(type: String, data: Data)]) {
            self.plain = plain
            self.natives = natives
        }

        /// The same bytes, whatever the order they arrived in the arrays.
        public func sameBytes(as other: Item) -> Bool {
            plain == other.plain && natives.count == other.natives.count
                && zip(natives, other.natives).allSatisfy { $0.type == $1.type && $0.data == $1.data }
        }
    }

    public static func sameBytes(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.sameBytes(as: $1) }
    }

    /// The blob's plaintext, before it is sealed:
    ///
    /// ```text
    /// version:u8 (1) | items:u32 | items × item          little-endian
    /// item = flags:u8 (bit 0: has a plain form) | [plain length:u64 | plain]
    ///        | natives:u16 | natives × (type length:u16 | type (UTF-8) | length:u64 | bytes)
    /// ```
    public static func encode(_ items: [Item]) -> [UInt8] {
        var size = 5
        for item in items {
            size += 1 + (item.plain.map { 8 + $0.count } ?? 0) + 2
            for native in item.natives { size += 2 + native.type.utf8.count + 8 + native.data.count }
        }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        out.append(1)
        append(&out, UInt32(items.count))
        for item in items {
            out.append(item.plain == nil ? 0 : 1)
            if let plain = item.plain {
                append(&out, UInt64(plain.count))
                out.append(contentsOf: plain)
            }
            append(&out, UInt16(item.natives.count))
            for native in item.natives {
                let type = Array(native.type.utf8)
                append(&out, UInt16(type.count))
                out.append(contentsOf: type)
                append(&out, UInt64(native.data.count))
                out.append(contentsOf: native.data)
            }
        }
        return out
    }

    /// The items a blob's plaintext holds, or nil if it is not one.
    public static func decode(_ bytes: [UInt8]) -> [Item]? {
        var offset = 0
        func take(_ count: Int) -> Range<Int>? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return offset..<(offset + count)
        }
        func integer<T: FixedWidthInteger>(_ type: T.Type) -> Int? {
            guard let range = take(MemoryLayout<T>.size) else { return nil }
            var value: T = 0
            for (shift, byte) in bytes[range].enumerated() { value |= T(truncatingIfNeeded: byte) << (8 * shift) }
            return Int(exactly: value)
        }
        guard bytes.first == 1 else { return nil }
        offset = 1
        guard let count = integer(UInt32.self) else { return nil }
        var items: [Item] = []
        for _ in 0..<count {
            guard let flags = take(1).map({ bytes[$0.lowerBound] }) else { return nil }
            var plain: Data?
            if flags & 1 != 0 {
                guard let length = integer(UInt64.self), let range = take(length) else { return nil }
                plain = Data(bytes[range])
            }
            guard let natives = integer(UInt16.self) else { return nil }
            var forms: [(type: String, data: Data)] = []
            for _ in 0..<natives {
                guard let typeLength = integer(UInt16.self), let typeRange = take(typeLength),
                      let type = String(bytes: bytes[typeRange], encoding: .utf8),
                      let length = integer(UInt64.self), let range = take(length) else { return nil }
                forms.append((type, Data(bytes[range])))
            }
            items.append(Item(plain: plain, natives: forms))
        }
        return offset == bytes.count ? items : nil
    }

    private static func append<T: FixedWidthInteger>(_ out: inout [UInt8], _ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
    }
}

// MARK: - The index

/// A clip, and where its bytes are and what opens them.
public struct ClipEntry: Codable, Equatable {
    public var clip: Clipboard.Clip
    /// The blob's (and the thumbnail's) file name.
    public var storage: String
    /// The clip's own `SealingKey`, exported (`exportedForWrapping()`).
    public var blobKey: Data

    public init(clip: Clipboard.Clip, storage: String, blobKey: Data) {
        self.clip = clip
        self.storage = storage
        self.blobKey = blobKey
    }

    public var key: SealingKey? { SealingKey(importing: [UInt8](blobKey)) }
}

/// One change to the index, as the journal records it: a few hundred bytes
/// for a copy, instead of the whole index rewritten.
///
/// The operations carry the clip **as the caller's own rules left it** (a
/// re-copy's merge with the card it lands on, an edit keeping its card's
/// place and pin), and replaying them only places it, so the rules live in one
/// place (`Clipboard.merging`, `Clipboard.replacing`) and a replay can never
/// disagree with what was on screen.
public enum ClipboardOp: Codable, Equatable {
    /// A copy: the card with this id (if there is one) goes, this one is the newest.
    case front(ClipEntry)
    /// The v1 migration: the next card in the old order, after the others.
    case tail(ClipEntry)
    /// The downgrade merge: this card, by its age, among the others.
    case ordered(ClipEntry)
    /// A card changed where it stands (a keepsake, a name, a caption, counts).
    /// A card that is no longer there stays gone.
    case set(ClipEntry)
    /// An edit: this card takes the place of `old`.
    case replace(old: String, ClipEntry)
    case delete([String])
    /// A v1 index (by the SHA-256 of its bytes) whose clips are all in here:
    /// what lets a migration that was interrupted after this record only
    /// remove the old files, and a merge that was repeated not repeat itself.
    case imported(digest: String)

    private struct Wire: Codable {
        var op: String
        var entry: ClipEntry?
        var old: String?
        var ids: [String]?
        var digest: String?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        func entry() throws -> ClipEntry {
            guard let entry = wire.entry else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no entry")) }
            return entry
        }
        switch wire.op {
        case "front": self = .front(try entry())
        case "tail": self = .tail(try entry())
        case "ordered": self = .ordered(try entry())
        case "set": self = .set(try entry())
        case "replace":
            guard let old = wire.old else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no old")) }
            self = .replace(old: old, try entry())
        case "delete": self = .delete(wire.ids ?? [])
        case "imported": self = .imported(digest: wire.digest ?? "")
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown op"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var wire = Wire(op: "")
        switch self {
        case .front(let entry): wire.op = "front"; wire.entry = entry
        case .tail(let entry): wire.op = "tail"; wire.entry = entry
        case .ordered(let entry): wire.op = "ordered"; wire.entry = entry
        case .set(let entry): wire.op = "set"; wire.entry = entry
        case .replace(let old, let entry): wire.op = "replace"; wire.old = old; wire.entry = entry
        case .delete(let ids): wire.op = "delete"; wire.ids = ids
        case .imported(let digest): wire.op = "imported"; wire.digest = digest
        }
        try wire.encode(to: encoder)
    }

    /// The storage names this operation points at.
    public var storages: [String] {
        switch self {
        case .front(let entry), .tail(let entry), .ordered(let entry), .set(let entry), .replace(_, let entry): [entry.storage]
        case .delete, .imported: []
        }
    }
}

/// The index as the operations leave it.
public struct ClipboardIndexState: Equatable {
    /// Newest first.
    public var entries: [ClipEntry] = []
    /// The v1 indexes (digests) already folded in.
    public var imported: Set<String> = []

    public init(entries: [ClipEntry] = [], imported: Set<String> = []) {
        self.entries = entries
        self.imported = imported
    }

    public mutating func apply(_ op: ClipboardOp) {
        switch op {
        case .front(let entry):
            entries.removeAll { $0.clip.id == entry.clip.id }
            entries.insert(entry, at: 0)
        case .tail(let entry):
            entries.removeAll { $0.clip.id == entry.clip.id }
            entries.append(entry)
        case .ordered(let entry):
            entries.removeAll { $0.clip.id == entry.clip.id }
            let position = entries.firstIndex { $0.clip.created < entry.clip.created } ?? entries.endIndex
            entries.insert(entry, at: position)
        case .set(let entry):
            if let position = entries.firstIndex(where: { $0.clip.id == entry.clip.id }) { entries[position] = entry }
        case .replace(let old, let entry):
            if let position = entries.firstIndex(where: { $0.clip.id == old }) {
                entries[position] = entry
                // The new text may already be a card of its own: one card per id.
                entries = entries.enumerated().filter { $0.offset == position || $0.element.clip.id != entry.clip.id }
                    .map(\.element)
            }
        case .delete(let ids):
            let gone = Set(ids)
            entries.removeAll { gone.contains($0.clip.id) }
        case .imported(let digest):
            imported.insert(digest)
        }
    }

    private struct Snapshot: Codable {
        var version = 1
        var entries: [ClipEntry]
        var imported: [String]
    }

    public func snapshot() -> [UInt8]? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Snapshot(entries: entries, imported: imported.sorted())) else { return nil }
        return [UInt8](data)
    }

    public static func decoding(snapshot bytes: [UInt8]) -> ClipboardIndexState? {
        guard let decoded = try? JSONDecoder().decode(Snapshot.self, from: Data(bytes)), decoded.version == 1 else { return nil }
        return ClipboardIndexState(entries: decoded.entries, imported: Set(decoded.imported))
    }

    /// What a replay held: the state, and how many of its values were not
    /// what the format says (counted; never read as nothing).
    public struct Folded {
        public var state: ClipboardIndexState
        public var malformed: Int
        /// Records applied after the snapshot.
        public var records: Int
        public var snapshotBytes: Int
        /// Deletes and replacements among those records: clips whose keys are
        /// still in a record that opens, until the next fold rotates the key.
        public var removals: Int
    }

    public static func fold(_ replay: SealedJournal.Replay) -> Folded {
        var state = ClipboardIndexState()
        var malformed = 0
        var snapshotBytes = 0
        if let snapshot = replay.snapshot {
            snapshotBytes = snapshot.bytes.count
            if let decoded = decoding(snapshot: snapshot.bytes) { state = decoded } else { malformed += 1 }
        }
        let decoder = JSONDecoder()
        var removals = 0
        for record in replay.records {
            guard let op = try? decoder.decode(ClipboardOp.self, from: Data(record.bytes)) else {
                malformed += 1
                continue
            }
            switch op {
            case .delete, .replace: removals += 1
            default: break
            }
            state.apply(op)
        }
        return Folded(state: state, malformed: malformed, records: replay.records.count, snapshotBytes: snapshotBytes,
                      removals: removals)
    }

    public static func encode(_ op: ClipboardOp) -> [UInt8]? {
        (try? JSONEncoder().encode(op)).map { [UInt8]($0) }
    }
}
