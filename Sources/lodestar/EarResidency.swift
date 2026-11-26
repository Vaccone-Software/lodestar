import Stoic

/// What the draft's ears, and the language model beside them, are held for,
/// and what each change owes: loads, releases, and the idle spans
/// (`IdleSpan`). Declared once (Stoic design/27) and run live by `EarHost`,
/// which does what a step owes, in order, on the main thread.
///
/// The desired state comes from use (a draft open, phrases heard outside
/// it), from what macOS says about memory, and from the idle spans. A load
/// is never asked for while one is on its way, and nothing is unloaded under
/// one.
enum EarResidency: Lifecycle {
    static let name = "lodestar.ears"

    /// Nothing is recorded: the machine is live, and only this app steps it.
    enum Principal: Hashable, Sendable, Codable { case lodestar }

    /// What a load is for.
    enum Load: Hashable, Sendable, Codable {
        /// Dictation: every cold ear, the quick one first.
        case draft
        /// A phrase outside the draft: the one ear it is heard by.
        case phrase
    }

    struct State: Hashable, Sendable, Codable {
        /// Between dictation starting and the draft closing: the ear is
        /// being used, whatever the memory says.
        var draft = false
        /// Phrases being heard outside the draft (`lodestar transcribe`).
        var phrases = 0
        /// The load on its way: one at a time, never two of one ear.
        var loading: Load?
        /// macOS said memory was critical while the ear was in use: it goes
        /// the moment the draft closes, not thirty minutes on.
        var pressed = false
        /// The same, for the language model and the ear behind, which go on
        /// a warning too.
        var modelPressed = false

        /// A memory signal waits: a dictation never loses its ear
        /// mid-sentence to a signal that may have passed.
        var busy: Bool { draft || loading != nil }
    }

    enum Event: Hashable, Sendable, Codable {
        /// Dictation started.
        case opened
        /// The draft closed.
        case closed
        /// A phrase outside the draft begins, by an ear that is not loaded
        /// (`cold`) or is.
        case phraseBegan(cold: Bool)
        case phraseEnded
        /// The load on its way is over; `loaded` unless it failed.
        case loadEnded(loaded: Bool)
        /// macOS: memory is short.
        case warning
        /// macOS: memory is critical.
        case critical
    }

    enum Effect: Hashable, Sendable, Codable {
        case load(Load)
        /// The language model for what was meant.
        case loadModel
        /// The live recognizer, loaded and warmed if it is not.
        case prepareLive
        /// The ears' idle span stops, or begins.
        case keepEars, restEars
        /// The language model's.
        case keepModel, restModel
        /// The quick ear and the one behind it.
        case unloadEars
        case unloadBehind
        case unloadLive
        case releaseModel
    }

    static func transition(from state: State, on event: Event) -> Step {
        var next = state
        var effects: [Effect] = []

        // The ear behind goes with the language model: it is a gigabyte or
        // more, and the quick ear still hears. The model's idle span is left
        // to run: it finds nothing to do.
        func letModelGo() {
            next.modelPressed = false
            if next.loading == nil { effects.append(.unloadBehind) }
            effects.append(.releaseModel)
        }
        // Critical: the live recognizer too. The next draft hears with
        // Apple's while it warms again.
        func letGo() {
            next.pressed = false
            effects.append(.keepEars)
            if next.loading == nil { effects += [.unloadEars, .unloadLive] }
        }

        switch event {
        case .opened:
            next.draft = true
            effects += [.keepEars, .keepModel, .prepareLive]
            // A load already on its way starts the models when it is done.
            if state.loading == nil {
                next.loading = .draft
                effects.append(.load(.draft))
            }
        case .closed:
            next.draft = false
            effects.append(.restModel)
            if state.modelPressed { letModelGo() }
            if state.pressed { letGo() } else { effects.append(.restEars) }
        case .phraseBegan(let cold):
            next.phrases += 1
            effects.append(.keepEars)
            if cold, state.loading == nil {
                next.loading = .phrase
                effects.append(.load(.phrase))
            }
        case .phraseEnded:
            guard state.phrases > 0 else { return .invalid("a phrase ended that never began") }
            next.phrases -= 1
            guard !state.draft, next.phrases == 0 else { break }
            // As when a draft closes; the language model's span is not touched.
            if state.pressed { letGo() } else { effects.append(.restEars) }
        case .loadEnded(let loaded):
            guard let load = state.loading else { return .invalid("a load ended that never began") }
            next.loading = nil
            switch load {
            case .draft:
                // Only once the ears are in, or have failed: loaded together
                // they fight for the same disk and the same GPU.
                effects.append(.loadModel)
                // Memory ran short while it loaded and nothing is using it.
                if state.pressed, !state.draft { letGo() }
                if state.modelPressed, !state.draft { letModelGo() }
            case .phrase:
                // A draft that opened while this loaded asked for its models.
                if loaded, state.draft { effects.append(.loadModel) }
            }
        case .warning:
            if state.busy { next.modelPressed = true } else { letModelGo() }
        case .critical:
            if state.busy {
                next.pressed = true
                next.modelPressed = true
            } else {
                letGo()
                letModelGo()
            }
        }
        return next == state ? .stay(effects: effects) : .to(next, effects: effects)
    }
}

/// How long a thing nothing uses is kept before it is let go: a state
/// timeout, counted again from each `count`, and stopped by `keep`.
enum IdleSpan: Lifecycle {
    static let name = "lodestar.idle-span"

    enum Principal: Hashable, Sendable, Codable { case lodestar }

    enum State: Hashable, Sendable, Codable {
        /// In use, or let go already: nothing counts down.
        case kept
        case counting(Duration)
        /// The span ran out, and nothing has used it since.
        case over
    }

    enum Event: Hashable, Sendable, Codable {
        case keep
        case count(Duration)
        case elapsed
    }

    enum Effect: Hashable, Sendable, Codable { case letGo }

    static func transition(from state: State, on event: Event) -> Step {
        switch (state, event) {
        case (.kept, .keep): .ignore
        case (_, .keep): .to(.kept)
        // Entered again, so counted again.
        case (_, .count(let span)): .to(.counting(span))
        case (.counting, .elapsed): .to(.over, effects: [.letGo])
        case (.kept, .elapsed), (.over, .elapsed): .ignore
        }
    }

    static func timeout(in state: State) -> Timeout? {
        guard case .counting(let span) = state else { return nil }
        return .after(span, send: .elapsed)
    }
}
