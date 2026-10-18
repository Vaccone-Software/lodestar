import Foundation
import StoicStore

/// What every private store of Lodestar's is written through, and the one
/// sweep that closes what an earlier build left open.
///
/// A note waiting in the outbox, the sealed records, the clipboard's files:
/// the person's own words and habits, and nobody else's business. Stoic's
/// `PosixFileSystem` takes the modes for what it creates
/// (`newFileMode:` / `newDirectoryMode:`), at `open(2)` and `mkdir(2)`, so
/// there is no instant at which a private file is readable by others, for
/// every file any store makes through it (a journal, its lock, a
/// compaction's temporary, an `AtomicFile`).
public enum OwnerOnly {
    /// Files `0600`, directories `0700`. One value for the process, as the
    /// file system carries no state of its own.
    public static let fileSystem = PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)

    /// **The one-time tightening.** A mode is given to what is *created*, so
    /// a file or folder an earlier build made `0644` or `0755` stays open
    /// until this closes it: every regular file under `directory` becomes
    /// `0600` and every folder `0700`, if it had any bit for group or others.
    /// A symbolic link is never followed, and what is neither a file nor a
    /// folder is left. Cheap and idempotent, so it is run at every launch.
    ///
    /// - Returns: How many entries it tightened.
    @discardableResult
    public static func tighten(_ directory: URL) -> Int {
        let manager = FileManager.default
        var tightened = 0
        var pending = [directory.path]
        while let folder = pending.popLast() {
            if narrow(folder, to: 0o700, type: .typeDirectory, manager) { tightened += 1 }
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: path),
                      let type = attributes[.type] as? FileAttributeType else { continue }
                switch type {
                case .typeDirectory: pending.append(path)
                case .typeRegular:
                    if narrow(path, to: 0o600, type: .typeRegular, manager) { tightened += 1 }
                default: break
                }
            }
        }
        return tightened
    }

    private static func narrow(_ path: String, to mode: Int, type: FileAttributeType, _ manager: FileManager) -> Bool {
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == type,
              let current = attributes[.posixPermissions] as? Int, current & 0o077 != 0 else { return false }
        return (try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)) != nil
    }
}
