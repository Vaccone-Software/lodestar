import Foundation
import StoicStore

/// The words of a draft that is still being spoken or typed (`draft-in-flight`):
/// written every half second while it is open so that a crash costs at most the
/// last half second, recovered to the pasteboard at the next boot, and removed
/// by a clean close.
///
/// **Sealed under the clipboard ring**, the same ring (and so the same key
/// states) as the history it is a transient of; read by `SealedValueFile`,
/// which also reads the plaintext an earlier build wrote.
///
/// - **Paused** (the history is opening, or unavailable, or the ring is
///   paused): the stash is *not written* — a sealed file needs a key, and a
///   plaintext one is what this exists not to leave. The consequence is that a
///   crash during a draft while the history is unavailable recovers nothing:
///   the words exist only in the draft window. The next update after the key
///   comes back writes it.
/// - **Rotation.** A compaction of the history retires the ring's old keys, and
///   a stash sealed under one would no longer open: `reseal()` writes the
///   current words again under the new key, and is called after every compaction.
/// - Removal is never refused: the file is a transient of the person's own
///   typing, not history, and a stale one left behind after a clean close
///   would be put on the pasteboard by a later crash.
///
/// Every call is made on one queue (the draft's stash queue): a keystroke
/// never reaches it.
public final class DraftStash: @unchecked Sendable {
    public static let name = "draft-in-flight"

    private let file: SealedValueFile
    private let allowed: @Sendable () -> Bool
    private var last: String?

    public init(directory: URL, ring: Vault.Ring, fileSystem: any FileSystem = OwnerOnly.fileSystem,
                allowed: @escaping @Sendable () -> Bool) {
        file = SealedValueFile(url: directory.appendingPathComponent(Self.name), name: Self.name, ring: ring, fileSystem: fileSystem)
        self.allowed = allowed
    }

    public var url: URL { file.url }

    /// Seal `text` as the stash. Nothing is written while the history's key is not ready.
    public func write(_ text: String) {
        last = text
        guard allowed() else { return }
        if case .failed(let why) = file.write(Array(text.utf8)) {
            Log.warning("draft: the in-flight stash could not be written (\(why))")
        } else {
            Paths.excludeFromBackup(file.url)
        }
    }

    /// The words, sealed again under the ring's current key.
    public func reseal() {
        guard let last, !last.isEmpty else { return }
        write(last)
    }

    /// A clean close: the stash is removed.
    public func clear() {
        last = nil
        try? file.fileSystem.remove(file.url.path)
    }

    public enum Recovered: Equatable {
        case text(String)
        case none
        /// Sealed, and the key cannot be asked for: left where it is (and not removed).
        case unavailable
        /// There, and would not open or is not text: nothing to give back.
        case unreadable
    }

    /// What a crashed run left. **Not for the main thread** (the key may be asked for).
    public func recover() -> Recovered {
        switch file.read() {
        case .absent: return .none
        case .unavailable: return .unavailable
        case .unreadable: return .unreadable
        case .value(let bytes, _):
            guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else { return .none }
            return .text(text)
        }
    }
}
