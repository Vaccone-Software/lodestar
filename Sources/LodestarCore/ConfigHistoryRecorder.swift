import Foundation
import StoicJSON
import StoicSettings

/// Writes the config's history from the store's stream of changes.
///
/// Every change to the config, whoever made it, is one `SettingsChange`: what
/// the value was, what it is, and why. This reads that stream and writes one
/// entry per leaf that differs, with the moment, a group (one change, one
/// group, which is what an undo takes back at once) and who made it:
///
/// - **`.update`**: the app did it, and the writer named itself when it wrote
///   (`Config.edit(source:)`: "Settings", "Lodestar", "The coach", "The
///   editor", "Undo", "Redo"). An update that nobody named is "Lodestar".
/// - **`.reload`**: the file changed under the app (a hand edit, the command
///   line, another instance): "The file". An update that found the file moved
///   is two changes, the file's edit and then the app's own, and each is
///   recorded as what it is.
/// - **`.reset`**: "The file" (the app never resets its own file; the command
///   line does, and the app sees it as a reload).
///
/// The file format is unchanged (`ConfigHistory`): `t, g, p, s, o, n` a line
/// each, the newest last, trimmed to the last 500 once it holds 1000, and
/// every entry an earlier release wrote still reads.
///
/// Runs on one task of its own, off the main thread: a change is recorded a
/// moment after the write that made it returns (the stream is told before the
/// write returns; this reads it). `onRecorded` is called there too, in order.
public final class ConfigHistoryRecorder: @unchecked Sendable {
    /// What was recorded for one change.
    public struct Recorded: Sendable {
        public let change: SettingsChange<JSONValue>
        public let source: String
        public let group: Int
        public let entries: [ConfigHistory.Entry]
    }

    private let store: ConfigStore.Store
    private let file: URL
    private let now: @Sendable () -> Date
    private let onRecorded: (@Sendable (Recorded) -> Void)?
    private let state = NSLock()
    private var task: Task<Void, Never>?
    private var lastGroup: Int?

    public init(store: ConfigStore.Store, file: URL = ConfigHistory.defaultFile,
                now: @escaping @Sendable () -> Date = { Date() },
                onRecorded: (@Sendable (Recorded) -> Void)? = nil) {
        self.store = store
        self.file = file
        self.now = now
        self.onRecorded = onRecorded
    }

    deinit { stop() }

    /// Starts listening. A change committed before this is not heard.
    public func start() {
        stop()
        let changes = store.changes(buffering: 1024)
        let started = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.record(change)
            }
        }
        state.lock()
        task = started
        state.unlock()
    }

    public func stop() {
        state.lock()
        let ending = task
        task = nil
        state.unlock()
        ending?.cancel()
    }

    /// Who made `change`.
    func source(of change: SettingsChange<JSONValue>) -> String {
        switch change.cause {
        case .update:
            return ConfigStore.attributions.claim(producing: change.new, at: store.path) ?? "Lodestar"
        case .reload, .reset:
            return "The file"
        }
    }

    /// Writes the entries for one change, if it changed anything this config
    /// can hold (a list or a null the tree drops is not a change of it).
    @discardableResult
    func record(_ change: SettingsChange<JSONValue>) -> Recorded? {
        let source = source(of: change)
        var ignored: [String] = []
        let leaves = ConfigHistory.changes(from: ConfigStore.tree(of: change.old, problems: &ignored),
                                           to: ConfigStore.tree(of: change.new, problems: &ignored))
        guard !leaves.isEmpty else { return nil }
        let at = now()
        let group = nextGroup(at: at)
        let entries = leaves.enumerated().map {
            ConfigHistory.Entry(group: group, index: $0.offset, at: at, path: $0.element.path,
                                old: $0.element.old, new: $0.element.new, source: source)
        }
        ConfigHistory.append(entries, to: file)
        let recorded = Recorded(change: change, source: source, group: group, entries: entries)
        onRecorded?(recorded)
        return recorded
    }

    /// The moment in milliseconds, which is what a group has always been, made
    /// unique: two changes in one millisecond would be one group, and an undo
    /// would take back both.
    private func nextGroup(at date: Date) -> Int {
        state.lock()
        defer { state.unlock() }
        let last = lastGroup ?? ConfigHistory.read(from: file).last?.group ?? 0
        let group = max(Int(date.timeIntervalSince1970 * 1000), last + 1)
        lastGroup = group
        return group
    }
}
