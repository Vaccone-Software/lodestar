import CoreGraphics

/// The chain grammar, extracted pure. The core decides — the AppKit shell
/// executes. Every keypress maps to (state transition, [effect]) given
/// oracle answers about the world; nothing here touches AX, panels, or
/// timers, which is what makes the grammar testable.

public enum ChainKind: String, Equatable {
    case graph, breath
}

/// The outcome of a breath operation against the stores — the seam
/// between grammar (core) and world (actions).
public enum ChainStep: Equatable {
    case done(flash: String?)
    case continuing(hint: String?)
    case failed(flash: String)
}

public enum GraphResolution: Equatable {
    case leaf, deeper, miss
}

/// What the shell must do in response to a keypress, in order.
public enum EngineEffect: Equatable {
    /// Hand the event back to the system untouched.
    case passThrough
    case exitHints
    case hintBackspace
    case hintRescan
    case dismissCheat
    case toggleCheat
    case hideBars
    case showSearcher
    case showWebBar
    case showMenuSearch
    case openWindowChooser
    case claimFocused(beside: Bool)
    case enterScroll
    case scrollGuide
    case scrollExit
    case scrollDirectionDown(String)
    case scrollDirectionUp(String)
    case scrollHalfPage(down: Bool)
    case scrollTapG
    case scrollToBottom
    case scrollCancelPendingG
    case scrollCyclePane
    case flipOrientation
    case sweep
    case undoLayout
    case redoLayout
    case goBack
    case goForward
    case indexJump(Int)
    case reorder(Int)
    case moveDisplay(direction: Int, beside: Bool)
    case summonGraph(letters: [String], beside: Bool)
    case flash(String)
    case showGuide(kind: ChainKind, letters: [String], deleting: Bool, note: String?)
    case hideGuide
}

/// The world as the grammar sees it: queries about what is visible, and
/// store operations that report how they went. The shell owns the real
/// implementations; tests script them.
public protocol EngineWorld: AnyObject {
    func resolveGraph(_ letters: [String]) -> GraphResolution
    func breathGo(_ letters: [String]) -> ChainStep
    func breathBind(_ letters: [String]) -> ChainStep
    func breathDelete(_ letters: [String]) -> ChainStep
    func breathUpdateLatest() -> ChainStep
    /// Enter scroll mode; false when there is nothing to scroll.
    func enterScroll() -> Bool
    /// Enter hints on the focused window; false when there is none.
    func enterHints(sticky: Bool) -> Bool
    /// A plain letter while hints are up — the overlay narrows or fires.
    func hintType(_ letter: String, shift: Bool) -> HintStep
    var searcherVisible: Bool { get }
    var webBarVisible: Bool { get }
    var menuSearchVisible: Bool { get }
    var cheatVisible: Bool { get }
    var hasFocusedApp: Bool { get }
}

public struct EngineCore {
    public enum State: Equatable {
        case idle
        case chain(kind: ChainKind, letters: [String], deleting: Bool)
        case scroll
        case hints(sticky: Bool)
    }

    public private(set) var state: State = .idle

    /// Fixed verbs the user has turned off — a disabled key behaves as
    /// unbound: the keystroke passes to the focused app.
    public var disabledGestures: Set<String> = []

    public init() {}

    public var isIdle: Bool { state == .idle }

    // MARK: - Trigger classification (pure)

    public enum Trigger {
        case rightCommand, rawHyper
    }

    /// Device-dependent flag bit for the right command key (NX_DEVICERCMDKEYMASK).
    public static let rightCommandBit: UInt64 = 0x0010
    public static let meh: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    /// Did this event carry the trigger, and is shift held beyond it?
    ///
    /// The trigger is the raw right-command device bit, or the ⌘⌃⌥ ("meh")
    /// form a hyper shim produces. Shift always carries meaning — a shim
    /// must be configured to exclude shift from its output.
    public static func classify(_ flags: CGEventFlags, trigger: Trigger) -> (held: Bool, shift: Bool) {
        let shift = flags.contains(.maskShift)
        switch trigger {
        case .rightCommand:
            let rawRight = flags.contains(.maskCommand) && (flags.rawValue & rightCommandBit) != 0
            return (rawRight || flags.contains(meh), shift)
        case .rawHyper:
            return (flags.contains(meh) && shift, false)
        }
    }

    /// Shift for a mid-chain letter: lode may or may not still be held.
    public static func chainShift(_ flags: CGEventFlags, trigger: Trigger) -> Bool {
        let (held, shift) = classify(flags, trigger: trigger)
        if held { return shift }
        return flags.contains(.maskShift)
    }

    // MARK: - Key events

    /// A key release. Only scroll mode cares: direction key-ups whose
    /// key-downs were swallowed are swallowed too.
    public mutating func keyUp(key: String) -> [EngineEffect] {
        if case .scroll = state, ["j", "k", "h", "l"].contains(key) {
            return [.scrollDirectionUp(key)]
        }
        return [.passThrough]
    }

    public mutating func keyDown(key: String, held: Bool, shift: Bool, world: EngineWorld) -> [EngineEffect] {
        switch state {
        case .idle:
            // Escape closes a visible cheat sheet, lode or not — the
            // press was aimed at the help, so it never reaches the app.
            if key == "escape", world.cheatVisible {
                return [.dismissCheat]
            }
            guard held else { return [.passThrough] }
            return idlePress(key: key, shift: shift, world: world)
        case .chain(let kind, let letters, let deleting):
            return chainPress(kind: kind, letters: letters, deleting: deleting,
                              key: key, shift: shift, world: world)
        case .scroll:
            return scrollPress(key: key, held: held, shift: shift, world: world)
        case .hints(let sticky):
            return hintsPress(key: key, held: held, shift: shift, sticky: sticky, world: world)
        }
    }

    // MARK: - Idle

    private mutating func idlePress(key: String, shift: Bool, world: EngineWorld) -> [EngineEffect] {
        var effects: [EngineEffect] = []
        if world.cheatVisible && !(key == "/" && shift) {
            effects.append(.dismissCheat)
        }
        if disabledGestures.contains(key) {
            effects.append(.passThrough)
            return effects
        }
        switch key {
        case "/" where shift:
            // ? exactly — plain / is reserved for a future verb.
            effects.append(.toggleCheat)
        case "space":
            let wasVisible = world.searcherVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showSearcher) }
        case "return":
            let wasVisible = world.webBarVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showWebBar) }
        case ".":
            let wasVisible = world.menuSearchVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showMenuSearch) }
        case ";":
            effects.append(.hideBars)
            if world.enterHints(sticky: shift) {
                state = .hints(sticky: shift)
            } else {
                effects.append(.flash("✕ no focused window to hint"))
            }
        case ",":
            effects.append(.hideBars)
            if world.enterScroll() {
                state = .scroll
                effects.append(contentsOf: [.enterScroll, .scrollGuide])
            } else {
                effects.append(.flash("✕ no focused window to scroll"))
            }
        case "tab":
            if world.searcherVisible { break } // the searcher owns its tab
            effects.append(world.hasFocusedApp ? .openWindowChooser : .flash("✕ no focused window"))
        case "=":
            // A window Lodestar did not summon is left alone until the user
            // says "this one" — then it gets the full summon treatment.
            // ⇧ joins beside instead.
            effects.append(world.hasFocusedApp ? .claimFocused(beside: shift) : .flash("✕ no focused window to claim"))
        case "o":
            effects.append(.flipOrientation)
        case "z":
            effects.append(shift ? .redoLayout : .undoLayout)
        case "x":
            effects.append(shift ? .goForward : .goBack)
        case "[":
            effects.append(.moveDisplay(direction: -1, beside: shift))
        case "]":
            effects.append(.moveDisplay(direction: 1, beside: shift))
        case "'":
            state = .chain(kind: .breath, letters: [], deleting: false)
            effects.append(.showGuide(kind: .breath, letters: [], deleting: false, note: nil))
        case "0":
            effects.append(.sweep)
        case _ where Self.isDigit(key):
            if let digit = Int(key), digit >= 1 {
                effects.append(shift ? .reorder(digit) : .indexJump(digit))
            }
        case _ where Self.isLetter(key):
            graphStep(letters: [key], shift: shift, firstLetter: true, world: world, into: &effects)
        default:
            effects.append(.passThrough)
        }
        return effects
    }

    // MARK: - Chains

    private mutating func chainPress(kind: ChainKind, letters: [String], deleting: Bool,
                                     key: String, shift: Bool, world: EngineWorld) -> [EngineEffect] {
        var effects: [EngineEffect] = []
        switch key {
        case "escape":
            state = .idle
            effects.append(.hideGuide)
        case "delete":
            if kind == .breath {
                let armed = !deleting
                state = .chain(kind: kind, letters: letters, deleting: armed)
                effects.append(.showGuide(kind: kind, letters: letters, deleting: armed, note: nil))
            }
            // Graph chains have nothing to delete — swallowed.
        case "'" where kind == .breath && letters.isEmpty && !deleting:
            // ' ' — the double-tap, update the latest breath.
            react(world.breathUpdateLatest(), kind: kind, letters: letters, deleting: false, into: &effects)
        case _ where Self.isLetter(key):
            switch kind {
            case .graph:
                graphStep(letters: letters + [key], shift: shift, firstLetter: false,
                          world: world, into: &effects)
            case .breath:
                if deleting {
                    reactDeleting(world.breathDelete(letters + [key]), kind: kind,
                                  letters: letters, key: key, into: &effects)
                } else if shift {
                    react(world.breathBind(letters + [key]), kind: kind,
                          letters: letters, deleting: false, into: &effects)
                } else {
                    react(world.breathGo(letters + [key]), kind: kind,
                          letters: letters + [key], deleting: false, into: &effects)
                }
            }
        default:
            // The chain is deliberate: only a completion or Escape ends it.
            // Anything else is swallowed so half-finished chains never leak
            // keystrokes into the focused app.
            break
        }
        return effects
    }

    private mutating func graphStep(letters: [String], shift: Bool, firstLetter: Bool,
                                    world: EngineWorld, into effects: inout [EngineEffect]) {
        switch world.resolveGraph(letters) {
        case .leaf:
            state = .idle
            effects.append(contentsOf: [.hideGuide, .summonGraph(letters: letters, beside: shift)])
        case .deeper:
            state = .chain(kind: .graph, letters: letters, deleting: false)
            effects.append(.showGuide(kind: .graph, letters: letters, deleting: false, note: nil))
        case .miss:
            if firstLetter {
                // A complete failed gesture, not an abandoned traversal —
                // do not trap the user in a mode over a stray lode+letter.
                state = .idle
                effects.append(contentsOf: [.hideGuide, .flash("✕ \(Self.display(letters)) is not on the graph")])
            } else {
                // A typo mid-traversal: stay put, show the way out.
                let valid = Array(letters.dropLast())
                state = .chain(kind: .graph, letters: valid, deleting: false)
                effects.append(.showGuide(kind: .graph, letters: valid, deleting: false,
                                          note: "✕ \(Self.display(letters)) is not on the graph"))
            }
        }
    }

    private mutating func react(_ result: ChainStep, kind: ChainKind, letters: [String],
                                deleting: Bool, into effects: inout [EngineEffect]) {
        switch result {
        case .done(let flash):
            state = .idle
            effects.append(.hideGuide)
            if let flash { effects.append(.flash(flash)) }
        case .failed(let flash):
            // Stay in the chain: a refused bind or a dead-end path is
            // information, not an exit.
            state = .chain(kind: kind, letters: letters, deleting: deleting)
            effects.append(.showGuide(kind: kind, letters: letters, deleting: deleting, note: flash))
        case .continuing(let hint):
            state = .chain(kind: kind, letters: letters, deleting: false)
            effects.append(.showGuide(kind: kind, letters: letters, deleting: false, note: hint))
        }
    }

    /// While armed for deletion: a miss keeps the valid prefix, exact match
    /// deleted and finished, a prefix keeps collecting (still armed).
    private mutating func reactDeleting(_ result: ChainStep, kind: ChainKind, letters: [String],
                                        key: String, into effects: inout [EngineEffect]) {
        switch result {
        case .done(let flash):
            state = .idle
            effects.append(.hideGuide)
            if let flash { effects.append(.flash(flash)) }
        case .failed(let flash):
            state = .chain(kind: kind, letters: letters, deleting: true)
            effects.append(.showGuide(kind: kind, letters: letters, deleting: true, note: flash))
        case .continuing:
            state = .chain(kind: kind, letters: letters + [key], deleting: true)
            effects.append(.showGuide(kind: kind, letters: letters + [key], deleting: true, note: nil))
        }
    }

    // MARK: - Scroll

    /// Scroll is a lens, not a transaction: its own keys act, Escape or
    /// lode+J closes it, and any other lode verb exits and executes.
    private mutating func scrollPress(key: String, held: Bool, shift: Bool,
                                      world: EngineWorld) -> [EngineEffect] {
        if held {
            state = .idle
            var effects: [EngineEffect] = [.scrollExit, .hideGuide]
            if key != "j" && key != "escape" {
                effects.append(contentsOf: idlePress(key: key, shift: shift, world: world))
            }
            return effects
        }
        var effects: [EngineEffect] = []
        if key != "g" { effects.append(.scrollCancelPendingG) }
        switch key {
        case "escape":
            state = .idle
            effects.append(contentsOf: [.scrollExit, .hideGuide])
        case "j", "k", "h", "l":
            effects.append(.scrollDirectionDown(key))
        case "d":
            effects.append(.scrollHalfPage(down: true))
        case "u":
            effects.append(.scrollHalfPage(down: false))
        case "g":
            if shift {
                effects.append(contentsOf: [.scrollCancelPendingG, .scrollToBottom])
            } else {
                effects.append(.scrollTapG)
            }
        case "tab":
            effects.append(contentsOf: [.scrollCyclePane, .scrollGuide])
        default:
            break // swallowed — mode discipline
        }
        return effects
    }

    // MARK: - Hints

    /// Hints are a lens like scroll: its own keys act, Escape (or lode ;
    /// again) closes it, any other lode verb exits and executes. Plain
    /// typing belongs to the labels; everything unlabeled is swallowed.
    private mutating func hintsPress(key: String, held: Bool, shift: Bool,
                                     sticky: Bool, world: EngineWorld) -> [EngineEffect] {
        if held {
            state = .idle
            var effects: [EngineEffect] = [.exitHints]
            if key != ";" && key != "escape" {
                effects.append(contentsOf: idlePress(key: key, shift: shift, world: world))
            }
            return effects
        }
        switch key {
        case "escape":
            state = .idle
            return [.exitHints]
        case "delete":
            return [.hintBackspace]
        case _ where Self.isLetter(key):
            switch world.hintType(key, shift: shift) {
            case .fired where sticky:
                return [.hintRescan]
            case .fired:
                state = .idle
                return [.exitHints]
            case .pending, .ignored:
                return []
            }
        default:
            return [] // swallowed — mode discipline
        }
    }

    // MARK: - Small helpers

    static func isLetter(_ name: String) -> Bool {
        name.count == 1 && name.first!.isLetter
    }

    static func isDigit(_ name: String) -> Bool {
        name.count == 1 && name.first!.isNumber
    }

    static func display(_ letters: [String]) -> String {
        letters.map { $0.uppercased() }.joined(separator: " ")
    }
}
