import Foundation
import Stoic
import Synchronization

/// One lane for everything that evaluates on the GPU through MLX.
///
/// MLX is not safe for two threads to evaluate at once, and Lodestar has
/// two independent users of it: the editor's language model (a
/// `ModelContainer` with its own actor) and the dictation ear Qwen3-ASR
/// (its own dispatch queue). Each serialized itself and neither knew of
/// the other, so a sentence check landing in the middle of a phrase made
/// both slow: the ear's phrases ran 3 to 9 s instead of 0.5 s, the
/// editor's answers missed their deadline, and 42 times in three weeks the
/// editor was left abandoning generations until it refused every question
/// for as long as the app ran (up to 50 minutes). The cure is one holder
/// at a time, for the whole process.
///
/// First come, first served, and a waiter that leaves, because its task was
/// cancelled or its patience ran out, never runs and never takes the lane
/// from the one behind it. The holder is given a `Permit`; releasing one that
/// no longer holds (the lane was taken back, see `release`) does nothing,
/// so a late release can never free the lane from its new holder.
///
/// Pure concurrency: nothing here links MLX, so Core can own it and both
/// the app and the ears can use it.
public final class MLXGate: Sendable {
    /// Every MLX evaluation in the process passes through this one. Tests
    /// build their own so they never wait on each other.
    public static let shared = MLXGate()

    /// Proof of holding the lane.
    public struct Permit: Sendable, Hashable {
        let id: UInt64
    }

    private struct Waiter {
        let id: UInt64
        /// Hands the lane over (a permit), or turns the waiter away (nil).
        let resume: @Sendable (Permit?) -> Void
    }

    private struct State {
        var nextID: UInt64 = 0
        var holder: UInt64?
        var queue: [Waiter] = []
        /// Acquires that have begun and not yet been answered, so a cancel
        /// or a timeout that arrives before the waiter is queued is not lost.
        var pending: Set<UInt64> = []
        var leftEarly: Set<UInt64> = []
    }

    /// Where a blocked thread finds the permit it was woken with.
    private final class Granted: Sendable {
        let permit = Mutex<Permit?>(nil)
    }

    private let state = Mutex(State())

    public init() {}

    /// Is anyone holding the lane right now?
    public var isHeld: Bool { state.withLock { $0.holder != nil } }

    /// How many are waiting behind the holder.
    public var waiting: Int { state.withLock { $0.queue.count } }

    /// The lane, or nil when `wait` ran out or the task was cancelled
    /// first. With no `wait`, only cancellation ends the wait. Pair every
    /// permit with `release`.
    ///
    /// The wait is timed on the ambient clock, so a test spends none of it.
    public func acquire(within wait: Duration? = nil) async -> Permit? {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.pending.insert(state.nextID)
            return state.nextID
        }
        let timer = wait.map { wait in
            Task { [self] in
                do { try await Ambient.sleep(for: wait) } catch { return }
                leave(id)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Permit?, Never>) in
                enqueue(id) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            leave(id)
        }
    }

    /// The lane for a thread that may block: a dispatch queue of the
    /// caller's own, never the cooperative pool. Waits as long as it takes.
    public func acquireBlocking() -> Permit {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.pending.insert(state.nextID)
            return state.nextID
        }
        let semaphore = DispatchSemaphore(value: 0)
        let granted = Granted()
        enqueue(id) { permit in
            granted.permit.withLock { $0 = permit }
            semaphore.signal()
        }
        semaphore.wait()
        return granted.permit.withLock { $0 }!
    }

    /// Gives the lane back. Idempotent, and a permit that no longer holds
    /// (it was released already, or taken back) is ignored.
    ///
    /// Calling it for a holder that is stuck is the one way to take the
    /// lane from it: whoever supervises the holder decides it is lost, and
    /// the next waiter goes. The holder's own release, if it ever comes,
    /// then does nothing.
    public func release(_ permit: Permit) {
        let next: (Waiter, Permit)? = state.withLock { state in
            guard state.holder == permit.id else { return nil }
            return handOver(&state)
        }
        if let (waiter, granted) = next { waiter.resume(granted) }
    }

    /// Runs `work` holding the lane. Nil when the wait for it ended first;
    /// then `work` never ran.
    public func run<T: Sendable>(within wait: Duration? = nil,
                                 _ work: @Sendable () async throws -> T) async rethrows -> T? {
        guard let permit = await acquire(within: wait) else { return nil }
        defer { release(permit) }
        return try await work()
    }

    /// Runs `work` holding the lane, on the calling thread, which blocks
    /// until it has the lane.
    public func runBlocking<T>(_ work: () throws -> T) rethrows -> T {
        let permit = acquireBlocking()
        defer { release(permit) }
        return try work()
    }

    // MARK: - The queue

    /// Takes the lane if it is free and nobody is ahead, else queues.
    private func enqueue(_ id: UInt64, _ resume: @escaping @Sendable (Permit?) -> Void) {
        enum Outcome { case granted, left, queued }
        let outcome = state.withLock { state -> Outcome in
            if state.leftEarly.remove(id) != nil {
                state.pending.remove(id)
                return .left
            }
            if state.holder == nil, state.queue.isEmpty {
                state.holder = id
                state.pending.remove(id)
                return .granted
            }
            state.queue.append(Waiter(id: id, resume: resume))
            return .queued
        }
        switch outcome {
        case .granted: resume(Permit(id: id))
        case .left: resume(nil)
        case .queued: break
        }
    }

    /// Takes waiter `id` out: it was cancelled or ran out of patience. No
    /// effect once it has been answered.
    private func leave(_ id: UInt64) {
        let gone: Waiter? = state.withLock { state in
            guard state.pending.contains(id) else { return nil }
            if let index = state.queue.firstIndex(where: { $0.id == id }) {
                state.pending.remove(id)
                return state.queue.remove(at: index)
            }
            state.leftEarly.insert(id)
            return nil
        }
        gone?.resume(nil)
    }

    /// The lane passes to the head of the queue, or is left free.
    private func handOver(_ state: inout State) -> (Waiter, Permit)? {
        guard !state.queue.isEmpty else {
            state.holder = nil
            return nil
        }
        let next = state.queue.removeFirst()
        state.holder = next.id
        state.pending.remove(next.id)
        return (next, Permit(id: next.id))
    }
}
