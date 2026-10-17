import CryptoKit
import Foundation

/// The clipboard history as every build before the sealed one wrote it: a
/// plain `index.json` of clips, with each clip's representations as ordinary
/// files beside it under deterministic names. Read by the migration, written
/// by nothing here (a test writes it, and an older build downgraded to still
/// does).
///
/// ```text
/// clipboard/
///   index.json            {"version":1,"clips":[…]}   the clips, newest first
///   items/<id>.plain             item 0's plain text
///   items/<id>.type<N>           item 0's Nth representation, richest first
///   items/<id>.i<k>.plain        item k's plain text   (k ≥ 1)
///   items/<id>.i<k>.type<N>      item k's Nth representation
///   thumbs/<id>.png              an image's thumbnail
///   index.json.corrupt-<stamp>   an index an older build could not decode, set aside
/// ```
public enum ClipboardV1 {
    public struct Index: Codable {
        public var version: Int = 1
        public var clips: [Clipboard.Clip] = []

        public init(clips: [Clipboard.Clip] = []) { self.clips = clips }
    }

    public static func indexFile(_ root: URL) -> URL { root.appendingPathComponent("index.json") }
    public static func items(_ root: URL) -> URL { root.appendingPathComponent("items", isDirectory: true) }
    public static func thumbs(_ root: URL) -> URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    /// Item one keeps the names it has always had; every later item hangs
    /// off its index.
    public static func itemFile(_ root: URL, id: String, item: Int, _ ext: String) -> URL {
        items(root).appendingPathComponent("\(id).\(item == 0 ? ext : "i\(item).\(ext)")")
    }

    public static func plainFile(_ root: URL, id: String, item: Int) -> URL { itemFile(root, id: id, item: item, "plain") }
    public static func nativeFile(_ root: URL, id: String, item: Int, offset: Int) -> URL {
        itemFile(root, id: id, item: item, "type\(offset)")
    }
    public static func thumbFile(_ root: URL, id: String) -> URL {
        thumbs(root).appendingPathComponent("\(id).png")
    }

    public static func digest(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// What reading one file gave.
    enum Read {
        case bytes(Data)
        case missing
        /// The file is there and could not be read.
        case unreadable
    }

    static func read(_ url: URL) -> Read {
        if access(url.path, F_OK) != 0, errno == ENOENT { return .missing }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return access(url.path, F_OK) != 0 ? .missing : .unreadable
        }
        return .bytes(data)
    }

    /// Whether anything of a v1 history is on disk: the index, a quarantined
    /// index, or files under `items/` or `thumbs/`.
    public static func plaintextFiles(_ root: URL) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in top where name == "index.json" || name.hasPrefix("index.json.corrupt-") { found.append(name) }
        for folder in ["items", "thumbs"] {
            for name in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? [] {
                found.append(folder + "/" + name)
            }
        }
        return found.sorted()
    }
}

// MARK: - Writing one (an older build's way)

extension ClipboardV1 {
    /// A history written the way every earlier build wrote it, which is how an
    /// older build that is run again after the sealed one still does. Kept
    /// here so that the migration's tests and its benchmark make a history
    /// the way a real one was made; nothing in the app calls it.
    public static func write(_ clip: Clipboard.Clip, items: [ClipboardContent.Item], thumbnail: Data? = nil, to root: URL) throws {
        let fm = FileManager.default
        for folder in [Self.items(root), thumbs(root)] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for (item, content) in items.enumerated() {
            if let plain = content.plain { try PrivateFile.write(plain, to: plainFile(root, id: clip.id, item: item)) }
            for (offset, native) in content.natives.enumerated() {
                try PrivateFile.write(native.data, to: nativeFile(root, id: clip.id, item: item, offset: offset))
            }
        }
        if let thumbnail { try PrivateFile.write(thumbnail, to: thumbFile(root, id: clip.id)) }
    }

    public static func writeIndex(_ clips: [Clipboard.Clip], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(try encoder.encode(Index(clips: clips)), to: indexFile(root))
    }
}
