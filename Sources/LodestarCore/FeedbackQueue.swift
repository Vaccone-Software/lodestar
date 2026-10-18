import Foundation
import Stoic
import StoicHTTP
import StoicStore

/// Where a note waits until the site has it: Stoic's `Outbox` on disk, the
/// client that carries it, and the schedule that goes on trying while any
/// are left.
///
/// A note is durable the moment `submit` takes it (written and synced before
/// anything is sent), is delivered under one `IdempotencyKey` for as many
/// tries, launches and days as it takes, and leaves the queue only when the
/// site says it has it or says it never will. The site passes the key on to
/// the mail service, so a note delivered twice (the answer was lost, or the
/// app quit between the answer and the acknowledgement) is one email.
///
/// **One delivery at a time**, which is the outbox's own rule (design/15):
/// the window's Send attends to the note it just saved (`deliver(_:using:)`),
/// the schedule's tick delivers what is queued, oldest first, and stops at
/// the first note that did not go (`deliverPending`). Neither is ever started
/// while the other is going: a Send that meets a run waits for it, and a tick
/// that meets a Send finds the queue busy and leaves the note to it, so one
/// note is never sent twice at once. A new note is not held behind an older
/// one that is failing; the older one stays queued, and the schedule has it.
///
/// **What the person is told** is `Submission`; the log carries counts and
/// outcomes only, never a word of a note or a reply address.
public actor FeedbackQueue {
    /// What `submit` came to, for the window.
    public enum Submission: Equatable, Sendable {
        /// The site has it.
        case delivered
        /// Saved, and not sent yet. The queue goes on trying by itself.
        case queued
        /// Saved, and the site refused it for good, so it is gone from the
        /// queue. The window still holds the person's text.
        case refused
        /// Not saved: the outbox could not be opened or written. Nothing
        /// was kept, so the caller must.
        case notSaved
    }

    /// The first try after a launch, once the app has settled.
    public static let launchDelay = Duration.seconds(20)

    /// A minute, five, half an hour, then every hour for as long as notes
    /// are queued, each wait drawn between its half and its whole so that
    /// a thousand Macs that came back online together do not knock together.
    public static let retrySchedule: Schedule =
        Schedule.delays([.seconds(60), .seconds(300), .seconds(1800)]).schedule
            .andThen(.fixed(.seconds(3600)))
            .jittered(.equal)

    /// A try is one attempt, with the client's own timeout: the schedule
    /// above is the retrying, and a window that waited out an in-run
    /// backoff would hold the person for half a minute. The note that
    /// failed stops the run (order matters less than not sending the rest
    /// into the same failure). A note that no longer reads (a format this
    /// build cannot decode, damage the journal's own checks let through)
    /// is dropped, and the run goes on: left in front, it would hold every
    /// later one. This build reads every later format of its own note, so
    /// what does not read is not a note.
    static let policy = DeliveryPolicy(
        schedule: Schedule.immediate.attempts(1), classify: .standard, budget: RetryBudget(), onFailure: .stopAtFirst,
        onUndecodable: .discard)

    /// Why a note stays in the queue, thrown out of a try so the outbox
    /// leaves it pending.
    private struct Unsent: Error {
        let reason: FeedbackOutcome.Reason
    }

    /// The files a note waits in are the person's own words, and a reply
    /// address, and maybe a log: closed to everyone else, created so (not
    /// narrowed after), in a directory only the owner can enter.
    public static func privateFileSystem() -> PosixFileSystem {
        PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)
    }

    private let directory: URL
    private let client: HTTPClient
    private let fileSystem: any FileSystem
    private let schedule: Schedule

    private var outbox: Outbox<FeedbackEntry>?
    /// The deliveries going now (a Send's, a tick's), so that a shutdown can
    /// stop them before it lets go of the files. The outbox keeps them one
    /// at a time; this only keeps count of them.
    private var deliveries: [Int: Going] = [:]
    private var deliveryCount = 0

    /// A delivery in progress: how to stop it, and when it has.
    private struct Going {
        let cancel: @Sendable () -> Void
        let finished: Task<Void, Never>
    }
    private var loop: (id: Int, task: Task<Void, Never>)?
    private var loops = 0

    /// How many deliveries are in progress or waiting their turn at the
    /// outbox: for the tests, which must know a second caller has met the
    /// first before they let the first finish.
    var deliveriesInProgress: Int { deliveries.count }

    public init(directory: URL, client: HTTPClient = Feedback.client(), schedule: Schedule = FeedbackQueue.retrySchedule,
                fileSystem: any FileSystem = FeedbackQueue.privateFileSystem()) {
        self.directory = directory
        self.client = client
        self.schedule = schedule
        self.fileSystem = fileSystem
    }

    // MARK: - Submitting

    /// Takes a note: saved first, then one try at once. Answers when that
    /// try has ended, which is at most a twenty-second try (more if a run
    /// of older notes is going, which is waited for).
    public func submit(_ feedback: Feedback) async -> Submission {
        guard let outbox = openOutbox() else { return .notSaved }
        let key = IdempotencyKey.random()
        do {
            try await outbox.enqueue(FeedbackEntry(feedback), key: key)
        } catch {
            Log.error("feedback: could not save a note", ["error": "\(error.kind)"])
            return .notSaved
        }
        let outcome = await delivery { () async -> DeliveryOutcome? in
            do {
                return try await outbox.deliver(key) { entry in try await self.attempt(entry) }
            } catch is CancellationError {
                // Shut down mid-try: the note in flight is still queued.
                return nil
            } catch {
                // The acknowledgement could not be written: the note may be
                // delivered and will be again, under its key, which the site
                // dedupes. What the window says is that it is saved.
                Log.error("feedback: could not record a delivery", ["error": "\(error)"])
                return nil
            }
        }
        switch outcome {
        case .delivered?:
            await sendTheRest()
            return .delivered
        case .discarded?:
            await sendTheRest()
            return .refused
        // Not sent, or not told: the note stays, and the schedule has it.
        case .failed?, .kept?, .notPending?, nil:
            // A note that did not go starts the schedule over, so a new note
            // is tried again in a minute and not at the end of an hour.
            startLoop(delayFirst: nil)
            return .queued
        }
    }

    /// The site just answered, so it is there: older notes that were waiting
    /// for the schedule need not. The window waited as long before, when a
    /// Send ran the older notes first.
    private func sendTheRest() async {
        guard await hasPending() else { return }
        await drain(why: "after a send")
    }

    /// How many notes are waiting.
    public var pendingCount: Int {
        get async { await outbox?.pendingCount ?? 0 }
    }

    /// Until the schedule has nothing left to try: for the tests.
    func loopFinished() async {
        await loop?.task.value
    }

    // MARK: - Launch

    /// At launch: if a note was left waiting, try again after `delay` and
    /// then on the schedule. Costs nothing, not even opening a file, when
    /// the person never sent one.
    public func resume(after delay: Duration = FeedbackQueue.launchDelay) {
        guard (try? fileSystem.exists(directory.path)) == true else { return }
        startLoop(delayFirst: delay)
    }

    /// Stops the schedule and lets go of the files. A run in the middle of
    /// a try is cancelled and its note stays queued. For a relaunch in a
    /// test, and the app's own end.
    public func shutdown() async {
        loop?.task.cancel()
        let finishing = loop?.task
        loop = nil
        await finishing?.value
        let going = Array(deliveries.values)
        for delivery in going { delivery.cancel() }
        for delivery in going { await delivery.finished.value }
        if let outbox {
            do {
                try await outbox.close()
            } catch {
                Log.warning("feedback: the outbox did not close cleanly", ["error": "\(error.kind)"])
            }
        }
        outbox = nil
    }

    // MARK: - The schedule

    /// (Re)starts the loop that tries again while notes remain. With a
    /// `delayFirst` it waits that long before the first run (a launch); with
    /// none it waits the schedule's first delay (a try that has just failed).
    private func startLoop(delayFirst: Duration?) {
        loop?.task.cancel()
        loops += 1
        let id = loops
        let schedule = self.schedule
        let task = Task { [weak self] in
            await recur(schedule, label: "feedback") { run in
                guard let self else { return .stop }
                if run.number == 1 {
                    // A try has just failed, so the first thing is to wait:
                    // that is the schedule's first delay, taken below.
                    if let delayFirst {
                        do {
                            try await Ambient.sleep(for: delayFirst)
                        } catch {
                            return .stop
                        }
                        await self.drain(why: "launch")
                    }
                } else {
                    await self.drain(why: "retry")
                }
                return await self.hasPending() ? .continue : .stop
            }
            await self?.loopEnded(id)
        }
        loop = (id, task)
    }

    private func loopEnded(_ id: Int) {
        if loop?.id == id { loop = nil }
    }

    private func hasPending() async -> Bool {
        guard let outbox = openOutbox() else { return true }
        return await outbox.pendingCount > 0
    }

    // MARK: - Delivering

    /// Runs `work` as a delivery the queue knows of, in a task of its own
    /// that cancelling the caller (or a shutdown) cancels.
    private func delivery<Result: Sendable>(_ work: @escaping @Sendable () async -> Result) async -> Result {
        deliveryCount += 1
        let id = deliveryCount
        let task = Task { await work() }
        deliveries[id] = Going(cancel: { task.cancel() }, finished: Task { _ = await task.value })
        defer { deliveries[id] = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// One run: what is queued, oldest first, until a note does not go.
    private func drain(why: String) async {
        guard let outbox = openOutbox() else { return }
        await delivery { await self.deliver(outbox, why: why) }
    }

    private func deliver(_ outbox: Outbox<FeedbackEntry>, why: String) async {
        do {
            let report = try await outbox.deliverPending { entry in try await self.attempt(entry) }
            if report.wasAlreadyRunning {
                // A Send is attending to its note, and will see to the rest.
                Log.info("feedback", ["run": why, "skipped": "busy", "pending": report.remaining])
                return
            }
            for dropped in report.discarded where dropped.reason == .undecodable {
                // A note that no longer reads is not a note any try can send.
                Log.error("feedback: dropped a queued note that no longer reads")
            }
            Log.info("feedback", ["run": why, "delivered": report.delivered.count,
                                  "refused": report.discarded.count, "failed": report.failed.count,
                                  "pending": report.remaining])
        } catch is CancellationError {
            // Shut down mid-try: the note in flight is still queued.
        } catch {
            // The acknowledgement could not be written: the note is delivered
            // and will be again, under its key, which the site dedupes.
            Log.error("feedback: could not record a delivery", ["error": "\(error)"])
        }
    }

    /// One try at one note, and what became of it: the site took it
    /// (`.delivered`), read it and will never take it (`.discard`: a 400,
    /// which is what it answers an empty or unreadable note, and the app
    /// sends neither), or nothing is known to have happened (thrown, so the
    /// outbox leaves it pending and the schedule tries again).
    private nonisolated func attempt(_ entry: Outbox<FeedbackEntry>.Entry) async throws -> DeliveryResult {
        let outcome: FeedbackOutcome
        do {
            let response = try await client.send(entry.item.feedback.httpRequest, idempotencyKey: entry.key)
            outcome = .classify(response)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            outcome = .classify(error)
        }
        Log.info("feedback", ["outcome": outcome.word, "report": entry.item.feedback.diagnostics == nil ? "no" : "yes"])
        switch outcome {
        case .delivered: return .delivered
        case .refused: return .discard(reason: "refused")
        case .unsent(let reason): throw Unsent(reason: reason)
        }
    }

    // MARK: - The outbox

    /// Opened when first wanted, and again after a failure: a launch that
    /// finds the files busy (the instance it replaced is still letting go)
    /// is not a launch that never sends.
    private func openOutbox() -> Outbox<FeedbackEntry>? {
        if let outbox { return outbox }
        do {
            // Created by Stoic, which syncs the parent, closed to everyone
            // else (`privateFileSystem`: files 0o600, directories 0o700).
            try fileSystem.createDirectory(directory.path)
            Paths.excludeFromBackup(directory)
            // The journal's own damage report is a count; a lost snapshot is
            // accepted (the notes it held are gone either way, and a queue
            // that refused to open would lose every note after them too).
            let opened = try Outbox<FeedbackEntry>.open(
                at: directory.appendingPathComponent("outbox").path, codec: FeedbackEntry.codec,
                fileSystem: fileSystem, policy: Self.policy,
                journalOptions: .init(crossProcessLock: true, lostSnapshot: .acceptLoss))
            let report = opened.openReport
            if report.lostSnapshot || !report.corruption.isEmpty {
                Log.warning("feedback: the outbox was damaged", [
                    "lost_snapshot": report.lostSnapshot ? "yes" : "no",
                    "damaged_stretches": report.corruption.count,
                    "records_lost": report.corruptRecords])
            }
            outbox = opened
            return opened
        } catch {
            Log.error("feedback: could not open the outbox", ["error": "\(error.kind)"])
            return nil
        }
    }
}
