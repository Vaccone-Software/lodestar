import Foundation

/// The walk: the tutorial's spine, as a state machine the shell can only
/// draw. Seven steps at most, each completed by the real gesture happening
/// in the real world. The engine reports what the hands did, and the walk
/// moves. Nothing here owns a window or a keyboard. The card that renders
/// `step` is never key, which is what makes the walk structurally unable
/// to brick anything. The old deck taught by enumeration and owned the
/// screen. The walk teaches by detection and owns nothing.
///
/// Skipping is per step (`.pass`, the coach's "not this one"), never a
/// dismissal of the whole walk. The card persists until the walk is done,
/// by decision, and no card is ever on a clock. A step that cannot be
/// performed can always be passed.
public struct Walk: Equatable {
    public enum Step: Equatable {
        /// Hold the lode key until the map appears (the peek).
        case lodeKey
        /// Summon a real app through the launcher.
        case launcher
        /// The drafted letters, offered. Lode-lode accepts, lode ⌫ passes.
        case graphOffer([StarterGraph.Proposal])
        /// Use one letter of the graph, theirs or the freshly accepted.
        case graphGo(letter: String)
        /// Working inside the window: hints, shown by doing.
        case inside
        /// Ask, shown by opening it once.
        case web
        /// Open the cheat sheet once, so it becomes a place they have been.
        case sheet
        /// The closing card. It stays until the user closes it.
        case done
    }

    /// What the world reports. The walk ignores anything its current step
    /// is not waiting for. A graph summon during the launcher step is a
    /// user exploring, not a sequence error.
    public enum Signal: Equatable {
        case peeked
        case launcherPick
        case assent
        case pass
        case graphSummon
        case hintsEntered
        case webBarOpened
        case cheatOpened
    }

    public enum Effect: Equatable {
        /// Assent on the offer: write these through the same path ⌘K uses.
        case acceptProposals([StarterGraph.Proposal])
        case stepChanged
        case completed
    }

    public private(set) var step: Step
    private let proposals: [StarterGraph.Proposal]
    /// A letter the user's own graph already answers to, for the graphGo
    /// step when there is nothing to offer (or the offer was passed).
    private let existingLetter: String?

    /// For persistence: the walk resumes from an index, with proposals and
    /// the graph recomputed fresh at show time. Steps that no longer apply
    /// (an offer with nothing to offer) resolve forward, never backward.
    public var stepIndex: Int {
        switch step {
        case .lodeKey: return 0
        case .launcher: return 1
        case .graphOffer: return 2
        case .graphGo: return 3
        case .inside: return 4
        case .web: return 5
        case .sheet: return 6
        case .done: return 7
        }
    }

    /// The card's counter, honest about conditional steps: an existing
    /// user is never told there are seven when their walk has six.
    public var progress: (position: Int, total: Int) {
        var indices = [0, 1]
        if !proposals.isEmpty { indices.append(2) }
        if existingLetter != nil || !proposals.isEmpty { indices.append(3) }
        indices.append(contentsOf: [4, 5, 6])
        let position = indices.filter { $0 < stepIndex }.count + 1
        return (min(position, indices.count), indices.count)
    }

    public var isDone: Bool { step == .done }

    public init(proposals: [StarterGraph.Proposal], existingLetter: String?,
                resumeAt index: Int = 0) {
        self.proposals = proposals
        self.existingLetter = existingLetter
        self.step = Self.resolve(index: index, proposals: proposals,
                                 existingLetter: existingLetter)
    }

    /// The step an index means today. An offer step with no proposals falls
    /// through to the graph step, and a graph step with no letter falls
    /// through to what follows. Resuming can only ever land somewhere real.
    private static func resolve(index: Int, proposals: [StarterGraph.Proposal],
                                existingLetter: String?) -> Step {
        switch index {
        case ..<1: return .lodeKey
        case 1: return .launcher
        case 2 where !proposals.isEmpty: return .graphOffer(proposals)
        case 2, 3:
            if let letter = existingLetter ?? proposals.first?.letter {
                return .graphGo(letter: letter)
            }
            return .inside
        case 4: return .inside
        case 5: return .web
        case 6: return .sheet
        default: return .done
        }
    }

    public mutating func handle(_ signal: Signal) -> [Effect] {
        if signal == .pass { return advance() }
        switch (step, signal) {
        case (.lodeKey, .peeked):
            return advance()
        case (.launcher, .launcherPick):
            return advance()
        case (.graphOffer(let offered), .assent):
            step = .graphGo(letter: offered.first?.letter ?? existingLetter ?? "")
            return [.acceptProposals(offered), .stepChanged]
        case (.graphGo, .graphSummon):
            return advance()
        case (.inside, .hintsEntered):
            return advance()
        case (.web, .webBarOpened):
            return advance()
        case (.sheet, .cheatOpened):
            return advance()
        default:
            return []
        }
    }

    /// The next step that exists, given what this user has. Passing the
    /// offer declines it. The graph step then needs a letter they already
    /// own, and without one it is not performable and resolves onward.
    private mutating func advance() -> [Effect] {
        switch step {
        case .lodeKey:
            step = .launcher
        case .launcher:
            step = Self.resolve(index: 2, proposals: proposals,
                                existingLetter: existingLetter)
        case .graphOffer:
            // Declined: only their own graph can carry the next step.
            if let letter = existingLetter {
                step = .graphGo(letter: letter)
            } else {
                step = .inside
            }
        case .graphGo:
            step = .inside
        case .inside:
            step = .web
        case .web:
            step = .sheet
        case .sheet:
            step = .done
            return [.stepChanged, .completed]
        case .done:
            return []
        }
        return [.stepChanged]
    }
}
