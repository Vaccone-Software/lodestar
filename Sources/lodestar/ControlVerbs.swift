import AppKit
import LodestarCore

/// Verbs, executed against the running world.
///
/// The parsing is in `LodestarCore.ControlParse`, decided without a world;
/// this is the half that has one. Every path here ends in the same call a
/// keypress would make, deliberately — a scripted summon and a typed summon
/// must be the same event, or the two drift and the log stops meaning one
/// thing. What arrives through the socket is recorded as `.other`, which is
/// what keeps the graph's own numbers honest about what a hand did.
struct ControlVerbs {
    let actions: Actions
    let appIndex: AppIndex
    let model: WindowModel
    let layout: LayoutController
    let parking: ParkingLot
    /// Read per call, never captured: a verb must answer to the config as
    /// it is now, not as it was when the socket opened.
    let config: () -> Config
    let mostRecentProfile: () -> BrowserProfile?
    let presenting: () -> Bool

    func run(_ arguments: [String]) -> [String: Any] {
        switch ControlParse.parse(arguments) {
        case .failure(let problem):
            return ["ok": false, "error": problem.message]
        case .success(let verb):
            return perform(verb)
        }
    }

    private func perform(_ verb: ControlVerb) -> [String: Any] {
        switch verb {
        case .go(let query, let beside):
            return go(query: query, beside: beside)
        case .web(let url, let profile):
            return openWeb(url: url, profileKey: profile)
        case .layout(let which):
            return runLayout(which)
        case .breath(let which):
            return runBreath(which)
        case .state:
            return ["ok": true, "result": worldState()]
        }
    }

    // MARK: - go

    /// A chain first, an app name second.
    ///
    /// The order matters and only one way round is defensible: a chain is an
    /// address you chose, and an app name is a guess at one. `go m` must
    /// mean the letter you bound even on a machine with an app called "M".
    /// The reverse would let installing something rename your addresses.
    private func go(query: [String], beside: Bool) -> [String: Any] {
        if let letters = ControlParse.address(query) {
            switch config().graph.resolve(letters) {
            case .leaf(let target):
                actions.summon(target, beside: beside, via: .other)
                return ["ok": true, "message": "→ \(target.label)",
                        "result": ["kind": "chain", "target": target.label]]
            case .deeper(let node):
                // Not an error worth guessing past — say what lives there.
                let next = node.children.keys.sorted().joined(separator: " ")
                return ["ok": false,
                        "error": "'\(letters.joined())' is a branch, not a destination"
                            + (next.isEmpty ? "" : " — try one of: \(next)")]
            case .miss:
                break // an app name, then
            }
        }
        let name = query.joined(separator: " ")
        guard let entry = appIndex.entry(named: name) else {
            return ["ok": false, "error": "no chain or app matches '\(name)'"]
        }
        actions.summon(.app(entry.name), beside: beside, via: .other)
        return ["ok": true, "message": "→ \(entry.name)",
                "result": ["kind": "app", "target": entry.name]]
    }

    // MARK: - web

    private func openWeb(url: String, profileKey: String?) -> [String: Any] {
        let target = WebRouting.normalize(url)
        let profile: BrowserProfile
        let decider: String
        if let profileKey {
            guard let named = config().browserProfiles[profileKey.lowercased()] else {
                let known = config().browserProfiles.keys.sorted().joined(separator: ", ")
                return ["ok": false, "error": "no profile '\(profileKey)'"
                    + (known.isEmpty ? "" : " — known: \(known)")]
            }
            profile = named
            decider = "asked"
        } else {
            // The same chain the bar and a clicked link answer to, so one
            // url lands in one place however it was asked for.
            let context = WebContext(config: config(), mostRecent: mostRecentProfile())
            let resolved = context.resolve(pinned: nil, routedOn: target)
            // Never nil by construction: the chain ends in "any profile at
            // all", because a destination must always have somewhere to go.
            profile = resolved.profile
            decider = resolved.source.label
        }
        actions.openWeb(url: target, profile: profile, beside: false, row: "control")
        return ["ok": true, "message": "→ \(profile.browser.label) · \(profile.display)",
                "result": ["profile": profile.reference, "decider": decider]]
    }

    // MARK: - layout

    private func runLayout(_ which: LayoutVerb) -> [String: Any] {
        let did: String
        switch which {
        case .undo:
            actions.undoLayout(); did = "undo"
        case .redo:
            actions.redoLayout(); did = "redo"
        case .flip:
            actions.flipOrientation(); did = "flip"
        case .fill(let beside):
            actions.maximizeFocused(beside: beside); did = beside ? "fill beside" : "fill"
        case .index(let digit):
            actions.indexJump(digit); did = "index \(digit)"
        }
        // A sentence for a person and the whole layout for a script, which
        // is the same split every verb here makes. Without the sentence,
        // `lodestar layout undo` answers a human with a page of JSON.
        return ["ok": true, "message": "✓ \(did)", "result": worldState()]
    }

    // MARK: - breaths

    /// Breaths answer in `ChainStep`, the same value the chain grammar
    /// reads, so a scripted breath and a typed one cannot diverge.
    ///
    /// Two things about that value are easy to report wrongly, and both are
    /// reported carefully here.
    ///
    /// `.done` means **accepted, and begun** — not finished. All three of
    /// these verbs hand their real work to `OffTap` on purpose, because a
    /// restore is dozens of accessibility round trips and a save is a full
    /// state write, and neither may happen on the keyboard's path. So an ok
    /// here promises that the address resolved and the work started. The
    /// wording says "begun" rather than "saved" so a script is not told a
    /// write completed that may still fail on an empty screen.
    ///
    /// `.continuing` means "keep typing", which a socket cannot do — but it
    /// does not mean the same thing for each verb, so each says its own.
    private func runBreath(_ which: BreathVerb) -> [String: Any] {
        let step: ChainStep
        let letters: [String]
        let begun: String
        let incomplete: String
        switch which {
        case .go(let chain):
            letters = chain
            step = actions.breathChain(chain)
            begun = "restoring"
            incomplete = "no breath at"
        case .save(let chain):
            letters = chain
            step = actions.bindBreath(chain)
            begun = "saving"
            incomplete = "not a complete address for"
        case .delete(let chain):
            letters = chain
            step = actions.deleteBreathStep(chain)
            begun = "deleting"
            // Delete is the one that reaches `.continuing` for a reason a
            // person would want to know: the address names a fork above
            // real breaths rather than nothing at all.
            incomplete = "a prefix of longer breath addresses, not a breath:"
        }
        let address = letters.joined().uppercased()
        switch step {
        case .done(let flash):
            return ["ok": true, "message": flash ?? "◎ \(begun) breath \(address)",
                    "result": ["address": address, "started": true]]
        case .failed(let flash):
            return ["ok": false, "error": flash]
        case .continuing:
            return ["ok": false, "error": "\(incomplete) \(address)"]
        }
    }

    // MARK: - state

    /// The world as data — including the parked half, which has never had a
    /// way to be looked at from outside a debugger.
    ///
    /// Titles are included because a script's whole reason to ask is to find
    /// one window among several. They are not logged, and this answers only
    /// over a `0600` socket to a process already running as you.
    private func worldState() -> [String: Any] {
        let active = layout.activeDisplay()
        func describe(_ id: CGWindowID) -> [String: Any]? {
            guard let window = model.window(id) else { return nil }
            return ["id": Int(window.id), "app": window.appName, "title": window.title,
                    "minimized": window.isMinimized]
        }
        let displays: [[String: Any]] = Displays.ordered().map { display in
            let members = layout.members(on: display.id).compactMap(describe)
            return ["id": Int(display.id),
                    "active": display.id == active?.id,
                    "orientation": layout.orientation(on: display.id).rawValue,
                    "members": members]
        }
        var state: [String: Any] = [
            "version": Lodestar.version,
            "displays": displays,
            "parked": parking.snapshot().keys.sorted().compactMap(describe),
            "presenting": presenting(),
        ]
        if let focused = model.focusedWindow, let described = describe(focused.id) {
            state["focused"] = described
        }
        return state
    }
}
