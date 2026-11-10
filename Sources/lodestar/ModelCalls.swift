import Foundation
import LodestarCore
import Stoic
import Synchronization

/// Whether a language model can answer now, for whoever would tell the hand
/// when it cannot (the editor says nothing to a field it cannot read, and
/// says so once).
enum ModelAbility: Equatable, Sendable {
    /// Answering, or not yet asked: nothing has gone wrong since the last
    /// answer.
    case able
    /// The last load failed or ran out of time, or the last generation
    /// never came back and nothing has answered since. Clears at the next
    /// answer or load.
    case unable
}

/// How one language model is asked, one thing at a time, so that a question
/// is bounded by its answer and never by the line it stood in.
///
/// The editor's model is asked from two places that drain concurrently and
/// shares the GPU with the dictation ear. Before, a question's eight-second
/// deadline started when it was asked, so time spent queued behind another
/// question or behind the ear was time the model did not have; a slow
/// minute made every question late, each late generation was abandoned
/// still running, and three of them refused every question until the app
/// restarted (42 times in three weeks, once for 50 minutes). Now:
///
/// - A question first waits for the process's MLX lane (`MLXGate`), at most
///   `wait` seconds. If it cannot start by then it is `busy`: nil at once,
///   never a generation, never on Stoic's ledger.
/// - Only once it holds the lane does the answer deadline start. A
///   generation that overruns is cancelled, and the lane is handed on when
///   it has actually stopped, not when it was given up on, so two
///   generations never overlap.
/// - A generation that overran and still has not stopped `stuckAfter`
///   seconds later is lost. `recoverIfStuck` takes the lane back from it
///   and starts a new ledger label, so the backend the caller then loads is
///   never refused for its predecessor's sins.
///
/// Every label is `name.generation`; a new backend is a new generation.
final class ModelCalls: Sendable {
    /// What a question came to.
    enum Asked<T: Sendable>: Sendable {
        case answer(T)
        /// It ran and gave nothing: an error, or the deadline.
        case unanswered
        /// It never got the lane in time.
        case busy

        var value: T? {
            if case .answer(let value) = self { return value }
            return nil
        }
    }

    /// One question that holds the lane (or would, for a model that is
    /// not MLX), from the moment it has it.
    private final class Hold: Sendable {
        enum Phase: Sendable {
            /// Has the lane; its work has not begun.
            case waiting
            case running
            /// The caller stopped waiting while the work was still running.
            case abandoned(at: AnyClock.Instant)
            case finished
            /// The lane was taken back from it.
            case lost
        }

        let id: UInt64
        let permit: MLXGate.Permit?
        let phase = Mutex<Phase>(.waiting)

        init(id: UInt64, permit: MLXGate.Permit?) {
            self.id = id
            self.permit = permit
        }

        /// Starts the work, unless the caller has already given up on it.
        func begin() -> Bool {
            phase.withLock { phase in
                guard case .waiting = phase else { return false }
                phase = .running
                return true
            }
        }

        /// The work is over, however it ended.
        func end() {
            phase.withLock { phase in
                if case .lost = phase { return }
                phase = .finished
            }
        }

        /// The caller has stopped waiting. True when the work never began
        /// (and now never will), so the caller must hand the lane back.
        func settle(abandoning now: AnyClock.Instant) -> Bool {
            phase.withLock { phase in
                switch phase {
                case .waiting:
                    phase = .finished
                    return true
                case .running:
                    phase = .abandoned(at: now)
                    return false
                default:
                    return false
                }
            }
        }

        /// How long ago the caller gave up on work that is still running.
        func abandonedFor(_ now: AnyClock.Instant) -> Duration? {
            phase.withLock { phase in
                guard case .abandoned(let at) = phase else { return nil }
                return at.duration(to: now)
            }
        }

        func lose() {
            phase.withLock { $0 = .lost }
        }
    }

    private struct State {
        var generation = 0
        var nextID: UInt64 = 0
        var holds: [UInt64: Hold] = [:]
        var ability = ModelAbility.able
    }

    let name: String
    let gate: MLXGate
    /// How long a generation may stay abandoned and running before it is
    /// given up on for good.
    let stuckAfter: Duration
    private let state = Mutex(State())
    /// A release has asked for MLX's buffer cache to be cleared and nobody
    /// has done it yet.
    private let clearPending = Mutex(false)

    /// Twenty seconds: the same the models service's requests are given
    /// before the peer ends it (`ModelsAPI.stuckAfter`), written once.
    static let defaultStuckAfter = TimeInterval(ModelsAPI.stuckAfter.components.seconds)

    init(name: String, gate: MLXGate = .shared, stuckAfter: TimeInterval = ModelCalls.defaultStuckAfter) {
        self.name = name
        self.gate = gate
        self.stuckAfter = .seconds(stuckAfter)
    }

    /// Clears MLX's buffer cache for a backend just let go of, holding the
    /// lane: the allocator is not known to be safe against an evaluation
    /// running on another thread (the ear's phrase), so it waits its turn
    /// like any other MLX work, without making the releasing actor wait.
    ///
    /// The next load does the clear itself, first thing under its own turn
    /// (`clearIfPending`), if it gets there before this does; whichever
    /// comes first clears and the other finds nothing to do. So a clear
    /// never runs after the backend that follows has loaded.
    func clearCacheSoon(_ clear: @escaping @Sendable () -> Void) {
        clearPending.withLock { $0 = true }
        Task { [self] in
            _ = await gate.run { clearIfPending(clear) }
        }
    }

    /// Clears now if a release is waiting for it. Call it only holding the
    /// lane.
    func clearIfPending(_ clear: () -> Void) {
        if clearPending.withLock({ pending in defer { pending = false }; return pending }) { clear() }
    }

    var ability: ModelAbility { state.withLock { $0.ability } }

    /// The ledger label for the backend now loaded.
    var label: String { state.withLock { "\(name).\($0.generation)" } }

    /// A new backend: its generations are counted on their own label.
    func backendReplaced() {
        state.withLock { $0.generation += 1 }
    }

    /// A load ended, one way or the other.
    func loadEnded(succeeded: Bool) {
        state.withLock { $0.ability = succeeded ? .able : .unable }
    }

    /// Asks `work` for an answer: at most `wait` seconds for the lane
    /// (when `gated`; a model that is not MLX needs none), then at most
    /// `deadline` seconds for the answer.
    func ask<T: Sendable>(deadline: TimeInterval, wait: TimeInterval, gated: Bool = true,
                          _ work: @escaping @Sendable () async -> T?) async -> Asked<T> {
        var permit: MLXGate.Permit?
        if gated {
            guard let got = await gate.acquire(within: .seconds(wait)) else { return .busy }
            permit = got
        }
        let hold = state.withLock { state -> Hold in
            state.nextID += 1
            let hold = Hold(id: state.nextID, permit: permit)
            state.holds[hold.id] = hold
            return hold
        }
        let began = Ambient.current.clock.now
        let answer = await EditorModel.within(deadline, label: label) { [self] () -> T? in
            guard hold.begin() else { return nil }
            // The lane goes on when the work has really stopped, which for
            // a generation cancelled at its deadline is a few tokens later.
            defer { finish(hold) }
            return await work()
        }
        if hold.settle(abandoning: Ambient.current.clock.now) { finish(hold) }
        if let answer {
            state.withLock { $0.ability = .able }
            return .answer(answer)
        }
        // Nil at or after the deadline is a generation that did not come
        // back; nil before it is a model that said it could not.
        if !Task.isCancelled, began.duration(to: Ambient.current.clock.now) >= .seconds(deadline) {
            state.withLock { $0.ability = .unable }
        }
        return .unanswered
    }

    private func finish(_ hold: Hold) {
        hold.end()
        state.withLock { _ = $0.holds.removeValue(forKey: hold.id) }
        if let permit = hold.permit { gate.release(permit) }
    }

    /// Takes the lane back from every generation that was given up on
    /// `stuckAfter` ago and has not stopped, and starts a new ledger label.
    /// Returns how many were lost, zero when all is well; the caller then
    /// lets go of the backend they ran on.
    func recoverIfStuck() -> Int {
        let now = Ambient.current.clock.now
        let lost = state.withLock { state -> [Hold] in
            let stuck = state.holds.values.filter { ($0.abandonedFor(now) ?? .zero) >= stuckAfter }
            for hold in stuck {
                hold.lose()
                state.holds.removeValue(forKey: hold.id)
            }
            if !stuck.isEmpty {
                state.generation += 1
                state.ability = .unable
            }
            return Array(stuck)
        }
        // Released outside the state's lock: handing the lane on resumes
        // the next waiter. The lost holder's own release, if it ever comes,
        // finds the lane held by someone else and does nothing.
        for hold in lost { if let permit = hold.permit { gate.release(permit) } }
        return lost.count
    }
}
