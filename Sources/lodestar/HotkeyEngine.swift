import AppKit
import CoreGraphics
import LodestarCore

/// The event tap and the chain state machine.
///
/// Chains are deliberately sticky: once a traversal starts (`lode W`,
/// `lode M`, …) it waits — for as long as it takes — until a letter
/// completes it or Escape clears it. No timeout, so the gesture is identical
/// every single time; the persistent guide panel is the state made visible.
/// Holding lode alone peeks the top-level guide: the system teaches itself.
final class HotkeyEngine {
    /// Fires when a chain starts or ends — the menu bar wears the state.
    var onChainActive: ((Bool) -> Void)?
    /// Where observations land. Nil until the app wires one, so the engine
    /// works identically with nobody watching.
    var observations: ObservationStore?
    /// While a modal walkthrough is up it owns the keyboard. Returning true
    /// swallows the key: a gesture that reached the engine from under the
    /// walkthrough summoned a window behind it, and then escape closed that
    /// panel instead of the card the reader was looking at. `other` says a
    /// modifier that is not lode is down, which is how ⌘Q and ⌘Tab stay the
    /// system's while every lode gesture stops being anybody's.
    var interceptor: ((_ key: String, _ held: Bool, _ shift: Bool, _ other: Bool) -> Bool)?

    /// Chain timing, for the one measurement that says whether an address has
    /// compiled into muscle memory: the pauses inside it. The first stamp is
    /// the trigger itself, because the gap between lode and the first letter
    /// is the recall, and single letter addresses have no other gap to offer.
    private var chainStamps: [Date] = []
    private var chainLetters: [String] = []
    /// The map was up when a letter landed: a labeled "reconstruction, not
    /// recall" that the mixture model builds on. Captured before the peek
    /// tears down, because by observation time it is already gone.
    private var chainSawPeek = false
    /// An app excluded from the clipboard from inside the panel; the app
    /// delegate writes it to the config so the choice survives a restart.
    var onExcludeApp: ((String) -> Void)?

    /// The coach's two gestures. Double-tap lode = assent to the standing
    /// offer; lode ⌫ answers "not this one" only while a chip is up (the
    /// closure returns whether it acted, and only then is the key
    /// swallowed). And whenever the engine claims a surface — a chain
    /// guide, a bar, the peek — the chip yields first.
    var onLodeDoubleTap: (() -> Void)?
    var coachDelete: (() -> Bool)?
    var onSurfaceClaimed: (() -> Void)?
    private var coachTaps = LodeTapDetector()

    /// The grammar lives in LodestarCore, pure and tested; this class is
    /// the AppKit shell that feeds it keys and executes its effects.
    private var core = EngineCore()
    private var tapDetector = ModifierTapDetector()
    private var tap: CFMachPort?
    private var peekWork: DispatchWorkItem?
    private var isPeeking = false
    private var tapWatchdog: Timer?
    /// Latched so a tap we cannot revive is reported once, not every tick.
    private var tapWasDead = false

    /// The last moment the engine acted on the user's behalf; the update
    /// gate reads this to find a quiet stretch.
    private(set) var lastActivityAt = Date.distantPast

    /// Nothing in flight: no chain, no scroll, no hints, no panel, no
    /// peek, no cheat sheet — a restart right now would be invisible.
    var isQuiet: Bool {
        core.isIdle && !anyBarVisible && !isPeeking && !cheat.isVisible
    }

    var config: Config {
        didSet { applyGrammarConfig() }
    }
    private let actions: Actions
    private let hud: HUD
    private let searcher: SearcherController
    private let webBar: WebBarController
    private let menuSearch: MenuSearchController
    private let scroller: ScrollController
    private let hints: HintsController
    private let select: SelectController
    private let clipboard: ClipboardController
    private let strip = ClipboardStrip()
    private var pasteQuery: String?
    private var pasteSelection = 0
    private var panelClip: Clipboard.Clip?
    /// Live only while the strip is up; see `watchClicks`.
    private var clickMonitor: Any?
    private let badges = IndexBadges()
    private let cheat = CheatSheet()

    /// Verbose tap tracing for E2E runs.
    static var traceTap = ProcessInfo.processInfo.environment["LODESTAR_TRACE"] != nil

    init(config: Config, actions: Actions, hud: HUD, searcher: SearcherController,
         webBar: WebBarController, menuSearch: MenuSearchController,
         scroller: ScrollController, hints: HintsController,
         select: SelectController, clipboard: ClipboardController) {
        self.config = config
        self.actions = actions
        self.hud = hud
        self.searcher = searcher
        self.webBar = webBar
        self.menuSearch = menuSearch
        self.scroller = scroller
        self.hints = hints
        self.select = select
        self.clipboard = clipboard
        clipboard.onCapture = { [weak self] in self?.refreshStripIfOpen() }
        applyGrammarConfig()
    }

    private func applyGrammarConfig() {
        core.disabledGestures = config.disabledGestures
        tapDetector.bindings = config.doubleTaps
    }

    private var anyBarVisible: Bool {
        searcher.isVisible || webBar.isVisible || menuSearch.isVisible
    }

    private func hideBars() {
        searcher.hide()
        webBar.hide()
        menuSearch.hide()
    }

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<HotkeyEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }
        // Armed before the attempt, not after it: a tap that could not be
        // created at launch is exactly the case that needs to keep
        // trying, because the grant it is waiting on arrives later.
        startTapWatchdog()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("hotkeys: could not create event tap (accessibility?)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        scroller.onPanesDiscovered = { [weak self] in
            guard let self, self.core.state == .scroll else { return }
            self.showScrollGuide()
        }
        Log.info("hotkeys: tap active (trigger: \(config.trigger.rawValue), sticky chains, peek)")
        return true
    }

    /// Is the tap still listening?
    ///
    /// macOS announces the disablements it knows about, and those are
    /// handled in `handle`. It does not announce a tap killed out from
    /// under us — revoking and re-granting Accessibility does exactly
    /// that, and it is routine after a self-update swaps the bundle.
    /// Nothing checked afterwards, so Lodestar sat in the menu bar looking
    /// alive and completely inert until the user thought to relaunch it.
    private func startTapWatchdog() {
        tapWatchdog?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkTapAlive()
        }
        // The tap is what makes the app an app; keep checking through a
        // menu tracking loop or a resize, not only when the run loop idles.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        tapWatchdog = timer
    }

    private func checkTapAlive() {
        if let tap {
            if CGEvent.tapIsEnabled(tap: tap) {
                tapWasDead = false
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                Log.error("hotkeys: tap had stopped — re-enabled")
                // Keys were dropped while it was off, so anything in
                // flight is waiting on a letter that never arrived — the
                // same reason the tapDisabled branch resets.
                resetToIdle(reason: "tap revived")
                tapWasDead = false
                return
            }
            // Re-enabling did not take: the port is gone. Drop it and
            // fall through to the rebuild.
            Log.error("hotkeys: tap would not re-enable — rebuilding")
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        // No tap at all. Keep trying on every tick rather than latching:
        // the thing that takes a tap away is an accessibility revoke, and
        // the user can undo that at any moment without relaunching us —
        // which is exactly the case this watchdog exists for. Only the
        // announcement is rate-limited, never the retry.
        guard Permissions.isTrusted else {
            announceDeadTap()
            return
        }
        guard start() else {
            announceDeadTap()
            return
        }
        tapWasDead = false
        resetToIdle(reason: "tap rebuilt")
        Log.error("hotkeys: tap rebuilt after being lost")
        hud.flash("⌖ gestures restored", seconds: 3)
    }

    /// Said once per outage, not once every five seconds.
    private func announceDeadTap() {
        guard !tapWasDead else { return }
        tapWasDead = true
        Log.error("hotkeys: no event tap — gestures are inert until accessibility is granted")
        hud.flash("⚠ Lodestar lost its keyboard access — re-grant it in Privacy & Security", seconds: 10)
    }

    /// Drop any chain, peek, or mode in flight and go quiet.
    private func resetToIdle(reason: String) {
        guard !core.isIdle || isPeeking else { return }
        Log.info("hotkeys: engine reset", ["reason": reason])
        cancelPeek(hideGuide: true)
        _ = apply(core.reset(), event: nil)
        hud.hide()
        onChainActive?(false)
    }

    // MARK: - Trigger classification

    private var coreTrigger: EngineCore.Trigger {
        config.trigger == .rawHyper ? .rawHyper : .rightCommand
    }

    private func classify(_ flags: CGEventFlags) -> (held: Bool, shift: Bool) {
        EngineCore.classify(flags, trigger: coreTrigger)
    }

    private func chainShift(_ flags: CGEventFlags) -> Bool {
        EngineCore.chainShift(flags, trigger: coreTrigger)
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if Self.traceTap {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            Log.info("tap: type=\(type.rawValue) key=\(keycode) flags=\(String(event.flags.rawValue, radix: 16))")
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The tap dropped events while it was off, so a chain in
            // flight is now missing letters it will wait for forever.
            // Clearing is the honest recovery: the gesture is stateless by
            // design, and a stranded chain swallows every key that follows.
            resetToIdle(reason: type == .tapDisabledByTimeout ? "tap timed out" : "tap interrupted")
            guard let tap else { return Unmanaged.passUnretained(event) }
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("hotkeys: tap re-enabled", ["alive": CGEvent.tapIsEnabled(tap: tap)])
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            // The coach's assent gesture watches the classified lode state
            // and consumes nothing — fed first, so no other path can
            // starve it.
            let (lodeHeld, _) = classify(event.flags)
            if coachTaps.lodeChanged(held: lodeHeld,
                                     at: Date().timeIntervalSinceReferenceDate) {
                onLodeDoubleTap?()
            }
            if let verb = tapDetector.flagsChanged(event.flags, at: Date().timeIntervalSinceReferenceDate) {
                cancelPeek(hideGuide: isPeeking)
                lastActivityAt = Date()
                let press = verb.keypress
                let wasIdle = core.isIdle
                _ = dispatch(core.keyDown(key: press.key, held: true, shift: press.shift, world: self),
                          event: event)
                if wasIdle != core.isIdle { onChainActive?(!core.isIdle) }
                return Unmanaged.passUnretained(event)
            }
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            // Only scroll mode cares about releases (smooth velocity stops
            // the instant a direction key lifts). Swallow the key-ups whose
            // key-downs we swallowed; everything else passes untouched.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard let key = Keys.name(for: keycode) else { return Unmanaged.passUnretained(event) }
            return dispatch(core.keyUp(key: key), event: event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        tapDetector.keyDown()
        coachTaps.keyDown()
        if isPeeking { chainSawPeek = true }
        cancelPeek(hideGuide: isPeeking)

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = Keys.name(for: keycode) else {
            // Unmapped keys pass through untouched, even mid-chain.
            return Unmanaged.passUnretained(event)
        }
        let (held, shift) = classify(event.flags)

        if let interceptor {
            let other = event.flags.contains(.maskControl)
                || event.flags.contains(.maskAlternate)
                || (event.flags.contains(.maskCommand) && !held)
            if interceptor(key, held, shift, other) { return nil }
        }

        // lode ⌫ while a coach chip is up answers "not this one". The
        // closure acts only when a chip is visible, and the key is
        // swallowed only when it acted — idle lode ⌫ everywhere else stays
        // exactly the nothing it always was.
        if held, key == "delete", core.isIdle, coachDelete?() == true {
            return nil
        }

        // A held select highlight answers ⌘C and dissolves on anything
        // else. First line inside is a nil-check — this costs nothing on
        // the 99.99% of keystrokes with no highlight standing.
        if select.ghostHandleKey(key: key, held: held, flags: event.flags) {
            return nil
        }

        // ⇧⌘V opens the clipboard strip — but only while lode is *not* the
        // command being held. Right ⌘ is the lode trigger, so lode ⇧V has to
        // stay a beside-summon of the graph's V; the device bit is what
        // tells the two apart.
        if !held, key == "v", config.clipboardEnabled,
           event.flags.contains(.maskShift), event.flags.contains(.maskCommand) {
            lastActivityAt = Date()
            return dispatch(core.openPaste(world: self), event: event)
        }
        // Mid-chain and mid-scroll, lode may or may not still be down —
        // shift keeps its meaning either way.
        let effectiveShift = core.isIdle ? shift : chainShift(event.flags)
        // Ordinary typing is not engine activity; lode gestures and
        // anything mid-chain are.
        if held || !core.isIdle { lastActivityAt = Date() }

        let wasIdle = core.isIdle
        let effects = core.keyDown(key: key, held: held, shift: effectiveShift,
                                   command: event.flags.contains(.maskCommand),
                                   option: event.flags.contains(.maskAlternate), world: self)
        let arrived = Date()
        let verdict = dispatch(effects, event: event)
        observeChain(effects, key: key, at: arrived)
        if wasIdle != core.isIdle { onChainActive?(!core.isIdle) }
        return verdict
    }

    /// Which verb an effect belongs to, for the count that lets a feature
    /// nobody has ever touched say so. Names match the gesture roster, so the
    /// report and the config speak the same words.
    private static func verb(for effect: EngineEffect) -> String? {
        switch effect {
        case .showSearcher, .openWindowChooser: return "launcher"
        case .showWebBar: return "web"
        case .showMenuSearch: return "menu"
        case .enterPaste: return "clipboard"
        case .enterScroll: return "scroll"
        case .toggleCheat: return "cheat"
        case .summonGraph: return "graph"
        case .indexJump, .reorder: return "index"
        case .maximizeFocused: return "maximize"
        case .flipOrientation: return "orientation"
        case .undoLayout, .redoLayout: return "undo"
        case .moveDisplay: return "displays"
        default: return nil
        }
    }

    /// What the grammar's own decisions say about how well an address is
    /// known. A completion carries its pauses and whether the map was
    /// consulted, a wrong letter carries the key the hand believed in, and
    /// an escape carries how long the hand hovered first — the difference
    /// between "wrong tool" and "couldn't recall".
    private func observeChain(_ effects: [EngineEffect], key: String, at now: Date) {
        guard let observations else { return }
        // Decided before the walk, not during it. A completing chain emits
        // hideGuide *before* summonGraph, so a flag set as the loop went along
        // let the guide's own teardown wipe the timestamps a moment before the
        // completion asked for them: every abandon recorded, every completion
        // arrived with no timing at all.
        let completed = effects.contains {
            if case .summonGraph = $0 { return true }
            return false
        }
        for effect in effects {
            if let verb = Self.verb(for: effect) {
                observations.verbUsed(verb, at: now)
            }
            switch effect {
            case .summonGraph(let letters, _):
                chainStamps.append(now)
                // Every pause counts, including the ones where the guide
                // appeared. Excluding those was the second mistake in this
                // feature: the guide shows up after 0.45s of holding lode, so
                // "the map was open" describes almost every deliberate gesture,
                // and discarding them threw away exactly the slow addresses
                // worth finding. A chain that needed the map is a chain that
                // was not fluent — so the pause counts, and the consultation
                // itself rides along as a label.
                var gaps: [TimeInterval] = []
                for (index, stamp) in chainStamps.enumerated() where index > 0 {
                    gaps.append(stamp.timeIntervalSince(chainStamps[index - 1]))
                }
                // A canary, kept: a completion with nothing to time means the
                // trigger stamp went missing, which is how this feature was
                // silently blind twice.
                if chainStamps.count < 2 {
                    Log.info("observations", ["untimed-chain-keys": letters.count,
                                              "stamps": chainStamps.count])
                }
                observations.chainCompleted(letters, gaps: gaps, peeked: chainSawPeek, at: now)
                chainStamps = []
                chainLetters = []
                chainSawPeek = false
            case .showGuide(let kind, let letters, _, let note):
                guard kind == .graph else { continue }
                if note != nil {
                    observations.wrongKey(after: chainLetters, pressed: key, at: now)
                } else if letters.count > chainLetters.count {
                    chainStamps.append(now)
                }
                chainLetters = letters
            case .hideGuide:
                if !completed, !chainLetters.isEmpty {
                    let hover = chainStamps.last.map { now.timeIntervalSince($0) } ?? 0
                    observations.chainAbandoned(chainLetters, hover: hover, at: now)
                }
                if !completed { chainStamps = []; chainLetters = []; chainSawPeek = false }
            default:
                continue
            }
        }
    }

    /// Effects that put something on screen the coach chip would sit
    /// under; the chip yields to every one of them.
    private static func claimsSurface(_ effect: EngineEffect) -> Bool {
        switch effect {
        case .showSearcher, .showWebBar, .showMenuSearch, .openWindowChooser,
             .enterPaste, .toggleCheat, .showGuide, .scrollGuide, .hideBars:
            return true
        default:
            return false
        }
    }

    /// Whether an effect moves windows through the Accessibility API.
    ///
    /// These are the only effects whose cost is unbounded: each one walks
    /// out to `Layout.retile` → `AXMover.setFrame`, roughly ten AX round
    /// trips per layout member, and an AX call against an app that is not
    /// answering blocks for the full messaging timeout. The tap callback
    /// runs on the main run loop as a `.defaultTap`, so blocking inside it
    /// stalls keyboard delivery for *every* app until the window server
    /// gives up on us — the user's chain letters then land as literal text
    /// in whatever is in front.
    ///
    /// Everything else stays synchronous on purpose. The clipboard verbs
    /// synthesize a ⌘V through `CGEvent.post`, and ordering between a
    /// run-loop source callback and a dispatched block is not guaranteed,
    /// so deferring those could land a paste after the next keystroke.
    private static func mutatesWindows(_ effect: EngineEffect) -> Bool {
        switch effect {
        case .summonGraph, .maximizeFocused, .indexJump, .reorder,
             .moveDisplay, .flipOrientation, .undoLayout, .redoLayout:
            return true
        default:
            return false
        }
    }

    /// Whether the core asked for the event to reach the app. Derived from
    /// the effect list alone, so the verdict the tap must return never
    /// waits on the work the effects do.
    private static func passesThrough(_ effects: [EngineEffect]) -> Bool {
        effects.contains { if case .passThrough = $0 { return true } else { return false } }
    }

    /// Decide the event's fate now, do the slow part after.
    ///
    /// The verdict is the only thing the tap owes the window server, and
    /// it is knowable from the effect list without running anything. So
    /// the window-moving effects go out on the next main-queue turn and
    /// the callback returns immediately. Relative order is preserved:
    /// `core` has already advanced synchronously, so the state machine
    /// stays exact, and only the AX work lags.
    private func dispatch(_ effects: [EngineEffect], event: CGEvent?) -> Unmanaged<CGEvent>? {
        let deferred = effects.filter(Self.mutatesWindows)
        guard !deferred.isEmpty else { return apply(effects, event: event) }
        let immediate = effects.filter { !Self.mutatesWindows($0) }
        let verdict = apply(immediate, event: event)
        DispatchQueue.main.async { [weak self] in
            _ = self?.apply(deferred, event: nil)
        }
        return verdict
    }

    /// Execute the core's decisions, in order. The one routing effect:
    /// .passThrough hands the event back to the system.
    private func apply(_ effects: [EngineEffect], event: CGEvent?) -> Unmanaged<CGEvent>? {
        var pass = false
        for effect in effects {
            if Self.claimsSurface(effect) { onSurfaceClaimed?() }
            switch effect {
            case .passThrough:
                pass = true
            case .enterPaste:
                renderStrip()
            case .exitPaste:
                pasteQuery = nil
                panelClip = nil
                stopWatchingClicks()
                strip.hide()
            case .pasteRecent(let label, let action):
                actOnClip(strip.shownRecents.first { clip in
                    ClipboardStrip.labels.firstIndex(of: label)
                        .map { strip.shownRecents.indices.contains($0) && strip.shownRecents[$0].id == clip.id }
                        ?? false
                }, action: action)
            case .pastePinned(let slot, let action):
                actOnClip(strip.shownPins[slot], action: action)
            case .pasteSearchBegin:
                pasteQuery = ""
                pasteSelection = 0
                renderStrip()
            case .pasteSearchEnd:
                pasteQuery = nil
                renderStrip()
            case .pasteSearchType(let text):
                pasteQuery = (pasteQuery ?? "") + text
                pasteSelection = 0
                renderStrip()
            case .pasteSearchDelete(let scope):
                let query = pasteQuery ?? ""
                switch scope {
                case .character: pasteQuery = String(query.dropLast())
                case .word: pasteQuery = Clipboard.droppingLastWord(query)
                case .all: pasteQuery = ""
                }
                pasteSelection = 0
                renderStrip()
            case .pasteSearchMove(let delta):
                pasteSelection = max(0, min(strip.shownRecents.count - 1, pasteSelection + delta))
                renderStrip()
            case .pasteSearchCommit(let action):
                let target = strip.shownRecents.indices.contains(pasteSelection)
                    ? strip.shownRecents[pasteSelection] : nil
                actOnClip(target, action: action)
            case .pastePanelShow:
                showClipPanel()
            case .pastePanelDismiss:
                panelClip = nil
                if case .paste = core.state { renderStrip() }
            case .pastePanelAct(let panelAction):
                performPanel(panelAction)
            case .exitHints:
                hints.exit()
            case .exitSelect:
                select.exit()
            case .selectBackspace:
                select.backspace()
            case .hintBackspace:
                hints.backspace()
            case .hintRescan:
                hints.rescan()
            case .dismissCheat:
                cheat.hide()
            case .toggleCheat:
                cheat.toggle(sections: cheatSections)
            case .hideBars:
                hideBars()
            case .showSearcher:
                searcher.show()
            case .showWebBar:
                webBar.config = config
                webBar.show()
            case .showMenuSearch:
                menuSearch.show()
            case .openWindowChooser:
                if let app = actions.focusedAppInfo() {
                    searcher.showWindowChooser(pid: app.pid, appName: app.name)
                }
            case .maximizeFocused(let beside):
                actions.maximizeFocused(beside: beside)
            case .enterScroll:
                break // entry happened in the world callback; state is the record
            case .scrollGuide:
                showScrollGuide()
            case .scrollExit:
                scroller.exit()
            case .scrollDirectionDown(let key):
                scroller.directionKeyDown(key)
            case .scrollDirectionUp(let key):
                scroller.directionKeyUp(key)
            case .scrollHalfPage(let down):
                scroller.halfPage(down: down)
            case .scrollTapG:
                scroller.tapG()
            case .scrollToBottom:
                scroller.toEnd(bottom: true)
            case .scrollCancelPendingG:
                scroller.cancelPendingG()
            case .scrollCyclePane:
                scroller.cyclePane()
            case .flipOrientation:
                actions.flipOrientation()
            case .undoLayout:
                actions.undoLayout()
            case .redoLayout:
                actions.redoLayout()
            case .indexJump(let digit):
                actions.indexJump(digit)
            case .reorder(let digit):
                actions.reorderFocused(toDigit: digit)
            case .moveDisplay(let direction, let beside):
                actions.moveFocusedDisplay(direction: direction, beside: beside)
            case .summonGraph(let letters, let beside):
                if case .leaf(let target) = config.graph.resolve(letters) {
                    actions.summon(target, beside: beside)
                }
            case .flash(let text):
                hud.flash(text)
            case .showGuide(let kind, let letters, let deleting, let note):
                showGuide(kind: kind, letters: letters, deleting: deleting, note: note)
            case .hideGuide:
                hud.hide()
            }
        }
        return pass ? event.map { Unmanaged.passUnretained($0) } : nil
    }

    // MARK: - Peek (hold lode to see your world)

    private func handleFlagsChanged(_ event: CGEvent) {
        guard core.isIdle else { return }
        // A walkthrough owns the keyboard, and that includes holding lode: the
        // peek would lay the graph guide over the card being read.
        guard interceptor == nil else { return }
        let (held, _) = classify(event.flags)
        if held {
            // The clock for a chain starts when lode goes down, not when the
            // first letter arrives.
            chainStamps = [Date()]
            chainLetters = []
            chainSawPeek = false
            guard peekWork == nil, !isPeeking, !anyBarVisible else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.core.isIdle, !self.anyBarVisible else { return }
                self.isPeeking = true
                self.lastActivityAt = Date()
                self.onSurfaceClaimed?()
                self.hud.showGuide(
                    title: "⌖ graph",
                    rows: self.actions.graphGuideRows(self.config.graph),
                    footer: "letter to go · space launcher · ⏎ ask · ; hints · ' breaths · ? everything · release to dismiss"
                )
                self.badges.show(self.actions.indexBadgeItems())
            }
            peekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else {
            cancelPeek(hideGuide: isPeeking)
        }
    }

    private func cancelPeek(hideGuide: Bool) {
        peekWork?.cancel()
        peekWork = nil
        if isPeeking {
            isPeeking = false
            badges.hide()
            if hideGuide { hud.hide() }
        }
    }

    // MARK: - Idle presses

    // MARK: - Chain presses

    // MARK: - Scroll mode

    private func showScrollGuide() {
        let pane = scroller.paneDescription.map { " · \($0)" } ?? ""
        hud.showGuide(
            title: "≡ scroll · \(scroller.appName)\(pane)",
            rows: [
                GuideRow(key: "J K", label: "down · up"),
                GuideRow(key: "H L", label: "left · right"),
                GuideRow(key: "D U", label: "half-page down · up"),
                GuideRow(key: "G G", label: "top    ·    ⇧G bottom"),
                GuideRow(key: "⇥", label: "next pane"),
            ],
            footer: "other lode verbs act and exit · esc or lode J closes"
        )
    }

    // MARK: - Guide

    private func display(_ letters: [String]) -> String {
        letters.map { $0.uppercased() }.joined(separator: " ")
    }

    private func showGuide(kind: ChainKind, letters: [String], deleting: Bool, note: String?) {
        let prefix = display(letters)
        switch kind {
        case .graph:
            var rows: [GuideRow] = []
            if case .deeper(let node) = config.graph.resolve(letters) {
                rows = actions.graphGuideRows(node)
            } else if letters.isEmpty {
                rows = actions.graphGuideRows(config.graph)
            }
            hud.showGuide(title: "⌖ \(prefix.isEmpty ? "graph" : prefix)", rows: rows,
                          footer: footer(note: note, base: "esc clears"))
        case .breath:
            var rows = actions.breathGuide(prefix: letters.joined())
            if letters.isEmpty && !deleting {
                rows.insert(GuideRow(key: "'", label: "update latest breath"), at: 0)
            }
            let title = deleting ? "◎ delete breath \(prefix)" : "◎ breath \(prefix)"
            let base = deleting
                ? "type a path to delete it · ⌫ disarms · esc clears"
                : "letter restores · ⇧letter saves here · ⌫ arms delete · esc clears"
            hud.showGuide(title: title, rows: rows, footer: footer(note: note, base: base))
        }
    }

    private func footer(note: String?, base: String) -> String {
        note.map { "\($0)   ·   \(base)" } ?? base
    }

    /// Everything on one sheet, from live config and state.
    private func cheatSections() -> [CheatSheet.Section] {
        let verbs: [GuideRow] = [
            GuideRow(key: "␣", label: "launcher"),
            GuideRow(key: "⏎", label: "ask — links · domains · search"),
            GuideRow(key: ".", label: "menu search — the frontmost app's menus"),
            GuideRow(key: "⇥", label: "windows of the focused app"),
            GuideRow(key: "1…9", label: "jump to window by position"),
            GuideRow(key: "0", label: "the focused window fills the display — ⇧0 beside"),
            GuideRow(key: "\\", label: "flip layout orientation"),
            GuideRow(key: ",", label: "scroll mode — j/k · h/l · d/u · gg/G"),
            GuideRow(key: ";", label: "click hints — ⇧; chains · ⇧label right-clicks"),
            GuideRow(key: "/", label: "select text — type what you see · ⇧letter anchors"),
            GuideRow(key: "← →", label: "undo · redo the layout"),
            GuideRow(key: "⇧1…9", label: "slide the focused window to that position"),
            GuideRow(key: "[ ]", label: "move window to prev/next display — ⇧ beside"),
            GuideRow(key: "'", label: "breaths — ' ' updates latest"),
            GuideRow(key: "hold", label: "peek the graph + window indexes"),
            GuideRow(key: "?", label: "this sheet — whenever you forget"),
            GuideRow(key: "⇧⌘V", label: "clipboard — label pastes · ⇧ as copied · ⌘ actions · / search"),
            GuideRow(key: "esc", label: "clear a chain"),
        ]
        return [
            .init(header: "verbs", rows: verbs),
            .init(header: "graph", rows: actions.graphCheatRows(config.graph)),
            .init(header: "breaths", rows: actions.breathGuide(prefix: "")),
        ]
    }

    /// For the SIGUSR1 diagnostics dump.
    var stateDescription: String {
        switch core.state {
        case .idle: return "idle\(isPeeking ? "+peek" : "")"
        case .chain(let kind, let letters, let deleting):
            return "chain(\(kind), '\(letters.joined())'\(deleting ? ", deleting" : ""))"
        case .scroll:
            return "scroll"
        case .hints(let sticky):
            return "hints\(sticky ? "(sticky)" : "")"
        case .select:
            return "select"
        case .paste(let searching):
            return "paste\(searching ? "(searching)" : "")"
        case .pastePanel:
            return "paste(panel)"
        }
    }
}

// MARK: - The world, as the grammar sees it

extension HotkeyEngine: EngineWorld {
    func resolveGraph(_ letters: [String]) -> GraphResolution {
        switch config.graph.resolve(letters) {
        case .leaf: return .leaf
        case .deeper: return .deeper
        case .miss: return .miss
        }
    }

    func breathGo(_ letters: [String]) -> ChainStep { actions.breathChain(letters) }
    func breathBind(_ letters: [String]) -> ChainStep { actions.bindBreath(letters) }
    func breathDelete(_ letters: [String]) -> ChainStep { actions.deleteBreathStep(letters) }
    func breathUpdateLatest() -> ChainStep { actions.updateLatestBreath() }

    /// Something new landed on the pasteboard. If the strip is up it is a
    /// live view, so it shows the arrival immediately — copy with the cards
    /// open and the new clip is simply the first one.
    private func refreshStripIfOpen() {
        switch core.state {
        case .paste, .pastePanel: renderStrip()
        default: break
        }
    }

    /// Redraw the strip for the current query and selection. Cheap: the
    /// previews are already in memory and the thumbnails already decoded.
    private func renderStrip() {
        let all = clipboard.history.clips
        let recents = pasteQuery.map { Clipboard.search(all, query: $0) } ?? Clipboard.recents(all)
        pasteSelection = max(0, min(pasteSelection, max(0, recents.count - 1)))

        // One band, whichever of its three jobs applies right now.
        let band: ClipboardStrip.Band
        if let clip = panelClip {
            band = .actions(Self.panelActions(for: clip))
        } else if let query = pasteQuery {
            band = .search(query)
        } else {
            band = .none
        }
        strip.show(recents: recents, pins: Clipboard.pins(all),
                   thumbnail: { [clipboard] id in clipboard.history.thumbnail(for: id) },
                   band: band, selection: pasteSelection, actingOn: panelClip?.id)
    }

    /// The rare half of a card's life. The strip draws these beside the
    /// card they act on — a pin's to its right, a recent's above it — and
    /// lights that card at the same weight, so the menu and its subject
    /// read as one object rather than two.
    /// Benign first, destructive after — the strip draws the rule between
    /// them, so the order here is what puts an action on the right side of
    /// it.
    static func panelActions(for clip: Clipboard.Clip) -> [ClipboardStrip.Action] {
        var actions = [ClipboardStrip.Action(
            key: "P",
            label: clip.isPinned ? "Unpin" : "Pin",
            symbol: clip.isPinned ? "pin.slash" : "pin"
        )]
        if clip.kind == .image {
            actions.append(.init(key: "S", label: "Save to Downloads",
                                 symbol: "square.and.arrow.down"))
        }
        actions.append(.init(key: "D", label: "Delete", symbol: "trash",
                             isDestructive: true))
        if clip.sourceAppName != nil {
            actions.append(.init(key: "X", label: "Never save from this app",
                                 symbol: "hand.raised", isDestructive: true))
        }
        return actions
    }

    private func showClipPanel() {
        renderStrip()
    }

    private func performPanel(_ action: PanelAction) {
        guard let clip = panelClip else { return }
        switch action {
        case .pin: clipboard.togglePin(clip)
        case .delete: clipboard.history.delete(clip.id)
        case .saveImage: clipboard.saveImage(clip)
        case .excludeApp:
            if let bundleID = clipboard.excludeApp(of: clip) {
                onExcludeApp?(bundleID)
                clipboard.excludedApps.insert(bundleID)
            }
        }
        panelClip = nil
    }

    /// One card, one verb. A panel action leaves the strip up; a paste has
    /// already closed it by the time this runs.
    private func actOnClip(_ clip: Clipboard.Clip?, action: PasteAction) {
        guard let clip else {
            // Nothing behind that label. A paste closes the strip anyway; a
            // panel request must not strand the mode in a panel with no card.
            if action == .panel { core.dismissPastePanel() } else { strip.hide() }
            return
        }
        switch action {
        case .plain, .native:
            strip.hide()
            clipboard.paste(clip, action: action)
        case .panel:
            panelClip = clip
        }
    }

    func enterPaste() -> Bool {
        guard !clipboard.history.clips.isEmpty else { return false }
        pasteQuery = nil
        pasteSelection = 0
        panelClip = nil
        watchClicks()
        renderStrip()
        return true
    }

    func pasteCardExists(address: String) -> Bool {
        if let slot = Int(address) { return strip.shownPins[slot] != nil }
        guard let index = ClipboardStrip.labels.firstIndex(of: address) else { return false }
        return strip.shownRecents.indices.contains(index)
    }

    /// A click means the user is looking at something else now, and the
    /// strip is a thing you read — leaving it up over the window they just
    /// reached for is the one state it should never be in.
    ///
    /// Observed, never intercepted: the tap watches keys only, and the strip
    /// takes no mouse events at all, so the click lands exactly where it was
    /// aimed and the mode simply ends behind it.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Off the callback before touching the monitor: tearing it down
            // from inside its own handler is asking for trouble.
            DispatchQueue.main.async {
                guard let self else { return }
                _ = self.apply(self.core.leavePaste(), event: nil)
            }
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func enterHints(sticky: Bool) -> Bool {
        hints.letters = config.hintLetters
        hints.rescanDelay = config.hintRescanDelay
        return hints.enter(sticky: sticky)
    }

    func hintType(_ letter: String, shift: Bool) -> HintStep {
        hints.type(letter, shift: shift)
    }

    func enterSelect() -> Bool {
        select.letters = config.hintLetters
        return select.enter()
    }

    func selectKey(_ key: String, shift: Bool) -> SelectStep {
        select.key(key, shift: shift)
    }

    func enterScroll() -> Bool {
        scroller.step = config.scrollStep
        scroller.smooth = config.scrollSmooth
        scroller.speed = config.scrollSpeed
        return scroller.enter()
    }

    var searcherVisible: Bool { searcher.isVisible }
    var webBarVisible: Bool { webBar.isVisible }
    var menuSearchVisible: Bool { menuSearch.isVisible }
    var cheatVisible: Bool { cheat.isVisible }
    var hasFocusedApp: Bool { actions.focusedAppInfo() != nil }
}
