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
/// **One delivery at a time.** A run delivers what is queued, oldest first,
/// and stops at the first note that did not go, since the ones behind it
/// would fail the same way. A run is never started while another is going:
/// whoever asks waits for the one running, then runs, so the window's Send
/// and the schedule's tick cannot send one note twice at once.
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
    /// into the same failure).
    static let policy = DeliveryPolicy(
        schedule: Schedule.immediate.attempts(1), classify: .standard, budget: RetryBudget(), onFailure: .stopAtFirst)

    /// Why a note stays in the queue, thrown out of a try so the outbox
    /// leaves it pending.
    private struct Unsent: Error {
        let reason: FeedbackOutcome.Reason
    }

    private let directory: URL
    private let client: HTTPClient
    private let fileSystem: any FileSystem
    private let schedule: Schedule

    private var outbox: Outbox<FeedbackEntry>?
    /// The run going now, if any: the single flight.
    private var running: Task<Void, Never>?
    /// The notes a `submit` is waiting on, and what the last try of each came
    /// to. A note the schedule delivers has no one waiting, and no entry.
    private var watching: Set<IdempotencyKey> = []
    private var outcomes: [IdempotencyKey: FeedbackOutcome] = [:]
    private var loop: (id: Int, task: Task<Void, Never>)?
    private var loops = 0
    /// Callers waiting for the run going now: for the tests, which must know
    /// a second caller has met the first before they let the first finish.
    private(set) var waiting = 0

    public init(directory: URL, client: HTTPClient = Feedback.client(), schedule: Schedule = FeedbackQueue.retrySchedule,
                fileSystem: any FileSystem = PosixFileSystem()) {
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
        // The key is made, and watched, before the note is written: a run
        // already going may find the note the moment it is, and its outcome
        // must not be missed.
        let key = IdempotencyKey.random()
        watching.insert(key)
        do {
            try await outbox.enqueue(FeedbackEntry(feedback), key: key)
        } catch {
            watching.remove(key)
            Log.error("feedback: could not save a note", ["error": "\(error.kind)"])
            return .notSaved
        }
        await drain(why: "submit")
        watching.remove(key)
        let outcome = outcomes.removeValue(forKey: key)
        switch outcome {
        case .delivered: return .delivered
        case .refused: return .refused
        // Unsent, or not tried at all because an older note stopped the run.
        case .unsent?, nil:
            // A note that did not go starts the schedule over, so a new note
            // is tried again in a minute and not at the end of an hour.
            startLoop(delayFirst: nil)
            return .queued
        }
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
        running?.cancel()
        await running?.value
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

    /// One run, alone. Whoever comes while another is going waits for it to
    /// end and then runs: a note saved while the run went was not in it.
    private func drain(why: String) async {
        while let current = running {
            waiting += 1
            await current.value
            waiting -= 1
        }
        guard let outbox = openOutbox() else { return }
        let run = Task { [weak self] in
            await self?.deliver(outbox, why: why)
            await self?.runEnded()
        }
        running = run
        await run.value
    }

    private func runEnded() { running = nil }

    private func deliver(_ outbox: Outbox<FeedbackEntry>, why: String) async {
        do {
            // Once more after dropping an unreadable note: it stopped the run
            // it was in, and the notes behind it are not to wait a minute.
            var dropped = true
            while dropped {
                dropped = false
                let report = try await outbox.deliverPending { entry in try await self.attempt(entry) }
                for failure in report.failed {
                    // A note that no longer reads is not a note any try can send,
                    // and left in front it would hold every later one.
                    guard let error = failure.error as? StoreError, error.kind == .corrupt, failure.attempts == 0 else { continue }
                    do {
                        try await outbox.discard(failure.key)
                        dropped = true
                        Log.error("feedback: dropped a queued note that no longer reads")
                    } catch {
                        Log.error("feedback: could not drop an unreadable queued note", ["error": "\(error.kind)"])
                    }
                }
                Log.info("feedback", ["run": why, "delivered": report.delivered.count,
                                      "failed": report.failed.count, "pending": report.remaining])
            }
        } catch is CancellationError {
            // Shut down mid-try: the note in flight is still queued.
        } catch {
            // The acknowledgement could not be written: the note is delivered
            // and will be again, under its key, which the site dedupes.
            Log.error("feedback: could not record a delivery", ["error": "\(error)"])
        }
    }

    /// One try at one note. A refusal returns, as a delivery does, so the
    /// outbox acknowledges it and the note leaves; only a note that may
    /// still be sent throws, and is left pending.
    private func attempt(_ entry: Outbox<FeedbackEntry>.Entry) async throws {
        let outcome: FeedbackOutcome
        do {
            let response = try await client.send(entry.item.feedback.httpRequest, idempotencyKey: entry.key)
            outcome = .classify(response)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            outcome = .classify(error)
        }
        if watching.contains(entry.key) { outcomes[entry.key] = outcome }
        Log.info("feedback", ["outcome": outcome.word, "report": entry.item.feedback.diagnostics == nil ? "no" : "yes"])
        if case .unsent(let reason) = outcome { throw Unsent(reason: reason) }
    }

    // MARK: - The outbox

    /// Opened when first wanted, and again after a failure: a launch that
    /// finds the files busy (the instance it replaced is still letting go)
    /// is not a launch that never sends.
    private func openOutbox() -> Outbox<FeedbackEntry>? {
        if let outbox { return outbox }
        do {
            // Created by Stoic, which syncs the parent, then closed to everyone
            // else: the files in it are 0o600 (OwnerOnlyFileSystem), and the
            // data directory above is 0o700.
            try fileSystem.createDirectory(directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            Paths.excludeFromBackup(directory)
            // The journal's own damage report is a count; a lost snapshot is
            // accepted (the notes it held are gone either way, and a queue
            // that refused to open would lose every note after them too).
            let opened = try Outbox<FeedbackEntry>.open(
                at: directory.appendingPathComponent("outbox").path, codec: FeedbackEntry.codec,
                fileSystem: OwnerOnlyFileSystem(fileSystem), policy: Self.policy,
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
