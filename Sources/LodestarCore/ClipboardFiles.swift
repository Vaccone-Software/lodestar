import Foundation
import StoicSealed
import StoicStore

/// The blobs and thumbnails of a sealed history: each a file of its own under
/// `<folder>/items/<storage>` and `<folder>/thumbs/<storage>`, **sealed under
/// the clip's own key** and never under the ring, so that rotating the ring
/// rewrites none of it and a clip stops existing when its key does.
///
/// A blob is `Sealing.seal` output written with `PrivateFile` (0600, atomic,
/// no `F_FULLFSYNC`). `SealedFile` is the primitive a whole file wants, and
/// this is the one place it is not used: it takes a `Keyring` (a clip's key is
/// in no ring, it is inside a sealed record) and pays a full sync and a
/// directory sync for each file, which is what a blob written beside every
/// copy must not pay. What it keeps: the file is a sealed value, opened with
/// its context and nothing else; it is replaced atomically; and the index
/// record that names it is appended **after** it is complete.
///
/// Thread-safe: no state but the paths.
public struct ClipboardFiles: Sendable {
    public let root: URL
    /// `v2`, or `v2.migrating` while a migration is building one.
    public let folder: String

    public init(root: URL, folder: String = "v2") {
        self.root = root
        self.folder = folder
    }

    public var base: URL { root.appendingPathComponent(folder, isDirectory: true) }
    public var items: URL { base.appendingPathComponent("items", isDirectory: true) }
    public var thumbs: URL { base.appendingPathComponent("thumbs", isDirectory: true) }
    public var indexPath: String { base.appendingPathComponent("index.sj").path }

    public func itemURL(_ storage: String) -> URL { items.appendingPathComponent(storage) }
    public func thumbURL(_ storage: String) -> URL { thumbs.appendingPathComponent(storage) }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The folders, `0700`.
    public func prepare(fileSystem: any FileSystem) {
        for directory in [base, items, thumbs] { SealedDirectory.ensure(directory.path, fileSystem: fileSystem) }
    }

    // MARK: Blobs

    public func writeBlob(storage: String, key: SealingKey, items content: [ClipboardContent.Item],
                          sync: Bool = false) throws {
        let sealed = try seal(ClipboardContent.encode(content), ClipboardSealed.blobContext(storage), key)
        try write(sealed, to: itemURL(storage), sync: sync)
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

    public func writeThumb(storage: String, key: SealingKey, png: Data, sync: Bool = false) throws {
        let sealed = try seal([UInt8](png), ClipboardSealed.thumbContext(storage), key)
        try write(sealed, to: thumbURL(storage), sync: sync)
    }

    /// The thumbnail's PNG bytes, or nil when there is none or it does not open.
    public func readThumb(storage: String, key: SealingKey) -> Data? {
        if case .bytes(let plain) = open(thumbURL(storage), ClipboardSealed.thumbContext(storage), key) { return Data(plain) }
        return nil
    }

    public func hasThumb(storage: String) -> Bool { access(thumbURL(storage).path, F_OK) == 0 }

    // MARK: Removing

    /// Unlink each storage's blob and thumbnail. What was in them stays on
    /// the disk's blocks as ciphertext, and stops being readable when the
    /// compaction after the deletion retires the key that was in the record.
    public func remove(storages: [String]) {
        for storage in storages where ClipboardSealed.isStorageName(storage) {
            unlink(itemURL(storage).path)
            unlink(thumbURL(storage).path)
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
                let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
                guard ClipboardSealed.isStorageName(stem) else { continue }
                // `<storage>.<token>` is a write that was cut short.
                guard name.contains(".") || !live.contains(stem) else { continue }
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

    private func seal(_ plain: [UInt8], _ context: SealContext, _ key: SealingKey) throws -> [UInt8] {
        do { return try Sealing.seal(plain, context: context, key: key) } catch { throw Failure(description: "\(error)") }
    }

    private enum Opened {
        case bytes([UInt8])
        case missing
        case unreadable(String)
    }

    private func open(_ url: URL, _ context: SealContext, _ key: SealingKey) -> Opened {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return access(url.path, F_OK) != 0 ? .missing : .unreadable("\(error)")
        }
        do {
            return .bytes(try Sealing.open([UInt8](data), context: context, key: key))
        } catch {
            return .unreadable("\(error)")
        }
    }

    private func write(_ sealed: [UInt8], to url: URL, sync: Bool) throws {
        do {
            try PrivateFile.write(sealed, to: url, atomically: true, sync: sync)
        } catch {
            throw Failure(description: "\(error)")
        }
    }
}
