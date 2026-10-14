import Foundation
import StoicStore

/// The two ways Lodestar puts bytes on disk that must still be there after
/// a crash or a power cut, and must never be silently lost.
///
/// `Data.write(to:options: .atomic)` writes a temporary and renames it, but
/// ends in a plain `fsync` (which on a Mac does not flush the drive's cache)
/// and never syncs the directory, so the rename itself can be lost; and
/// nearly every caller wrapped it in `try?`, so a full disk or a permission
/// change dropped the save without a word. `write` is Stoic's `AtomicFile`
/// with the checksum envelope off — the bytes on disk are exactly the bytes
/// given, so every reader (the CLI, older builds, a text editor) is
/// untouched — and `save` is the same write with the failure said in the
/// log, once, rather than swallowed.
///
/// `append` is the other half: an `O_APPEND` descriptor opened on the path
/// itself. The older shape, `FileHandle(forWritingTo:)` then `seekToEnd`,
/// fell back to writing a whole new file when the open failed, so a file
/// that existed but could not be opened for a moment (too many descriptors,
/// a permission change) was replaced by the one line being appended.
public enum DurableFile {
    /// Replace the file at `url` with `data`: temporary, full sync, rename,
    /// directory sync. An existing file keeps its permission bits; a new one
    /// gets `newFileMode`, set before a byte is written.
    public static func write(_ data: Data, to url: URL, newFileMode: UInt16 = 0o644) throws {
        let atomic = AtomicFile(options: .init(envelope: false, newFileMode: newFileMode))
        try atomic.write([UInt8](data), to: url.path)
    }

    /// `write`, with a failure logged instead of thrown: for the saves
    /// whose caller has nothing better to do than go on and try again at the
    /// next change. The first failure for a file is logged; the ones after
    /// it are not (a full disk would otherwise write a line per save), until
    /// a save succeeds and the next failure is news again.
    @discardableResult
    public static func save(_ data: Data, to url: URL, as label: String,
                            newFileMode: UInt16 = 0o644) -> Bool {
        do {
            try write(data, to: url, newFileMode: newFileMode)
            failing.withLock { _ = $0.remove(url.path) }
            return true
        } catch {
            let first = failing.withLock { $0.insert(url.path).inserted }
            if first {
                Log.error("\(label): could not write \(url.lastPathComponent)",
                          ["error": "\(error)"])
            }
            return false
        }
    }

    fileprivate static let failing = Locked<Set<String>>([])

    /// Tests: forget which files have already been reported.
    static func forgetFailures() { failing.withLock { $0 = [] } }

    /// Add `data` to the end of the file at `url`, creating it (with
    /// `newFileMode`) if it is not there. Never replaces what is there: if the
    /// file cannot be opened, this throws and the file is as it was.
    ///
    /// A write that fails part-way (a full disk takes what it can) is
    /// rewound to where it started when nothing else has appended since, so
    /// the caller's retry does not leave a torn line at the seam.
    public static func append(_ data: Data, to url: URL, newFileMode: mode_t = 0o600) throws {
        guard !data.isEmpty else { return }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, newFileMode)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor) }
        var before = stat()
        let start: off_t? = fstat(descriptor, &before) == 0 ? before.st_size : nil
        do {
            try handle.write(contentsOf: data)
        } catch {
            var after = stat()
            if let start, fstat(descriptor, &after) == 0,
               after.st_size > start, after.st_size - start < off_t(data.count) {
                _ = ftruncate(descriptor, start)
            }
            throw error
        }
    }
}

/// A value behind a lock, for the one-line shared tables this file needs.
fileprivate final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
