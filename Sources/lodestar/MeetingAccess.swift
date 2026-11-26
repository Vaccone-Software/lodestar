import Stoic

/// Config's intent met with the machine's authorization: whether meetings
/// run, and what is asked or said on the way there. Declared once (Stoic
/// design/27) and run live by `MeetingController`, which says what it sees
/// each time either may have changed and does what a step owes.
///
/// Level-triggered: seeing the same thing again owes only the watch for a
/// grant, which is one however often it is asked for.
enum MeetingAccess: Lifecycle {
    static let name = "lodestar.meetings"

    /// Nothing is recorded: the machine is live, and only this app steps it.
    enum Principal: Hashable, Sendable, Codable { case lodestar }

    struct State: Hashable, Sendable, Codable {
        enum Phase: String, Hashable, Sendable, Codable {
            /// Meetings are switched off.
            case off
            /// On, and calendar access not yet asked.
            case undecided
            /// On, and access denied.
            case refused
            /// On and allowed: the calendar is read and the chip offered.
            case open
        }

        var phase = Phase.off
        /// The prime card was shown since meetings were switched on. Someone
        /// who turns the feature back on is asking the question again and
        /// deserves the card again, this boot included.
        var primed = false
        /// A denied grant is reported once, not every reconcile: until
        /// access is had again.
        var told = false
    }

    /// What was seen: config's intent, then the machine's authorization.
    enum Event: String, Hashable, Sendable, Codable, CaseIterable {
        case switchedOff, undecided, refused, granted
    }

    enum Effect: String, Hashable, Sendable, Codable {
        case start, stop
        /// Watch for the grant to land.
        case watch
        /// The card that asks before macOS does.
        case prime
        /// Say that access is denied, and where to allow it.
        case tell
    }

    static func transition(from state: State, on event: Event) -> Step {
        var next = state
        var effects: [Effect] = []
        switch event {
        case .switchedOff:
            next.phase = .off
            next.primed = false
            if state.phase != .off { effects.append(.stop) }
        case .undecided:
            // What runs is left running: access taken back to the question
            // is asked again, not answered no.
            next.phase = .undecided
            effects.append(.watch)
            if !state.primed {
                next.primed = true
                effects.append(.prime)
            }
        case .refused:
            next.phase = .refused
            if state.phase != .refused { effects.append(.stop) }
            effects.append(.watch)
            if !state.told {
                next.told = true
                effects.append(.tell)
            }
        case .granted:
            next.phase = .open
            next.told = false
            if state.phase != .open { effects.append(.start) }
        }
        return next == state ? .stay(effects: effects) : .to(next, effects: effects)
    }
}
