import Foundation

/// The walk: the first launch's spine, as a state machine the shell can only
/// draw. The person chooses a door on the welcome, Write, Switch, Keep or
/// Speak, and the walk is that door's few steps, each completed by the real
/// gesture happening in the real world. The engine reports what the hands
/// did, and the walk moves. Nothing here owns a window or a keyboard. The
/// card that renders `step` is never key, which is what makes the walk
/// structurally unable to brick anything. It teaches by detection and owns
/// nothing, and it ends in one real success: a typo fixed, a window
/// reached, a clip pasted, a sentence spoken into place.
///
/// Skipping is per step (`.pass`, the coach's "not this one"), never a
/// dismissal of the whole walk. The card persists until the walk is done,
/// by decision, and no card is ever on a clock. A step that cannot be
/// performed can always be passed.
public struct Walk: Equatable {
    /// What the person came for. The app never learns it from the download;
    /// the welcome asks every time, so every install begins the same way.
    public enum Door: String, CaseIterable, Codable, Equatable {
        case write
        case switcher = "switch"
        case keep
        case speak

        public var name: String {
            switch self {
            case .write: return "Write"
            case .switcher: return "Switch"
            case .keep: return "Keep"
            case .speak: return "Speak"
            }
        }
    }

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
        // Switch: the launcher before any letters, because on day one the
        // launcher already works and the letters do not exist yet.
        /// Summon a real app through the launcher.
        case launcher
        /// The drafted letters, offered as suggestions. Lode-lode accepts,
        /// lode ⌫ passes.
        case graphOffer([StarterGraph.Proposal])
        /// Use any letter of the graph, chosen from a few of their own.
        case graphGo(options: [GraphChoice])
        // Write
        /// A word typed wrong anywhere, and the line appears under it.
        case typo
        /// The fix taken, by the pointer or the keys.
        case fix
        /// Spelling works; a closer reader can be downloaded. Lode-lode
        /// takes the engine named, lode ⌫ keeps spelling alone.
        case grammar(engine: String)
        // Keep
        /// Anything copied, the usual way.
        case copy
        /// The strip opened, where a letter pastes.
        case strip
        // Speak
        /// The draft opened, listening.
        case draft
        /// The words landed where the cursor was.
        case land
        /// The closing card. It stays until the user closes it. Everything
        /// else is taught later, one lesson at a time, by the curriculum
        /// (`Curriculum`), on the same card.
        case done
    }

    /// What the world reports. The walk ignores anything its current step
    /// is not waiting for. A graph summon during the launcher step is a
    /// user exploring, not a sequence error.
    public enum Signal: Equatable {
        case launcherPick
        case assent
        case pass
        case graphSummon
        case editorMarked
        case editorFixed
        case clipCopied
        case draftLanded
        // Shared with the lessons: the Keep and Speak walks wait on two of
        // these, and the curriculum's cards on the rest, one each.
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
        /// Assent on the grammar step: the editor reads with this engine.
        case chooseEngine(String)
        case stepChanged
        case completed
    }

    public let door: Door
    public private(set) var step: Step
    private let proposals: [StarterGraph.Proposal]
    /// Addresses the user's own graph already answers to, for the graph
    /// step when there is nothing to offer (or the offer was passed).
    private let existing: [GraphChoice]
    /// The engine the grammar step offers, or nil when this Mac can run
    /// nothing closer than spelling and the step does not exist.
    private let grammar: String?

    /// This door's steps before the close, in order. A Switch walk with
    /// nothing to offer and nothing to press is just the launcher.
    private var plan: [Step] {
        switch door {
        case .switcher:
            var steps: [Step] = [.launcher]
            if !proposals.isEmpty { steps.append(.graphOffer(proposals)) }
            let options = existing.isEmpty ? Self.choices(from: proposals) : existing
            if !options.isEmpty { steps.append(.graphGo(options: options)) }
            return steps
        case .write:
            return [.typo, .fix] + (grammar.map { [.grammar(engine: $0)] } ?? [])
        case .keep:
            return [.copy, .strip]
        case .speak:
            return [.draft, .land]
        }
    }

    /// For persistence: the walk resumes from an index into its door's
    /// steps, recomputed fresh at show time. A step that no longer applies
    /// resolves forward, never backward.
    public var stepIndex: Int {
        if step == .done { return plan.count }
        return plan.firstIndex { Self.sameKind($0, step) } ?? 0
    }

    /// The card's counter, honest about conditional steps.
    public var progress: (position: Int, total: Int) {
        (min(stepIndex + 1, plan.count), plan.count)
    }

    public var isDone: Bool { step == .done }

    public init(door: Door, proposals: [StarterGraph.Proposal] = [], existing: [GraphChoice] = [],
                grammar: String? = nil, resumeAt index: Int = 0) {
        self.door = door
        self.proposals = proposals
        self.existing = existing
        self.grammar = grammar
        self.step = .done
        let plan = self.plan
        self.step = index < plan.count ? plan[max(0, index)] : .done
    }

    private static func sameKind(_ a: Step, _ b: Step) -> Bool {
        switch (a, b) {
        case (.graphOffer, .graphOffer), (.graphGo, .graphGo), (.grammar, .grammar): return true
        default: return a == b
        }
    }

    private static func choices(from proposals: [StarterGraph.Proposal]) -> [GraphChoice] {
        proposals.map { GraphChoice(path: $0.letter, label: $0.app) }
    }

    public mutating func handle(_ signal: Signal) -> [Effect] {
        if signal == .pass { return pass() }
        switch (step, signal) {
        case (.launcher, .launcherPick),
             (.graphGo, .graphSummon),
             (.typo, .editorMarked),
             (.fix, .editorFixed),
             (.copy, .clipCopied),
             (.strip, .clipboardOpened),
             (.draft, .draftOpened),
             (.land, .draftLanded):
            return advance()
        case (.graphOffer(let offered), .assent):
            // The freshly accepted letters are the ones to prove: pressing
            // one closes the loop the assent just opened.
            step = .graphGo(options: Self.choices(from: offered))
            return [.acceptProposals(offered), .stepChanged]
        case (.grammar(let engine), .assent):
            return [.chooseEngine(engine)] + advance()
        default:
            return []
        }
    }

    /// Passing a step moves on. Passing the offer declines it, and then
    /// only their own graph can carry the next step; without any, the walk
    /// is over.
    private mutating func pass() -> [Effect] {
        if case .graphOffer = step, existing.isEmpty {
            step = .done
            return [.stepChanged, .completed]
        }
        if case .graphOffer = step {
            step = .graphGo(options: existing)
            return [.stepChanged]
        }
        return advance()
    }

    /// The next step of this door's plan, or the close.
    private mutating func advance() -> [Effect] {
        guard step != .done else { return [] }
        let next = stepIndex + 1
        let plan = self.plan
        if next < plan.count {
            step = plan[next]
            return [.stepChanged]
        }
        step = .done
        return [.stepChanged, .completed]
    }
}
