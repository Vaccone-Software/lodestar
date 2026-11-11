import Foundation
import Stoic
import StoicStore
import Synchronization

/// The updater's release records, kept the way the updater needs them kept:
/// beside the markers, never in their way.
///
/// The record of a release (`ReleaseOnThisMac`) is a `JournaledLifecycleStore`
/// at `Paths.data/releases`. Two Lodestar processes run at once during every
/// handover, the relay and the resident, so the store takes the cross-process
/// lock, and for that reason it is never held open for the life of the app:
/// each piece of work opens it, does its work and closes it, waiting a bounded
/// few seconds if the other process has it.
///
/// Three rules hold it:
///
/// - **Off the caller's thread, in order.** Every piece of work goes through
///   one channel that one task reads, so what was decided first is written
///   first, and no caller (the main thread among them) waits on a file.
/// - **Best effort, said so.** The markers and the tombstone are the protocol
///   between processes and between builds, and the update never waits on this.
///   A store that cannot be opened or written makes a piece of work a no-op
///   that is logged, and the controller falls back to what it did before
///   there were records.
/// - **The decision to offer is a snapshot.** Whether a release may be offered
///   is read from the ids this object last saw refused, kept current by every
///   piece of work (the first is the launch's boot), so the feed's answer never
///   waits on the store.
public final class ReleaseRecords: Sendable {
    public typealias Store = JournaledLifecycleStore<ReleaseOnThisMac, String>
    typealias Job = @Sendable (Engine) async -> Void

    /// Where the journal lives (its outbox is beside it, at `.effects`).
    public static var standardPath: String { Paths.data.path + "/releases" }

    private let engine: Engine
    private let work = Channel<Job>(capacity: 64, label: "release.records")

    public init(path: String = ReleaseRecords.standardPath,
                fileSystem: any FileSystem = PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700),
                lockWait: Duration = .seconds(5)) {
        let engine = Engine(path: path, fileSystem: fileSystem, lockWait: lockWait)
        self.engine = engine
        // The one task that does the work, in the order it was asked for. It
        // ends when the records go (`deinit`).
        // Utility, named: a task started from the main thread would run in the
        // main thread's bucket of the cooperative pool (user-initiated), and
        // this is bookkeeping that waits on files and a lock.
        Task(priority: .utility) { [work] in
            for await job in work { await job(engine) }
        }
    }

    deinit { work.finish() }

    // MARK: - Asking

    /// Whether the records keep this release from being offered: a rollback
    /// or a refusal is for good, and a handover that has not timed out may
    /// still be confirmed. From the snapshot, never from the store.
    public func refuses(_ tag: String) -> Bool {
        guard let id = ReleaseOnThisMac.id(for: tag) else { return false }
        return engine.refusing.withLock { $0.contains(id) }
    }

    /// Resolves when everything asked for before it has been done.
    public func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !work.trySend({ _ in continuation.resume() }) { continuation.resume() }
        }
    }

    // MARK: - Telling

    /// The feed offered a release and a download begins: a record in
    /// `offered` if there is none, then `download`.
    public func offered(_ tag: String, because: String) {
        guard let id = ReleaseOnThisMac.id(for: tag) else { return }
        enqueue("offer \(id)") { store in
            if try await store.load(id) == nil {
                _ = try await store.insert(.new(in: .offered, by: .updater, because: because), as: id)
            }
            try await Engine.send(.download, to: id, by: .updater, because: "the download began", store: store)
        }
    }

    /// One event on one release, from this build's controller.
    public func record(_ event: ReleaseOnThisMac.Event, of tag: String,
                       by principal: ReleaseOnThisMac.Principal = .updater, because: String) {
        guard let id = ReleaseOnThisMac.id(for: tag) else {
            Log.warning("update", ["record": "none", "event": event.rawValue, "why": "\"\(tag)\" is not a version"])
            return
        }
        enqueue("\(event.rawValue) \(id)") { store in
            try await Engine.send(event, to: id, by: principal, because: because, store: store)
        }
    }

    /// A launch has cleared the staging folder, so a release still shown as
    /// downloading or staged has nothing behind it: `abandon`.
    public func abandonInFlight() {
        enqueue("abandon what was in flight") { store in
            let now = await store.moment(for: .now)
            for (id, record) in await store.records() {
                let state = record.state(at: now)
                guard state == .downloading || state == .staged else { continue }
                try await Engine.send(.abandon, to: id, by: .launch,
                                      because: "the launch cleared the staging folder of the release it was \(state.rawValue)",
                                      store: store)
            }
        }
    }

    // MARK: - Boot

    /// What a launch found of the updater's markers, for `boot`.
    public struct Boot: Sendable, Equatable {
        /// This build's version.
        public var version: String
        public var pid: Int32
        /// The `refused` tombstone's text.
        public var tombstone: String?
        /// The `updated-to` marker's text.
        public var updated: String?
        /// The `rolled-back` marker's text.
        public var rolledBack: String?

        public init(version: String, pid: Int32, tombstone: String? = nil, updated: String? = nil, rolledBack: String? = nil) {
            self.version = version
            self.pid = pid
            self.tombstone = tombstone
            self.updated = updated
            self.rolledBack = rolledBack
        }
    }

    /// Where the records stand for each marker after a boot, read from the
    /// store; nil for a marker that was not there, or that the store could
    /// not take (then the controller does what it did before records).
    public struct BootResult: Sendable, Equatable {
        /// The record the `updated-to` marker names, after this build confirmed it or found it unchanged.
        public var updated: ReleaseOnThisMac.State?
        /// The record the `rolled-back` marker names, after the rollback was recorded.
        public var rolledBack: ReleaseOnThisMac.State?
    }

    /// The boot, in the order the design gives:
    ///
    /// 1. a tombstone's release with no record becomes one, refused;
    /// 2. an `updated-to` marker is this build's version (`confirm`, by this
    ///    process as the successor) or not (`unchanged`, the build that did not
    ///    change the binary), a record missing for it being made first, applying,
    ///    by the importer;
    /// 3. a `rolled-back` marker is the watchdog's verdict (`rollBack`);
    /// 4. whatever has timed out is committed.
    ///
    /// Each step stands alone: one that fails is logged and leaves its marker's
    /// field nil. Nil as a whole means the store could not be opened.
    public func boot(_ boot: Boot) async -> BootResult? {
        await perform("boot") { store in await Engine.boot(boot, store: store) }
    }

    // MARK: - Saying

    /// An announcement due to the person, for `deliver`'s closure.
    public struct Delivery: Sendable, Equatable {
        /// The release's id (its canonical version).
        public let id: String
        public let announcement: ReleaseOnThisMac.Announcement
    }

    /// Commits what has timed out and says what is owed, at least once, each
    /// announcement under its own key: `say` answers `.delivered` once it has
    /// been put in front of the person (or `.discard` for one that no longer
    /// means anything). False when the store could not be used.
    public func deliver(using say: @escaping @Sendable (Delivery) async -> DeliveryResult) async -> Bool {
        let done = await perform("deliver") { store in
            _ = try await store.settleDue()
            _ = try await store.deliverEffects { delivery in
                switch delivery.effect {
                case .announce(let announcement): await say(Delivery(id: delivery.id, announcement: announcement))
                }
            }
            return true
        }
        return done ?? false
    }

    /// `deliver`, with the announcement put in front of the person on the
    /// main thread. `decide` answers for it where the store is (keep, discard,
    /// or delivered), and a delivered one is handed to `present` on the main
    /// thread without waiting for it: the store holds the cross-process lock
    /// while it delivers, and a main thread that is busy, or frozen, must
    /// never hold that lock against the other instance of a handover.
    public func deliver(deciding decide: @escaping @Sendable (Delivery) -> DeliveryResult,
                        onMain present: @escaping (Delivery) -> Void) async -> Bool {
        let box = MainQueueOnly(value: present)
        return await deliver { delivery in
            let result = decide(delivery)
            if case .delivered = result {
                DispatchQueue.main.async { box.value(delivery) }
            }
            return result
        }
    }

    // MARK: - Reading

    /// One release as the records hold it now, for `lodestar diagnose`.
    public struct Row: Sendable, Equatable {
        public let id: String
        /// The state read now, a timeout that has fallen due applied.
        public let state: ReleaseOnThisMac.State
        public let since: Moment
        /// Who made the latest entry and why.
        public let by: String?
        public let because: String?
    }

    /// Every record, oldest first; nil when the store could not be used.
    public func rows() async -> [Row]? {
        await perform("read") { store in
            let now = await store.moment(for: .now)
            var rows: [Row] = []
            for (id, record) in await store.records() {
                let reading = record.read(at: now)
                let last = try await store.history(of: id).last
                let by: String? = last.map {
                    switch $0.by {
                    case .timeout: "timeout"
                    case .principal(let principal): String(describing: principal)
                    }
                }
                rows.append(Row(id: id, state: reading.state, since: reading.since, by: by, because: last?.because))
            }
            return rows
        }
    }

    // MARK: - For `lodestar diagnose`

    /// The records as a paste-able report says them: each release's id, the
    /// state it is in now (a timeout that has fallen due applied), since when,
    /// and who made the latest entry and why, so "who moved it and why" is
    /// readable. The report is synchronous and read-only in spirit, so it
    /// makes no journal that is not there, and waits only a moment for the
    /// other process (`lockWait`).
    public static func diagnosis(path: String = standardPath, lockWait: Duration? = nil) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return ["releases: none recorded yet"] }
        // On the main thread (Send Feedback builds the report there) the
        // records are asked once and not waited for: the app's own updater may
        // hold the lock for a moment, and the report says so rather than hold
        // the main thread.
        let lockWait = lockWait ?? (Thread.isMainThread ? .zero : .seconds(1))
        let records = ReleaseRecords(path: path, lockWait: lockWait)
        let done = DispatchSemaphore(value: 0)
        let found = Mutex<[Row]?>(nil)
        Task {
            let rows = await records.rows()
            found.withLock { $0 = rows }
            done.signal()
        }
        // Bounded, whatever the store does: the report is somebody's evidence.
        let budget = Thread.isMainThread ? DispatchTimeInterval.milliseconds(500)
            : .seconds(Int(lockWait.components.seconds) + 2)
        guard done.wait(timeout: .now() + budget) == .success else {
            return ["releases: ⚠ the records did not answer"]
        }
        return lines(for: found.withLock { $0 })
    }

    /// The report's lines for rows read (nil: the store could not be used).
    static func lines(for rows: [Row]?) -> [String] {
        guard let rows else { return ["releases: ⚠ the records were busy or could not be opened (the log says which); the markers carry the update"] }
        guard !rows.isEmpty else { return ["releases: none recorded yet"] }
        let formatter = ISO8601DateFormatter()
        return ["releases:"] + rows.map { row in
            var line = "  \(row.id) \(row.state.rawValue) since \(formatter.string(from: row.since.date))"
            if let by = row.by { line += " · by \(by)" }
            if let because = row.because, !because.isEmpty { line += " · \(because)" }
            return line
        }
    }

    // MARK: - The queue

    private func enqueue(_ doing: String, _ body: @escaping @Sendable (Store) async throws -> Void) {
        let accepted = work.trySend { engine in
            _ = await engine.run(doing, body)
        }
        if !accepted {
            Log.warning("update", ["records": "skipped", "doing": doing, "why": "\(work.count) pieces of work are waiting"])
        }
    }

    private func perform<T: Sendable>(_ doing: String, _ body: @escaping @Sendable (Store) async throws -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let accepted = work.trySend { engine in
                continuation.resume(returning: await engine.run(doing, body))
            }
            if !accepted {
                Log.warning("update", ["records": "skipped", "doing": doing, "why": "\(work.count) pieces of work are waiting"])
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Engine

    /// What a piece of work needs, kept apart from the object the app holds
    /// so the task that reads the queue never keeps the queue's owner alive.
    final class Engine: Sendable {
        let path: String
        let fileSystem: any FileSystem
        let lockWait: Duration
        /// The ids that keep a release from being offered, as of the last piece of work.
        let refusing = Mutex<Set<String>>([])

        /// How often a store another process holds is asked for again.
        static let retryEvery = Duration.milliseconds(100)

        init(path: String, fileSystem: any FileSystem, lockWait: Duration) {
            self.path = path
            self.fileSystem = fileSystem
            self.lockWait = lockWait
        }

        /// The store, waiting for the other process to let go of it. Nil, logged, when it cannot be had.
        func open() async -> Store? {
            let attempts = max(1, Int(lockWait / Self.retryEvery))
            do throws(StoreError) {
                return try await retry(.fixed(Self.retryEvery).attempts(attempts), label: "release-records.open") { _ throws(StoreError) in
                    try await Store.open(at: path, fileSystem: fileSystem,
                                         journalOptions: Journal.Options(crossProcessLock: true))
                }
            } catch {
                Log.warning("update", ["records": "unavailable", "path": path,
                                       "consequence": "the markers carry the update as they did before records",
                                       "error": "\(error)"])
                return nil
            }
        }

        /// Opens the store, does `body`, keeps the snapshot of refusals current, and closes it again.
        /// A failure of `body` is logged, and answers nil.
        func run<T>(_ doing: String, _ body: (Store) async throws -> T) async -> T? {
            guard let store = await open() else { return nil }
            let value = await Log.attempt("update: release records: \(doing)") { try await body(store) }
            let now = await store.moment(for: .now)
            let held = await store.records().filter { $0.record.state(at: now).holdsTheOffer }.map(\.id)
            refusing.withLock { $0 = Set(held) }
            await Log.attempt("update: could not close the release records") { try await store.close() }
            excludeFromBackup()
            return value
        }

        /// Every file of the records out of backups as soon as it exists, not
        /// at the next launch's sweep: a record restored onto another Mac
        /// would tell it that a release failed there. Once per run is enough,
        /// and costs a directory listing.
        private func excludeFromBackup() {
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for file in files where file == name || file.hasPrefix(name + ".") {
                Paths.excludeFromBackup(folder.appendingPathComponent(file))
            }
        }

        enum Sent: Equatable {
            case moved
            /// The definition says the event means nothing here: a second confirm, a rollback read twice.
            case ignored
            case refused(String)
        }

        enum Failure: Error { case notFound(String), conflict, cancelled }

        /// One event, and what the definition made of it. Ignored and refused are answers, not failures:
        /// what is thrown is a record that is not there, a lost race, or the store.
        @discardableResult
        static func send(_ event: ReleaseOnThisMac.Event, to id: String, by principal: ReleaseOnThisMac.Principal,
                         because: String, store: Store) async throws -> Sent {
            let sent: Sent
            do throws(LifecycleUpdateError<ReleaseOnThisMac, StoreError>) {
                _ = try await store.apply(event, to: id, by: principal, because: because)
                sent = .moved
            } catch {
                switch error {
                case .refused(.ignored): sent = .ignored
                case .refused(.refused(_, _, let reason)): sent = .refused(reason)
                case .refused(let other): throw other
                case .notFound: throw Failure.notFound(id)
                case .conflict: throw Failure.conflict
                case .cancelled: throw Failure.cancelled
                case .storage(let failure): throw failure
                }
            }
            Log.info("update", ["record": id, "event": event.rawValue, "by": "\(principal)", "answer": "\(sent)"])
            return sent
        }

        /// The record for a release an earlier build applied, made from its marker: applying, by the importer.
        static func ensureApplying(_ id: String, store: Store) async throws {
            guard try await store.load(id) == nil else { return }
            _ = try await store.insert(
                .new(in: .applying, by: .importer, because: "applied by an earlier build; from its marker"), as: id)
        }

        static func state(of id: String, store: Store) async throws -> ReleaseOnThisMac.State? {
            try await store.read(id)?.state
        }

        static func boot(_ boot: Boot, store: Store) async -> BootResult {
            var result = BootResult()
            // A tombstone that names a release this boot also has a marker for is the marker's own: the
            // other instance of a handover writes it as soon as it reads the marker, before the record
            // has the verdict, and importing it first would refuse the release before the watchdog's
            // verdict (or the build that did not change) could be recorded as what it was.
            let named = Set([boot.updated, boot.rolledBack].compactMap { $0.flatMap(ReleaseOnThisMac.id(for:)) })
            if let tombstone = boot.tombstone, let id = ReleaseOnThisMac.id(for: tombstone), !named.contains(id) {
                await Log.attempt("update: could not import the refusal tombstone as a record") {
                    guard try await store.load(id) == nil else { return }
                    _ = try await store.insert(
                        .new(in: .refused, by: .importer, because: "the refusal tombstone an earlier build left names it"), as: id)
                }
            }
            if let marker = boot.updated, let id = ReleaseOnThisMac.id(for: marker) {
                result.updated = await Log.attempt("update: could not record the updated-to marker") {
                    try await ensureApplying(id, store: store)
                    if let version = Updater.parseVersion(marker), let here = Updater.parseVersion(boot.version),
                       Updater.sameVersion(version, here) {
                        try await send(.confirm, to: id, by: .successor(pid: boot.pid),
                                       because: "this build, \(boot.version), is the one the update applied", store: store)
                    } else {
                        try await send(.unchanged, to: id, by: .successor(pid: boot.pid),
                                       because: "relaunched as \(boot.version), which is not the \(marker) it applied",
                                       store: store)
                    }
                    return try await state(of: id, store: store)
                } ?? nil
            }
            if let marker = boot.rolledBack, let id = ReleaseOnThisMac.id(for: marker) {
                result.rolledBack = await Log.attempt("update: could not record the rolled-back marker") {
                    try await ensureApplying(id, store: store)
                    try await send(.rollBack, to: id, by: .watchdog,
                                   because: "\(marker) never took the pid file, and \(boot.version) was put back", store: store)
                    return try await state(of: id, store: store)
                } ?? nil
            }
            await Log.attempt("update: could not commit the timeouts that fell due") { _ = try await store.settleDue() }
            return result
        }
    }
}
