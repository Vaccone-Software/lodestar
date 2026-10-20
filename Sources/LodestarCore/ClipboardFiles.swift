import Foundation
import StoicSealed
import StoicStore

/// The blobs and thumbnails of a sealed history: each a file of its own under
/// `<folder>/items/<storage>` and `<folder>/thumbs/<storage>`, **sealed under
/// the clip's own key** and never under the ring, so that rotating the ring
/// rewrites none of it and a clip stops existing when its key does.
///
/// A blob is a `SealedObjectFile` (StoicSealed): the sealed value alone, written
/// to `0600` atomically, with `.standard` durability (a plain `fsync` and a
/// rename, no `F_FULLFSYNC` and no directory sync), which is what a blob written
/// beside every copy can afford, and what the history can lose the end of
/// without anyone being worse off. A power cut may bring the old file, or none,
/// back, and never a torn one. What it keeps: the file is a sealed value, opened
/// with its context and the clip's own key and nothing else; it is replaced
/// atomically; and the index record that names it is appended **after** it is
/// complete.
///
/// Thread-safe: no state but the paths.
public struct ClipboardFiles: Sendable {
    public let root: URL
    /// `v2`, or `v2.migrating` while a migration is building one.
    public let folder: String

    /// What every blob and thumbnail is written and read through: private files
    /// (`OwnerOnly.fileSystem`), written with plain `fsync`.
    private let sealedFile: SealedObjectFile

    public init(root: URL, folder: String = "v2") {
        self.root = root
        self.folder = folder
        sealedFile = SealedObjectFile(fileSystem: OwnerOnly.fileSystem, options: .init(durability: .standard))
    }

    public var base: URL { root.appendingPathComponent(folder, isDirectory: true) }
    public var items: URL { base.appendingPathComponent("items", isDirectory: true) }
    public var thumbs: URL { base.appendingPathComponent("thumbs", isDirectory: true) }
    public var indexPath: String { base.appendingPathComponent("index.sj").path }

    public func itemURL(_ storage: String) -> URL { items.appendingPathComponent(storage) }
    public func thumbURL(_ storage: String, index: Int = 0) -> URL {
        thumbs.appendingPathComponent(ClipboardSealed.thumbName(storage, index: index))
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The folders, `0700`.
    public func prepare(fileSystem: any FileSystem) {
        for directory in [base, items, thumbs] { SealedDirectory.ensure(directory.path, fileSystem: fileSystem) }
    }

    // MARK: Blobs

    public func writeBlob(storage: String, key: SealingKey, items content: [ClipboardContent.Item]) throws {
        try write(ClipboardContent.encode(content), to: itemURL(storage), ClipboardSealed.blobContext(storage), key)
    }

    public enum BlobRead {
        case items([ClipboardContent.Item])
        case missing
        /// There, and would not open or decode.
        case unreadable(String)
    }

    public func readBlob(storage: String, key: SealingKey) -> BlobRead {
        switch open(itemURL(storage), ClipboardSealed.blobContext(storage), key) {
        case .missing: return .missing
        case .unreadable(let why): return .unreadable(why)
        case .bytes(let plain):
            guard let items = ClipboardContent.decode(plain) else { return .unreadable("the blob is not a container") }
            return .items(items)
        }
    }

    // MARK: Thumbnails

    /// A clip has one thumbnail (an image's), or, for a copy of files, one
    /// per file up to `Clipboard.thumbnailedFiles`, numbered from 0. The
    /// first is where the single one always was.
    public func writeThumb(storage: String, key: SealingKey, png: Data, index: Int = 0) throws {
        try write([UInt8](png), to: thumbURL(storage, index: index),
                  ClipboardSealed.thumbContext(storage, index: index), key)
    }

    /// The thumbnail's PNG bytes, or nil when there is none or it does not open.
    public func readThumb(storage: String, key: SealingKey, index: Int = 0) -> Data? {
        if case .bytes(let plain) = open(thumbURL(storage, index: index),
                                         ClipboardSealed.thumbContext(storage, index: index), key) { return Data(plain) }
        return nil
    }

    public func hasThumb(storage: String, index: Int = 0) -> Bool {
        access(thumbURL(storage, index: index).path, F_OK) == 0
    }

    // MARK: Removing

    /// Unlink each storage's blob and thumbnails. What was in them stays on
    /// the disk's blocks as ciphertext, and stops being readable when the
    /// compaction after the deletion retires the key that was in the record.
    public func remove(storages: [String]) {
        for storage in storages where ClipboardSealed.isStorageName(storage) {
            unlink(itemURL(storage).path)
            for index in 0..<Clipboard.thumbnailedFiles { unlink(thumbURL(storage, index: index).path) }
        }
    }

    /// Remove every file under `items/` and `thumbs/` that no live clip names
    /// (a blob whose record never landed, a half-written temporary). Names
    /// that are not storage names are left alone: they are not ours.
    @discardableResult
    public func collectGarbage(keeping live: Set<String>) -> Int {
        var removed = 0
        for directory in [items, thumbs] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                // A blob is named by its storage; a thumbnail by it too, or
                // with the number of the file's picture after a hyphen.
                let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
                let owner = directory == thumbs ? ClipboardSealed.storage(ofThumbName: name)
                    : (ClipboardSealed.isStorageName(stem) ? stem : nil)
                guard let owner else { continue }
                // `<storage>.<token>` is a write that was cut short.
                guard name.contains(".") || !live.contains(owner) else { continue }
                if unlink(directory.appendingPathComponent(name).path) == 0 { removed += 1 }
            }
        }
        return removed
    }

    /// The storage names present on disk, blobs and thumbnails together.
    public func storagesOnDisk() -> Set<String> {
        var found: Set<String> = []
        for directory in [items, thumbs] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] { found.insert(name) }
        }
        return found
    }

    // MARK: Sealing, opening, writing

    private enum Opened {
        case bytes([UInt8])
        case missing
        case unreadable(String)
    }

    private func open(_ url: URL, _ context: SealContext, _ key: SealingKey) -> Opened {
        do {
            guard let plain = try sealedFile.read(url.path, context: context, key: key) else { return .missing }
            return .bytes(plain)
        } catch {
            return .unreadable("\(error)")
        }
    }

    private func write(_ plain: [UInt8], to url: URL, _ context: SealContext, _ key: SealingKey) throws {
        // AtomicFile keeps the mode of a file it replaces, so one left wider
        // (an older build's, or a hand chmod) is narrowed first: the new
        // bytes are never written readable by anyone else.
        if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int,
           mode & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        do {
            try sealedFile.write(plain, to: url.path, context: context, key: key)
        } catch {
            throw Failure(description: "\(error)")
        }
    }
}
