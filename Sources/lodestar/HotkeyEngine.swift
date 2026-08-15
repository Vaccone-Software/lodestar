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
    /// An app excluded from the clipboard from inside the panel; the app
    /// delegate writes it to the config so the choice survives a restart.
    var onExcludeApp: ((String) -> Void)?

    /// The grammar lives in LodestarCore, pure and tested; this class is
    /// the AppKit shell that feeds it keys and executes its effects.
    private var core = EngineCore()
    private var tapDetector = ModifierTapDetector()
    private var tap: CFMachPort?
    private var peekWork: DispatchWorkItem?
    private var isPeeking = false
    var isPaused = false

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
    private let clipboard: ClipboardController
    private let strip = ClipboardStrip()
    private var pasteQuery: String?
    private var pasteSelection = 0
    private var panelClip: Clipboard.Clip?
    private let badges = IndexBadges()
    private let cheat = CheatSheet()

    /// Verbose tap tracing for E2E runs.
    static var traceTap = ProcessInfo.processInfo.environment["LODESTAR_TRACE"] != nil

    init(config: Config, actions: Actions, hud: HUD, searcher: SearcherController,
         webBar: WebBarController, menuSearch: MenuSearchController,
         scroller: ScrollController, hints: HintsController,
         clipboard: ClipboardController) {
        self.config = config
        self.actions = actions
        self.hud = hud
        self.searcher = searcher
        self.webBar = webBar
        self.menuSearch = menuSearch
        self.scroller = scroller
        self.hints = hints
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("hotkeys: tap re-enabled")
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            if !isPaused,
               let verb = tapDetector.flagsChanged(event.flags, at: Date().timeIntervalSinceReferenceDate) {
                cancelPeek(hideGuide: isPeeking)
                lastActivityAt = Date()
                let press = verb.keypress
                let wasIdle = core.isIdle
                _ = apply(core.keyDown(key: press.key, held: true, shift: press.shift, world: self),
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
            return apply(core.keyUp(key: key), event: event)
        }
        guard type == .keyDown, !isPaused else { return Unmanaged.passUnretained(event) }

        tapDetector.keyDown()
        cancelPeek(hideGuide: isPeeking)

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = Keys.name(for: keycode) else {
            // Unmapped keys pass through untouched, even mid-chain.
            return Unmanaged.passUnretained(event)
        }
        let (held, shift) = classify(event.flags)

        // ⇧⌘V opens the clipboard strip — but only while lode is *not* the
        // command being held. Right ⌘ is the lode trigger, so lode ⇧V has to
        // stay a beside-summon of the graph's V; the device bit is what
        // tells the two apart.
        if !held, key == "v", config.clipboardEnabled,
           event.flags.contains(.maskShift), event.flags.contains(.maskCommand) {
            lastActivityAt = Date()
            return apply(core.openPaste(world: self), event: event)
        }
        // Mid-chain and mid-scroll, lode may or may not still be down —
        // shift keeps its meaning either way.
        let effectiveShift = core.isIdle ? shift : chainShift(event.flags)
        // Ordinary typing is not engine activity; lode gestures and
        // anything mid-chain are.
        if held || !core.isIdle { lastActivityAt = Date() }

        let wasIdle = core.isIdle
        let effects = core.keyDown(key: key, held: held, shift: effectiveShift,
                                   command: event.flags.contains(.maskCommand), world: self)
        let verdict = apply(effects, event: event)
        if wasIdle != core.isIdle { onChainActive?(!core.isIdle) }
        return verdict
    }

    /// Execute the core's decisions, in order. The one routing effect:
    /// .passThrough hands the event back to the system.
    private func apply(_ effects: [EngineEffect], event: CGEvent) -> Unmanaged<CGEvent>? {
        var pass = false
        for effect in effects {
            switch effect {
            case .passThrough:
                pass = true
            case .enterPaste:
                renderStrip()
            case .exitPaste:
                pasteQuery = nil
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
            case .pasteSearchBackspace:
                if let query = pasteQuery, !query.isEmpty { pasteQuery = String(query.dropLast()) }
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
                hud.hide()
                if case .paste = core.state { renderStrip() }
            case .pastePanelAct(let panelAction):
                performPanel(panelAction)
            case .exitHints:
                hints.exit()
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
            case .goBack:
                actions.goBack()
            case .goForward:
                actions.goForward()
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
        return pass ? Unmanaged.passUnretained(event) : nil
    }

    // MARK: - Peek (hold lode to see your world)

    private func handleFlagsChanged(_ event: CGEvent) {
        guard !isPaused else { return }
        guard core.isIdle else { return }
        let (held, _) = classify(event.flags)
        if held {
            guard peekWork == nil, !isPeeking, !anyBarVisible else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.core.isIdle, !self.anyBarVisible else { return }
                self.isPeeking = true
                self.lastActivityAt = Date()
                self.hud.showGuide(
                    title: "⌖ graph",
                    rows: self.actions.graphGuideRows(self.config.graph),
                    footer: "letter to go · space searcher · ⏎ web · ; hints · ' breaths · ? everything · release to dismiss"
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
            GuideRow(key: "␣", label: "searcher"),
            GuideRow(key: "⏎", label: "web bar — links · domains · search"),
            GuideRow(key: ".", label: "menu search — the frontmost app's menus"),
            GuideRow(key: "⇥", label: "windows of the focused app"),
            GuideRow(key: "1…9", label: "jump to window by position"),
            GuideRow(key: "0", label: "the focused window fills the display — ⇧0 beside"),
            GuideRow(key: "O", label: "flip layout orientation"),
            GuideRow(key: ",", label: "scroll mode — j/k · h/l · d/u · gg/G"),
            GuideRow(key: ";", label: "click hints — ⇧; chains · ⇧label right-clicks"),
            GuideRow(key: "Z", label: "undo layout · ⇧Z redo"),
            GuideRow(key: "X", label: "back · ⇧X forward — the attention timeline"),
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
        strip.show(recents: recents, pins: Clipboard.pins(all),
                   thumbnail: { [clipboard] id in clipboard.history.thumbnail(for: id) },
                   query: pasteQuery, selection: pasteSelection)
    }

    /// A short list, drawn where the guide already draws — this is the rare
    /// half of a card's life and does not deserve a surface of its own.
    private func showClipPanel() {
        guard let clip = panelClip else { return }
        var rows = [GuideRow(key: "P", label: clip.isPinned ? "unpin" : "pin"),
                    GuideRow(key: "D", label: "delete this clip")]
        if clip.kind == .image { rows.append(GuideRow(key: "S", label: "save to Downloads")) }
        if let app = clip.sourceAppName { rows.append(GuideRow(key: "X", label: "never save from \(app)")) }
        hud.showGuide(title: "⌂ clip", rows: rows, footer: "esc back to the strip")
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
            if action != .panel { strip.hide() }
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
        renderStrip()
        return true
    }

    func enterHints(sticky: Bool) -> Bool {
        hints.letters = config.hintLetters
        hints.rescanDelay = config.hintRescanDelay
        return hints.enter(sticky: sticky)
    }

    func hintType(_ letter: String, shift: Bool) -> HintStep {
        hints.type(letter, shift: shift)
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
