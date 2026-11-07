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
/// - **Stranded.** A `recover()` that finds the file sealed with the key
///   unavailable makes the stash *stranded*: the file holds words from a run
///   that crashed, and it is the only thing a stranded stash protects. Until
///   they have been handed over (`handOver`, once, when the key opens them)
///   `clear()` removes nothing, `write` never replaces the file (it tries to
///   recover first, and writes nothing to disk while it cannot), and `reseal`
///   leaves the file alone. `keyMayHaveReturned()` is the retry. Losing one
///   draft's crash protection is the price; losing the stranded words is not.
/// - Removal of the words this run wrote itself is never refused: the file is
///   a transient of the person's own typing, not history, and a stale one left
///   behind after a clean close would be put on the pasteboard by a later crash.
///
/// Every call is made on one queue (the draft's stash queue): a keystroke
/// never reaches it.
public final class DraftStash: @unchecked Sendable {
    public static let name = "draft-in-flight"

    private let file: SealedValueFile
    private let allowed: @Sendable () -> Bool
    private let handOver: @Sendable (String) -> Void
    private var last: String?
    private var stranded = false
    private var saidStranded = false

    /// `handOver` receives words a stranded stash recovers later, once, on the
    /// queue the stash is called on; the file is removed as it is called.
    public init(directory: URL, ring: Vault.Ring, fileSystem: any FileSystem = OwnerOnly.fileSystem,
                allowed: @escaping @Sendable () -> Bool, handOver: @escaping @Sendable (String) -> Void = { _ in }) {
        file = SealedValueFile(url: directory.appendingPathComponent(Self.name), name: Self.name, ring: ring, fileSystem: fileSystem)
        self.allowed = allowed
        self.handOver = handOver
    }

    public var url: URL { file.url }

    /// Seal `text` as the stash. Nothing is written while the history's key is not ready.
    public func write(_ text: String) {
        last = text
        if stranded {
            retryStranded()
            if stranded {
                if !saidStranded {
                    saidStranded = true
                    Log.warning("draft: words from a crashed run are still sealed, so this draft is not stashed until they can be read")
                }
                return
            }
        }
        guard allowed() else { return }
        if case .failed(let why) = file.write(Array(text.utf8)) {
            Log.warning("draft: the in-flight stash could not be written (\(why))")
        } else {
            Paths.excludeFromBackup(file.url)
        }
    }

    /// The words, sealed again under the ring's current key.
    public func reseal() {
        if stranded { retryStranded() }
        guard !stranded, let last, !last.isEmpty else { return }
        write(last)
    }

    /// A clean close: the stash is removed, unless it holds words this run
    /// did not write and has not handed over.
    public func clear() {
        last = nil
        guard !stranded else { return }
        try? file.fileSystem.remove(file.url.path)
    }

    /// The key the stash is sealed under may be back (the keychain unlocked,
    /// after the ring was asked again): a stranded stash reads its words and
    /// hands them over. Nothing when it is not stranded, and nothing happens
    /// when the key is still away: the next call tries again.
    public func keyMayHaveReturned() {
        guard stranded else { return }
        retryStranded()
    }

    /// Read the stranded file. Words are handed over and the file removed; a
    /// file that is gone, or would not open or is not text, has nothing to
    /// give back and ends the wait as a launch's recovery does.
    private func retryStranded() {
        switch file.read() {
        case .unavailable:
            return
        case .absent, .unreadable:
            break
        case .value(let bytes, _):
            if let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty { handOver(text) }
        }
        stranded = false
        saidStranded = false
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
        let found = read()
        stranded = found == .unavailable
        return found
    }

    private func read() -> Recovered {
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
