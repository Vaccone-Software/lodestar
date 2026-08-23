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

/// What a label does to the card it names. The label always names the card;
/// the modifier names the verb.
public enum PasteAction: Equatable {
    /// Paste as plain text — the common case, and what a bare label does.
    case plain
    /// Paste as copied: rich text, HTML, or whatever proprietary flavour the
    /// source app offered. An image has no plain form, so both are the image.
    case native
    /// Open the card's actions: save an image, pin, delete, exclude.
    case panel
}

/// What the shell must do in response to a keypress, in order.
public enum EngineEffect: Equatable {
    /// Hand the event back to the system untouched.
    case passThrough
    case exitHints
    case hintBackspace
    case hintRescan
    case exitSelect
    case selectBackspace
    case dismissCheat
    case toggleCheat
    case hideBars
    case showSearcher
    case showWebBar
    case showCommandsBar
    case openWindowChooser
    case maximizeFocused(beside: Bool)
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
    case openSettings
    case flipOrientation
    case undoLayout
    case redoLayout
    case indexJump(Int)
    case reorder(Int)
    case moveDisplay(direction: Int, beside: Bool)
    case summonGraph(letters: [String], beside: Bool)
    case flash(String)
    case showGuide(kind: ChainKind, letters: [String], deleting: Bool, note: String?)
    case hideGuide
    case enterPaste
    case exitPaste
    case pasteRecent(label: String, action: PasteAction)
    case pastePinned(slot: Int, action: PasteAction)
    case pasteSearchBegin
    case pasteSearchEnd
    case pasteSearchType(String)
    case pasteSearchDelete(SearchDeletion)
    case pasteSearchMove(delta: Int)
    case pasteSearchCommit(action: PasteAction)
    case pastePanelShow
    case pastePanelDismiss
    case pastePanelAct(PanelAction)
}

public extension EngineEffect {
    /// Does running this effect take the shared glass panel away from
    /// whatever was on it?
    ///
    /// The coach's chip is the only thing that lives on that panel long
    /// enough to be stolen from, and being stolen from is correct — a
    /// chain guide is pending state the hand is waiting on, an offer is a
    /// suggestion that can wait. What matters is that the theft is
    /// *recorded*, because an offer is spent by being read, not by being
    /// drawn.
    ///
    /// `hideGuide` is the one that has to be here and is easiest to
    /// forget: it draws nothing, so it does not look like a claim, but
    /// `hud.hide()` orders the panel out and every completed chain emits
    /// one (`graphStep`, `.leaf`). Left off this list it erased the chip
    /// while the controller went on believing it stood, and the offer was
    /// billed ten seconds later to a user who had seen it for a third of
    /// a second.
    var claimsSurface: Bool {
        switch self {
        case .showSearcher, .showWebBar, .showCommandsBar, .openWindowChooser,
             .enterPaste, .toggleCheat, .showGuide, .scrollGuide, .hideBars,
             .hideGuide:
            return true
        default:
            return false
        }
    }
}

/// How much of the query a backspace takes.
public enum SearchDeletion: Equatable {
    case character, word, all
}

/// The rare half of a card's life, kept off the hot path deliberately.
public enum PanelAction: Equatable {
    case pin, delete, saveImage, excludeApp
}

/// The world as the grammar sees it: queries about what is visible, and
/// store operations that report how they went. The shell owns the real
/// implementations; tests script them.
public protocol EngineWorld: AnyObject {
    func resolveGraph(_ letters: [String]) -> GraphResolution
    /// Was this address replaced by one the user accepted? The new
    /// address, shown, when so. Asked only on a miss, so it costs nothing
    /// on the path that resolves.
    func supersededBy(_ letters: [String]) -> String?
    func breathGo(_ letters: [String]) -> ChainStep
    func breathBind(_ letters: [String]) -> ChainStep
    func breathDelete(_ letters: [String]) -> ChainStep
    func breathUpdateLatest() -> ChainStep
    /// Enter scroll mode; false when there is nothing to scroll.
    func enterScroll() -> Bool
    /// Enter hints on the focused window; false when there is none.
    func enterHints(sticky: Bool) -> Bool
    /// Open the clipboard strip; false when nothing has been copied yet.
    func enterPaste() -> Bool
    /// Does a card answer to this address at this moment? Letters address
    /// the recents on show, digits the filled pin slots. Asked before ⌘ is
    /// treated as addressing the strip rather than the app underneath.
    func pasteCardExists(address: String) -> Bool
    /// A plain letter while hints are up — the overlay narrows or fires.
    /// Shift fires a pick; control, held with it, right-clicks instead —
    /// the system's own word for a secondary click. Which button is a
    /// variant of the fire, carried by the keystroke that completes it:
    /// on a two-letter label, the last key decides.
    func hintType(_ letter: String, shift: Bool, control: Bool) -> HintStep
    /// Enter select on the focused window; false when there is none.
    func enterSelect() -> Bool
    /// A key while select is up — search, label, anchor, or finish.
    func selectKey(_ key: String, shift: Bool) -> SelectStep
    /// ⌘C while select is up: take what is anchored so far. `.done` when
    /// something was copied and the mode is over, `.pending` when there
    /// was nothing anchored yet to take.
    func selectCopy() -> SelectStep
    var searcherVisible: Bool { get }
    var webBarVisible: Bool { get }
    var commandsBarVisible: Bool { get }
    var cheatVisible: Bool { get }
    var hasFocusedApp: Bool { get }
}

public struct EngineCore {
    public enum State: Equatable {
        case idle
        case chain(kind: ChainKind, letters: [String], deleting: Bool)
        case scroll
        case hints(sticky: Bool)
        case select
        case paste(searching: Bool)
        /// A card's actions are open; the shell remembers which card. The
        /// flag carries where to return — closing a panel opened mid-search
        /// must not silently drop you out of the search.
        case pastePanel(searching: Bool)
    }

    /// The shell found no card behind the label ⌘ named. Without this the
    /// panel state would stick with nothing drawn in it — a dead end whose
    /// only exit is escape.
    public mutating func dismissPastePanel() {
        if case .pastePanel(let searching) = state { state = .paste(searching: searching) }
    }

    /// ⇧⌘V, from the shell — the one trigger that lives outside the lode
    /// namespace, because pasting happens inside a stream of typing rather
    /// than between them.
    public mutating func openPaste(world: EngineWorld) -> [EngineEffect] {
        switch state {
        case .paste, .pastePanel:
            // The toggle closes the strip from either level — a card's
            // panel is still the strip, and re-entering from under it
            // would silently reset the search the panel rode in on.
            state = .idle
            return [.exitPaste]
        default:
            break
        }
        guard world.enterPaste() else { return [.flash("⌂ nothing copied yet")] }
        state = .paste(searching: false)
        return [.hideBars, .enterPaste]
    }

    /// Something outside the keyboard ended the mode — a click landed
    /// elsewhere, so the strip is no longer what the user is looking at.
    /// Nothing to interpret, nothing to pass on.
    public mutating func leavePaste() -> [EngineEffect] {
        switch state {
        case .paste, .pastePanel:
            state = .idle
            return [.pastePanelDismiss, .exitPaste]
        default:
            return []
        }
    }

    public private(set) var state: State = .idle

    /// Fixed verbs the user has turned off — a disabled key behaves as
    /// unbound: the keystroke passes to the focused app.
    public var disabledGestures: Set<String> = []

    public init() {}

    public var isIdle: Bool { state == .idle }

    /// Abandon whatever is in flight and return to idle, naming the
    /// surfaces that have to come down with it.
    ///
    /// Chains are sticky on purpose — they wait for a letter for as long
    /// as it takes — which is right while the engine is hearing every key,
    /// and wrong the moment it stops. A tap that macOS disabled dropped
    /// the letters that would have completed the chain, so without this
    /// the engine waits forever and swallows everything after it.
    public mutating func reset() -> [EngineEffect] {
        var effects: [EngineEffect] = []
        switch state {
        case .idle: return []
        case .chain: effects = [.hideGuide]
        case .scroll: effects = [.scrollExit, .hideGuide]
        case .hints: effects = [.exitHints]
        case .select: effects = [.exitSelect]
        case .paste, .pastePanel: effects = [.exitPaste]
        }
        state = .idle
        return effects
    }

    // MARK: - Trigger classification (pure)

    public enum Trigger {
        case rightCommand, leftCommand
    }

    /// Device-dependent flag bits for the two command keys
    /// (NX_DEVICERCMDKEYMASK / NX_DEVICELCMDKEYMASK).
    public static let rightCommandBit: UInt64 = 0x0010
    public static let leftCommandBit: UInt64 = 0x0008
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
        case .leftCommand:
            let rawLeft = flags.contains(.maskCommand) && (flags.rawValue & leftCommandBit) != 0
            return (rawLeft || flags.contains(meh), shift)
        }
    }

    /// Shift for a mid-chain letter. Whether lode is still held changes
    /// nothing — classify reads shift straight off the event's flags
    /// either way, so this is that one read, named for the call site.
    public static func chainShift(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskShift)
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

    /// `command` matters inside paste mode, where ⌘label opens a card's
    /// actions, and inside select, where ⌘C takes the anchored word;
    /// every other state ignores it.
    public mutating func keyDown(key: String, held: Bool, shift: Bool,
                                 command: Bool = false, option: Bool = false,
                                 control: Bool = false,
                                 world: EngineWorld) -> [EngineEffect] {
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
            return hintsPress(key: key, held: held, shift: shift, control: control,
                              sticky: sticky, world: world)
        case .select:
            return selectPress(key: key, held: held, shift: shift, command: command,
                               option: option, world: world)
        case .paste(let searching):
            return pastePress(key: key, held: held, shift: shift, command: command,
                              option: option, searching: searching, world: world)
        case .pastePanel(let searching):
            return pastePanelPress(key: key, held: held, shift: shift,
                                   searching: searching, world: world)
        }
    }

    // MARK: - Idle

    private mutating func idlePress(key: String, shift: Bool, world: EngineWorld) -> [EngineEffect] {
        var effects: [EngineEffect] = []
        if world.cheatVisible && !(key == "/" && shift) {
            effects.append(.dismissCheat)
        }
        // The cheat sheet rides select's key with shift, and help is the
        // one gesture that must survive every toggle: someone who turned
        // things off deserves the map that says so.
        if disabledGestures.contains(key), !(key == "/" && shift) {
            effects.append(.passThrough)
            return effects
        }
        switch key {
        case "/" where shift:
            // ? exactly — plain / toggles nothing; it enters select below.
            effects.append(.toggleCheat)
        case "/":
            effects.append(.hideBars)
            if world.enterSelect() {
                state = .select
            } else {
                effects.append(.flash("✕ no focused window to select in"))
            }
        case "space":
            let wasVisible = world.searcherVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showSearcher) }
        case "return":
            let wasVisible = world.webBarVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showWebBar) }
        case ".":
            let wasVisible = world.commandsBarVisible
            effects.append(.hideBars)
            if !wasVisible { effects.append(.showCommandsBar) }
        case ";":
            effects.append(.hideBars)
            if world.enterHints(sticky: shift) {
                state = .hints(sticky: shift)
            } else {
                effects.append(.flash("✕ no focused window to hint"))
            }
        case ",":
            // The comma waited from 0.20 for this: settings, as ⌘, means
            // it everywhere else on the Mac.
            effects.append(contentsOf: [.hideBars, .openSettings])
        case "`":
            // Scroll's door moved off , in 0.20: the corner key is found
            // blind by the idle left hand while the right thumb holds lode,
            // and the comma is freed to mean settings, as ⌘, does.
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
        case "\\":
            // The key wearing the vertical bar flips the layout — moved
            // off O so the letter can go back to being an address.
            effects.append(.flipOrientation)
        case "left":
            effects.append(.undoLayout)
        case "right":
            effects.append(.redoLayout)
        case "[":
            effects.append(.moveDisplay(direction: -1, beside: shift))
        case "]":
            effects.append(.moveDisplay(direction: 1, beside: shift))
        case "'":
            state = .chain(kind: .breath, letters: [], deleting: false)
            effects.append(.showGuide(kind: .breath, letters: [], deleting: false, note: nil))
        case "0":
            // The number row reads as one sentence: 0 collapses to one
            // window, 1…9 pick among many. A window Lodestar did not summon
            // is left alone until this says "this one" — then it fills the
            // display and becomes a member, addressable like any other.
            // ⇧ joins beside instead of taking over.
            effects.append(world.hasFocusedApp
                ? .maximizeFocused(beside: shift)
                : .flash("✕ no focused window to maximize"))
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
            // An address the coach superseded is not a typo. The hand is
            // reaching for a habit it agreed to give up, so say where the
            // habit went and leave the chain — waiting inside `b` for a
            // letter that is never coming again would strand the user in
            // a mode over a gesture they were told to stop making.
            if let moved = world.supersededBy(letters) {
                state = .idle
                effects.append(contentsOf: [
                    .hideGuide,
                    .flash("⌖ lode \(Self.display(letters)) moved to lode \(moved)"),
                ])
            } else if firstLetter {
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
                                     control: Bool, sticky: Bool,
                                     world: EngineWorld) -> [EngineEffect] {
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
        default:
            // Every typable key feeds the mode — the pixel door aims by
            // typing what the screen says, and a URL or a count needs its
            // digits and symbols. Unmappable keys die quietly inside.
            switch world.hintType(key, shift: shift, control: control) {
            case .fired where sticky:
                return [.hintRescan]
            case .fired, .firedFocus:
                // firedFocus ends the mode even in sticky: the fire put
                // focus in a text input, and what the hands type next
                // belongs in it, not in the aim.
                state = .idle
                return [.exitHints]
            case .pending, .ignored:
                return []
            }
        }
    }

    /// Select is a lens like hints: every key is its own — typed text must
    /// never reach the app underneath — Escape closes it, any other lode
    /// verb exits and executes. Lowercase searches, capitals pick; the
    /// controller reports when a selection landed and the mode ends.
    ///
    /// Plain ⌘C is the one modifier the mode answers to: it takes the word
    /// already anchored, so a single word costs one pick instead of two.
    /// Lode is a command key itself, so the gesture is only ever the other
    /// one — `held` has already claimed the lode half above.
    private mutating func selectPress(key: String, held: Bool, shift: Bool,
                                      command: Bool, option: Bool,
                                      world: EngineWorld) -> [EngineEffect] {
        if held {
            state = .idle
            var effects: [EngineEffect] = [.exitSelect]
            if key != "/" && key != "escape" {
                effects.append(contentsOf: idlePress(key: key, shift: shift, world: world))
            }
            return effects
        }
        switch key {
        case "escape":
            state = .idle
            return [.exitSelect]
        case "delete":
            return [.selectBackspace]
        case "c" where command && !shift && !option:
            switch world.selectCopy() {
            case .done:
                state = .idle
                return [.exitSelect]
            case .pending:
                return []
            }
        default:
            switch world.selectKey(key, shift: shift) {
            case .done:
                state = .idle
                return [.exitSelect]
            case .pending:
                return []
            }
        }
    }

    // MARK: - Paste

    /// The clipboard strip. A mode, not a hold: the cards on screen are what
    /// make it unforgettable, and paging or searching needs both hands free.
    /// Its own keys act; escape leaves; any lode verb exits and executes,
    /// the same bargain scroll and hints already make.
    private mutating func pastePress(key: String, held: Bool, shift: Bool, command: Bool,
                                     option: Bool, searching: Bool,
                                     world: EngineWorld) -> [EngineEffect] {
        if held {
            state = .idle
            var effects: [EngineEffect] = [.exitPaste]
            if key != "escape" {
                effects.append(contentsOf: idlePress(key: key, shift: shift, world: world))
            }
            return effects
        }

        let action: PasteAction = command ? .panel : (shift ? .native : .plain)

        if searching {
            switch key {
            case "escape":
                // Back to the strip, not out of the mode — one escape per
                // thing you opened.
                state = .paste(searching: false)
                return [.pasteSearchEnd]
            case "return":
                // ⌘↵ acts on the selected match without leaving: opening a
                // panel and closing the mode in the same breath showed
                // nothing at all.
                if action == .panel {
                    state = .pastePanel(searching: true)
                    return [.pasteSearchCommit(action: .panel), .pastePanelShow]
                }
                state = .idle
                return [.pasteSearchCommit(action: action), .exitPaste]
            case "delete":
                // The editing shortcuts every macOS field has: ⌘⌫ clears
                // the line, ⌥⌫ takes the last word.
                if command { return [.pasteSearchDelete(.all)] }
                if option { return [.pasteSearchDelete(.word)] }
                return [.pasteSearchDelete(.character)]
            case "left":
                return [.pasteSearchMove(delta: -1)]
            case "right":
                return [.pasteSearchMove(delta: 1)]
            case "space":
                return [.pasteSearchType(" ")]
            case _ where Self.isLetter(key) || Self.isDigit(key):
                // ⌘ makes it the app's shortcut rather than a character, and
                // reaching for one means this search is over. ⌘⌫ and ⌘↵ are
                // handled above, being about the search itself.
                if command {
                    state = .idle
                    return [.exitPaste]
                }
                return [.pasteSearchType(shift ? key.uppercased() : key)]
            default:
                return [] // swallowed — mode discipline
            }
        }

        // ⌘ addressing a card opens its actions; ⌘ anything else says the
        // strip is no longer what you are working in, so it goes away.
        //
        // The keystroke is swallowed rather than passed on. It was aimed at
        // an app that had a clipboard strip over it, and the cost of being
        // wrong is asymmetric: a swallowed ⌘W is a keystroke to repeat, a
        // forwarded one closes a window the user was only trying to get
        // back to.
        if command, !world.pasteCardExists(address: key) {
            state = .idle
            return [.exitPaste]
        }

        switch key {
        case "escape":
            state = .idle
            return [.exitPaste]
        case "/":
            state = .paste(searching: true)
            return [.pasteSearchBegin]
        case _ where Self.isDigit(key):
            // Digits address the pinned column; the slots are few and fixed.
            // With ⌘, an unfilled slot has already left the mode above.
            guard let slot = Int(key), slot >= 1, slot <= Clipboard.pinSlots else {
                return []
            }
            if action == .panel {
                state = .pastePanel(searching: searching)
                return [.pastePinned(slot: slot, action: .panel), .pastePanelShow]
            }
            state = .idle
            return [.pastePinned(slot: slot, action: action), .exitPaste]
        case _ where Self.isLetter(key):
            // A letter outside the alphabet is not a label, and with ⌘ it
            // has already left the mode above.
            guard Clipboard.recentLabels.contains(key) else {
                return []
            }
            if action == .panel {
                state = .pastePanel(searching: searching)
                return [.pasteRecent(label: key, action: .panel), .pastePanelShow]
            }
            state = .idle
            return [.pasteRecent(label: key, action: action), .exitPaste]
        default:
            return [] // swallowed — mode discipline
        }
    }

    /// One keypress per action, and escape steps back to the strip rather
    /// than out of the mode — one escape per thing you opened.
    private mutating func pastePanelPress(key: String, held: Bool, shift: Bool,
                                          searching: Bool,
                                          world: EngineWorld) -> [EngineEffect] {
        if held {
            state = .idle
            var effects: [EngineEffect] = [.pastePanelDismiss, .exitPaste]
            if key != "escape" {
                effects.append(contentsOf: idlePress(key: key, shift: shift, world: world))
            }
            return effects
        }
        let action: PanelAction?
        switch key {
        case "escape":
            state = .paste(searching: searching)
            return [.pastePanelDismiss]
        case "p": action = .pin
        case "d": action = .delete
        case "s": action = .saveImage
        case "x": action = .excludeApp
        default: return []
        }
        state = .paste(searching: searching)
        return [.pastePanelAct(action!), .pastePanelDismiss]
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
