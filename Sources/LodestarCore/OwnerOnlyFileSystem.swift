import StoicStore

/// The real file system, with every file it opens for writing made readable
/// by its owner alone.
///
/// Stoic's `PosixFileSystem` creates files 0o644, and neither `Journal` nor
/// `Outbox` can be told otherwise (only `AtomicFile` takes a mode). A note
/// waiting in the outbox is the person's own words, and a reply address, and
/// maybe a log; so each file is `fchmod`ed to 0o600 as it is opened, and no
/// later mode that asks for more is applied. The directory around them is
/// 0o700 as well, which is what covers the instant between create and chmod.
public struct OwnerOnlyFileSystem: FileSystem {
    let base: any FileSystem

    public init(_ base: any FileSystem = PosixFileSystem()) {
        self.base = base
    }

    public func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        let file = try base.open(path, mode: mode)
        if mode != .read {
            do throws(StoreError) {
                try base.setPermissions(file, to: 0o600)
            } catch {
                // A file that cannot be made private is not used: closing it
                // is best effort, the error that matters is the chmod's.
                _ = try? base.close(file)
                throw error
            }
        }
        return file
    }

    public func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) {
        try base.setPermissions(file, to: permissions & 0o600)
    }

    public func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] {
        try base.read(file, at: offset, count: count)
    }
    public func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
        try base.write(file, bytes, at: offset)
    }
    public func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    public func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    public func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    public func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    public func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    public func rename(from source: String, to destination: String) throws(StoreError) {
        try base.rename(from: source, to: destination)
    }
    public func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    public func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    public func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    public func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    public func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    public func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    public func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
    public func exchange(_ first: String, _ second: String) throws(StoreError) { try base.exchange(first, second) }
    public func removeTree(_ path: String) throws(StoreError) { try base.removeTree(path) }
    public func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    public func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}
