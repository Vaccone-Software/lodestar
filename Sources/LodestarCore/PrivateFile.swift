import Foundation

/// A file only its owner may read, from the first byte written.
///
/// What the clipboard keeps under `items/` and `thumbs/` is what the person
/// copied, and `Data.write` made each file 0644 under the usual umask. This
/// creates the file 0600 — `open` with the mode, then `fchmod`, so neither
/// the umask nor a file an older build left readable can leave it looser —
/// and says nothing of durability. `DurableFile` is the writer for the
/// things that must survive a power cut and pays an fsync for it; a blob
/// that is written four times to every copy, and one the history can lose
/// the end of without anyone being worse off, is not that.
public enum PrivateFile {
    /// Write `data` at `url`. A new file is 0600, an existing one is
    /// truncated and tightened to 0600. With `atomically`, the bytes go to a
    /// file beside it first and are renamed over, so a reader never sees
    /// half of them; the temporary name is `<name>.<token>`, and a name made
    /// that way is still the clip's, which is how a trim finds one a crash
    /// left behind. A symbolic link at `url` is never followed.
    public static func write(_ data: Data, to url: URL, atomically: Bool = false, sync: Bool = false) throws {
        try data.withUnsafeBytes { try write(bytes: $0, to: url, atomically: atomically, sync: sync) }
    }

    /// The same, for bytes already in an array (a sealed blob), without a
    /// copy into a `Data` first. `sync` asks for an `fsync` before the file
    /// is closed (and so before it is renamed into place): the drive has the
    /// bytes, though not that its own cache is flushed. A migration that is
    /// about to remove the plaintext syncs, and ends with one full sync.
    public static func write(_ bytes: [UInt8], to url: URL, atomically: Bool = false, sync: Bool = false) throws {
        try bytes.withUnsafeBytes { try write(bytes: $0, to: url, atomically: atomically, sync: sync) }
    }

    private static func write(bytes: UnsafeRawBufferPointer, to url: URL, atomically: Bool, sync: Bool) throws {
        let path = url.path
        let target = atomically ? "\(path).\(UUID().uuidString.prefix(8))" : path
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (atomically ? O_EXCL : O_TRUNC | O_NOFOLLOW)
        let descriptor = open(target, flags, 0o600)
        guard descriptor >= 0 else { throw failure() }
        var failed: Error?
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure()
                }
                written += count
            }
            if sync, fsync(descriptor) != 0 { throw failure() }
        } catch {
            failed = error
        }
        // Closed once, whichever way the writing went; a close that fails
        // is a write that did not land.
        if close(descriptor) != 0, failed == nil { failed = failure() }
        if let failed {
            if atomically { unlink(target) }
            throw failed
        }
        if atomically, rename(target, path) != 0 {
            let error = failure()
            unlink(target)
            throw error
        }
    }

    /// Owner-only for a file that exists already, and nothing for one that
    /// is not a plain file: a link is never followed, and what is tightened
    /// is the entry itself.
    @discardableResult
    public static func restrict(existing path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 != 0 else { return false }
        return chmod(path, 0o600) == 0
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
