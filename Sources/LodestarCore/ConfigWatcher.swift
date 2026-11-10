import Foundation
import Synchronization
import StoicJSON
import StoicSettings
import StoicStore

/// A value that is handed across a thread boundary and used on one thread
/// only. The watcher's callbacks are the app's, called on the main queue.
// stoic:allow(unchecked-sendable): an immutable `let` box whose value every use site calls (or reads through) only on the main queue, inside `DispatchQueue.main.async` or a `queue` that is main in the app, so the value is never used on two threads at once
struct MainQueueOnly<T>: @unchecked Sendable {
    let value: T
}

/// An object held weakly, for a box like `MainQueueOnly` to carry to another
/// thread and back to main: `MainQueueOnly(value: WeakRef(self))`.
struct WeakRef<T: AnyObject> {
    weak var object: T?
    init(_ object: T) { self.object = object }
}

/// Tells the app that the config arrived from outside, once per arrival.
///
/// The directory is watched by the store (`watch(debounce:)`: an editor that
/// saves by rename, a file that does not exist yet, a burst of writes is one
/// reload), which reloads the file off the main thread. What reaches the app
/// is told here, on the main queue:
///
/// - **A `.reload` change of the value**: the file changed under the app (a
///   hand edit, `lodestar config set` from a terminal, another instance).
/// - **A change of the file's problem** (`problems()`): a save that does not
///   parse leaves the last good value, so the value did not change and no
///   change is announced; the person still has to be told (and told again,
///   plainly, when the fix lands and the problem clears).
///
/// **The app's own writes are not told.** A change with cause `.update` is the
/// app's, and whoever made it applies it (or chose not to); the watcher
/// reports the file's change to the store too, and the store finds the bytes
/// as it wrote them and says nothing. So nothing is applied twice. What is
/// told is also checked against what the app last applied
/// (`ConfigApplyLedger`): a store state the app has already applied is not
/// told again.
///
/// Runs: the reload and the streams on Stoic's own tasks, off
/// the main thread; `arrived` on `queue` (the main queue).
public final class ConfigWatcher: Sendable {
    private let store: ConfigStore.Store
    private let debounce: Duration
    private let queue: DispatchQueue
    private let arrived: MainQueueOnly<() -> Void>
    private let ledger = ConfigApplyLedger()
    private struct Running {
        var watch: SettingsWatch?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(Running())

    public init(store: ConfigStore.Store, debounce: Duration = .milliseconds(300),
                queue: DispatchQueue = .main, arrived: @escaping () -> Void) {
        self.store = store
        self.debounce = debounce
        self.queue = queue
        self.arrived = MainQueueOnly(value: arrived)
    }

    deinit { stop() }

    /// Starts watching. Throws what the store throws when it cannot watch
    /// (`.notFound` for a directory that is not there).
    public func start() throws(StoreError) {
        stop()
        let started = try store.watch(debounce: debounce)
        let changes = store.changes(buffering: 256)
        let problems = store.problems(buffering: 64)
        let changesTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                switch change.cause {
                case .reload: self.notify()
                case .update: self.ledger.ownUpdate(change)
                case .reset: break
                }
            }
        }
        let problemTask = Task { [weak self] in
            // Once for each change of the problem (it stopped parsing, parses
            // again, or is wrong in another way): the store says so itself.
            for await _ in problems {
                guard let self else { return }
                self.notify()
            }
        }
        state.withLock { $0 = Running(watch: started, tasks: [changesTask, problemTask]) }
    }

    public func stop() {
        let ending = state.withLock { running -> Running in
            defer { running = Running() }
            return running
        }
        ending.watch?.stop()
        for task in ending.tasks { task.cancel() }
    }

    /// The app applied the config built from `snapshot` (every apply, its own
    /// and an explicit reload's too).
    public func didApply(_ snapshot: ConfigStore.Snapshot) {
        ledger.didApply(snapshot)
    }

    private func notify() {
        let handler = arrived
        queue.async { [self] in
            // The store as it is when the main queue gets here, which is at
            // least as new as what announced it.
            let problem = store.fileProblem
            let snapshot = ConfigStore.Snapshot(value: store.value, problem: problem)
            guard ledger.needsApply(snapshot) else { return }
            handler.value()
        }
    }
}

extension ConfigWatcher {
    /// The explicit reload (the menu's "Reload Config", SIGUSR2, which
    /// `lodestar reload` and `config set` send): re-read the file, then apply,
    /// **always**. Whether the file changed or not, and whether it parses or
    /// not, `apply` runs once, after the store has been brought up to date: a
    /// reload is also the moment the app asks the world again (the doctor's
    /// ground truth), and it says so. The ledger is not consulted.
    ///
    /// The file is read on a utility queue, so the caller's thread (the
    /// main thread, for a signal source on the main queue) never waits on the
    /// store's lock or on the file; `apply` runs on `queue`. `store` is nil
    /// when the config could not be opened, and `apply` still runs.
    public static func reloadThenApply(_ store: ConfigStore.Store?, on queue: DispatchQueue = .main,
                                       apply: @escaping () -> Void) {
        let handler = MainQueueOnly(value: apply)
        DispatchQueue.global(qos: .userInitiated).async {
            // Never throws for a hand-edited file: one that cannot be used is
            // the store's `fileProblem`, which `apply` reports.
            if let store { Log.attempt("config-watch: could not read the file after a change") { try store.reload() } }
            queue.async { handler.value() }
        }
    }
}

/// What the app has applied, so that one arrival is applied once.
///
/// An arrival can be announced twice (a `.reload` change and a change of the
/// problem together, as when a fix lands) and the app's own explicit reload
/// (SIGUSR2, the menu) can meet a watcher reload of the same bytes. Applying
/// is idempotent, but it flashes and re-runs ground truth; this says whether
/// the store holds something the app has not applied. The explicit reload
/// does not ask: it always applies.
public final class ConfigApplyLedger: Sendable {
    private let applied = Mutex<ConfigStore.Snapshot?>(nil)

    public init() {}

    /// Whether the store holds a value or a problem the app has not applied.
    public func needsApply(_ snapshot: ConfigStore.Snapshot) -> Bool {
        applied.withLock { $0 != snapshot }
    }

    /// The app applied this.
    public func didApply(_ snapshot: ConfigStore.Snapshot) {
        applied.withLock { $0 = snapshot }
    }

    /// The app made `change` itself and did not reload for it (a one-key
    /// write that sets what it holds in memory): it has applied it. A writer
    /// that did reload has applied something newer already, and this finds
    /// the ledger past `change.old` and leaves it.
    public func ownUpdate(_ change: SettingsChange<ConfigFile>) {
        applied.withLock { applied in
            guard var current = applied, current.value == change.old else { return }
            current.value = change.new
            applied = current
        }
    }
}
