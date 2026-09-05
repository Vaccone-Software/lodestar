import Foundation

/// The walk: the tutorial's spine, as a state machine the shell can only
/// draw. Eight steps at most, each completed by the real gesture happening
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
    /// One address the graph card can invite the user to press: a chain
    /// (letters separated by spaces) and the app it reaches. The card
    /// offers several and prescribes none, because "press A" once told
    /// somebody to open Asana they had no wish to open.
    public struct GraphChoice: Equatable {
        public let path: String
        public let label: String

        public init(path: String, label: String) {
            self.path = path
            self.label = label
        }
    }

    public enum Step: Equatable {
        /// Hold the lode key until the map appears (the peek).
        case lodeKey
        /// Summon a real app through the launcher.
        case launcher
        /// The drafted letters, offered. Lode-lode accepts, lode ⌫ passes.
        case graphOffer([StarterGraph.Proposal])
        /// Use any letter of the graph, chosen from a few of their own.
        case graphGo(options: [GraphChoice])
        /// The closing card. It stays until the user closes it. Everything
        /// past the letters is taught later, one lesson at a time, by the
        /// curriculum (`Curriculum`), on the same card.
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
        // The lessons' signals. The walk itself waits on none of these;
        // the curriculum's cards do, one each.
        case hintsEnded
        case webBarOpened
        case clipboardOpened
        case cheatOpened
        case draftOpened
        case selectEnded
        case commandsOpened
        case scrollEnded
    }

    public enum Effect: Equatable {
        /// Assent on the offer: write these through the same path ⌘K uses.
        case acceptProposals([StarterGraph.Proposal])
        case stepChanged
        case completed
    }

    public private(set) var step: Step
    private let proposals: [StarterGraph.Proposal]
    /// Addresses the user's own graph already answers to, for the graph
    /// step when there is nothing to offer (or the offer was passed).
    private let existing: [GraphChoice]

    /// For persistence: the walk resumes from an index, with proposals and
    /// the graph recomputed fresh at show time. Steps that no longer apply
    /// (an offer with nothing to offer) resolve forward, never backward.
    public var stepIndex: Int {
        switch step {
        case .lodeKey: return 0
        case .launcher: return 1
        case .graphOffer: return 2
        case .graphGo: return 3
        case .done: return 4
        }
    }

    /// The card's counter, honest about conditional steps: an existing
    /// user is never told there are seven when their walk has six.
    public var progress: (position: Int, total: Int) {
        var indices = [0, 1]
        if !proposals.isEmpty { indices.append(2) }
        if !existing.isEmpty || !proposals.isEmpty { indices.append(3) }
        let position = indices.filter { $0 < stepIndex }.count + 1
        return (min(position, indices.count), indices.count)
    }

    public var isDone: Bool { step == .done }

    public init(proposals: [StarterGraph.Proposal], existing: [GraphChoice],
                resumeAt index: Int = 0) {
        self.proposals = proposals
        self.existing = existing
        self.step = Self.resolve(index: index, proposals: proposals,
                                 existing: existing)
    }

    /// The step an index means today. An offer step with no proposals falls
    /// through to the graph step, and a graph step with nothing to press
    /// falls through to what follows. Resuming can only land somewhere real.
    private static func resolve(index: Int, proposals: [StarterGraph.Proposal],
                                existing: [GraphChoice]) -> Step {
        switch index {
        case ..<1: return .lodeKey
        case 1: return .launcher
        case 2 where !proposals.isEmpty: return .graphOffer(proposals)
        case 2, 3:
            let options = existing.isEmpty ? Self.choices(from: proposals) : existing
            return options.isEmpty ? .done : .graphGo(options: options)
        default: return .done
        }
    }

    private static func choices(from proposals: [StarterGraph.Proposal]) -> [GraphChoice] {
        proposals.map { GraphChoice(path: $0.letter, label: $0.app) }
    }

    public mutating func handle(_ signal: Signal) -> [Effect] {
        if signal == .pass { return advance() }
        switch (step, signal) {
        case (.lodeKey, .peeked):
            return advance()
        case (.launcher, .launcherPick):
            return advance()
        case (.graphOffer(let offered), .assent):
            // The freshly accepted letters are the ones to prove: pressing
            // one closes the loop the assent just opened.
            step = .graphGo(options: Self.choices(from: offered))
            return [.acceptProposals(offered), .stepChanged]
        case (.graphGo, .graphSummon):
            return advance()
        default:
            return []
        }
    }

    /// The next step that exists, given what this user has. Passing the
    /// offer declines it. The graph step then needs addresses they already
    /// own, and without any it is not performable and resolves onward.
    private mutating func advance() -> [Effect] {
        switch step {
        case .lodeKey:
            step = .launcher
        case .launcher:
            step = Self.resolve(index: 2, proposals: proposals, existing: existing)
        case .graphOffer:
            // Declined: only their own graph can carry the next step, and
            // with none the walk is over.
            if existing.isEmpty {
                step = .done
                return [.stepChanged, .completed]
            }
            step = .graphGo(options: existing)
        case .graphGo:
            step = .done
            return [.stepChanged, .completed]
        case .done:
            return []
        }
        return [.stepChanged]
    }
}
