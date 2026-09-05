import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A clock the test owns.
///
/// Work scheduled through it runs when the test advances time — in
/// order, each item at its own moment, with the main queue drained
/// between steps so the engine's next-turn hops land as well. Nothing
/// here waits on the wall: a minute passes when the test says it does.
final class VirtualClock {
    private(set) var now: Date
    private var queue: [(at: Date, seq: Int, work: DispatchWorkItem)] = []
    private var seq = 0

    init(start: Date = Date()) { now = start }

    var clock: Clock {
        Clock(now: { [unowned self] in self.now },
              after: { [unowned self] delay, work in self.after(delay, work) })
    }

    private func after(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        seq += 1
        queue.append((at: now.addingTimeInterval(delay), seq: seq, work: work))
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            queue.removeAll { $0.work.isCancelled }
            guard let next = queue.min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }),
                  next.at <= target else { break }
            queue.removeAll { $0.seq == next.seq }
            now = next.at
            next.work.perform()
            Stage.pump()
        }
        now = target
        Stage.pump()
    }
}

/// The window world, as a ledger of what it was asked. It moves nothing.
final class FakeActions: EngineActions {
    var summoned: [(target: GraphTarget, beside: Bool)] = []
    var indexJumps: [Int] = []
    var maximized = 0
    var focused: (pid: pid_t, name: String)? = (pid: 1, name: "Ghostty")
    /// What `Actions` does once a summon has landed: tell the coach.
    var coachBoundary: ((String?) -> Void)?

    func focusedAppInfo() -> (pid: pid_t, name: String)? { focused }
    private(set) var joins = 0
    func joinNextPlacement() { joins += 1 }
    func summon(_ target: GraphTarget, beside: Bool, via route: Observations.Route) {
        summoned.append((target: target, beside: beside))
        coachBoundary?(target.label.lowercased())
    }
    func maximizeFocused(beside: Bool) { maximized += 1 }
    func flipOrientation() {}
    func undoLayout() {}
    func redoLayout() {}
    func indexJump(_ digit: Int) { indexJumps.append(digit) }
    func reorderFocused(toDigit digit: Int) {}
    func moveFocusedDisplay(direction: Int, beside: Bool) {}
    func graphGuideRows(_ node: GraphNode) -> [GuideRow] {
        node.children.keys.sorted().map { GuideRow(key: $0.uppercased(), label: $0) }
    }
    func graphCheatRows(_ node: GraphNode, prefix: [String]) -> [GuideRow] { [] }
    func breathGuide(prefix: String) -> [GuideRow] { [] }
    func indexBadgeItems() -> [(index: Int, frame: CGRect)] { [] }
    func breathChain(_ letters: [String]) -> ChainStep { .failed(flash: "✕ no breaths on this stage") }
    func bindBreath(_ letters: [String]) -> ChainStep { .failed(flash: "✕ no breaths on this stage") }
    func deleteBreathStep(_ letters: [String]) -> ChainStep { .failed(flash: "✕ no breaths on this stage") }
    func updateLatestBreath() -> ChainStep { .failed(flash: "✕ no breaths on this stage") }
}

/// A recognizer the test drives by hand: `hear` is a volatile word,
/// `settle` a final one. It never touches a microphone.
final class FakeSpeech: SpeechSession {
    var isAvailable = true
    private(set) var listens = 0
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var stops = 0
    /// How many sessions were opened and never stopped: every listen
    /// must be matched by a stop, or a microphone stays on.
    var openSessions: Int { listens - stops }
    private var onState: ((SpeechState) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var onVolatile: ((String) -> Void)?
    private var onSettled: ((String) -> Void)?
    /// The session before this one, the way a real recognizer's late
    /// results still reach the closures it was given.
    private var previousSettled: ((String) -> Void)?
    /// Whether `stop` settles the standing ghost before completing, the
    /// way a real finalization does.
    var settlesOnStop = true
    /// Hold the listening state back, the way a model download or the
    /// first-run microphone prompt does; `ready()` releases it.
    var slowToListen = false
    /// Hold `stop`'s completion back, the way finalization does; `finish()`
    /// releases it.
    var slowToStop = false
    private var pendingStop: (() -> Void)?
    private var ghost: String?

    func warm(input: String?) {}
    private(set) var lastInput: String?
    func listen(words: [String], input: String?, onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float) -> Void,
                onVolatile: @escaping (String) -> Void, onSettled: @escaping (String) -> Void) {
        listens += 1
        lastInput = input
        previousSettled = self.onSettled
        self.onState = onState; self.onLevel = onLevel
        self.onVolatile = onVolatile; self.onSettled = onSettled
        if !slowToListen { onState(.listening(input: "Stage Microphone")) }
    }
    func ready() { onState?(.listening(input: "Stage Microphone")) }
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func stop(completion: @escaping () -> Void) {
        stops += 1
        if slowToStop {
            // Finalization takes a moment: the ghost settles when it ends.
            pendingStop = completion
            return
        }
        if settlesOnStop, let ghost { onSettled?(ghost) }
        ghost = nil
        completion()
    }
    func finish() {
        if settlesOnStop, let ghost { onSettled?(ghost) }
        ghost = nil
        pendingStop?()
        pendingStop = nil
    }
    func feed(file: URL) -> Bool { false }
    func level(_ value: Float) { onLevel?(value) }
    /// A final from the session before this one, arriving late.
    func settleFromPreviousSession(_ text: String) { previousSettled?(text) }
    func hear(_ text: String) { ghost = text; onVolatile?(text) }
    func settle(_ text: String) { ghost = nil; onSettled?(text) }
}

/// A bar that knows only whether it is up.
final class FakeBar: SearcherSurface, WebBarSurface {
    private(set) var isVisible = false
    var config = Config()
    private(set) var shows = 0
    func show() { isVisible = true; shows += 1 }
    func hide() { isVisible = false }
    func showWindowChooser(pid: pid_t, appName: String) { isVisible = true; shows += 1 }
}

/// The app's surfaces, wired the way the app wires them, on a world that
/// never moves a window.
///
/// The engine, the glass, and the coach are the real classes — the ones
/// that ship — and the wiring between them is `SurfaceWiring`, the same
/// call the app delegate makes. Only the window world and the bars are
/// stand-ins, and every wait runs on a clock the test advances by hand.
/// Keystrokes go in as synthesized `CGEvent`s through the tap's own
/// callback, so a scripted `lode s` walks exactly the path a hardware one
/// does, verdict included.
///
/// The glass panel is real too, which means it briefly appears on screen
/// while these run. That is the point: a test that stubbed the panel
/// would be testing the stub.
final class Stage {
    let clock = VirtualClock()
    let hud: HUD
    let engine: HotkeyEngine
    let coach: CoachController
    let actions = FakeActions()
    let searcher = FakeBar()
    let webBar = FakeBar()
    let commandsBar = FakeBar()
    let speech = FakeSpeech()
    let draft: DraftController
    /// The real clipboard history, on a store in the stage's own directory.
    let clipboard: ClipboardController
    /// Every paste the strip landed: the keystroke, never the system.
    private(set) var stripPastes = 0
    /// Every keystroke the draft posted to the system (⌘V, ⌘A).
    var posted: [(key: String, flags: CGEventFlags)] = []
    /// Every pasteboard write the draft made.
    var pasteboard: [String] = []
    /// What the stage's focused field holds, for the draft to pull.
    var field: DraftController.Field?
    /// Every input chosen on the register line (nil = system default).
    var chosenInputs: [String?] = []
    /// The playback world: which players say they are playing, whether
    /// the route is a shared Bluetooth radio, the output's nominal
    /// rate, and every pause and play the pauser sent. Pausing and
    /// playing move the fake players' state the way the real ones obey.
    var playing: Set<String> = []
    var sharedRoute = false
    private(set) var pausedPlayers: [String] = []
    private(set) var playedPlayers: [String] = []
    private var outputRate: Double = 44_100
    private var rateWatcher: ((Double) -> Void)?
    /// The profile flips: the rate changes and any watcher hears it.
    func setOutputRate(_ rate: Double) {
        outputRate = rate
        rateWatcher?(rate)
    }
    let observations: ObservationStore
    let scroller: ScrollController
    /// Every wheel delta scroll mode posted, caught before the window
    /// server saw it.
    var wheel: [(dx: Int32, dy: Int32)] = []
    /// Every config line the coach asked the app to write.
    private(set) var edits: [ConfigEdit] = []
    private let directory: URL

    /// The graph on this stage: `lode s` is a leaf, `lode b` is a branch
    /// with `x` and `g` under it, `q` is nowhere.
    static func graph() -> GraphNode {
        let graph = GraphNode()
        let slack = GraphNode()
        slack.target = .app("Slack")
        graph.children["s"] = slack
        let brave = GraphNode()
        let work = GraphNode()
        work.target = .app("Brave Browser")
        let google = GraphNode()
        google.target = .app("Google Chrome")
        brave.children["x"] = work
        brave.children["g"] = google
        graph.children["b"] = brave
        return graph
    }

    /// A suggestion with an edit behind it, so an assent has something to
    /// write. `.bind` cues on its app, and the stage stands it with the
    /// cue wait already over.
    static let offer = Recommendation(
        kind: .bind, target: "notes", detail: "bind Notes at lode N",
        secondsPerWeek: 40, probability: 0.9,
        evidence: ["reached 30 times through the launcher"],
        edit: .bindTarget(chain: ["n"], target: "Notes"))

    init(voices: [Voice] = []) {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-stage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observations = ObservationStore(
            file: directory.appendingPathComponent("observations.json"),
            log: EventLog(file: directory.appendingPathComponent("events.jsonl")))

        var config = Config()
        config.graph = Self.graph()

        hud = HUD(clock: clock.clock)
        let model = WindowModel()
        let clipboard = ClipboardController(
            store: ClipboardStore(root: directory.appendingPathComponent("clipboard")))
        // A private board and a counted keystroke: a test that pasted into
        // the general pasteboard and posted ⌘V would type into whatever
        // the machine had focused.
        clipboard.pasteboard = NSPasteboard(name: NSPasteboard.Name("lodestar-stage-\(UUID().uuidString)"))
        self.clipboard = clipboard
        scroller = ScrollController(model: model)
        draft = DraftController(speech: speech, clock: clock.clock)
        engine = HotkeyEngine(config: config, actions: actions, hud: hud,
                              searcher: searcher, webBar: webBar, commandsBar: commandsBar,
                              scroller: scroller,
                              select: SelectController(model: model),
                              clipboard: clipboard, draft: draft, clock: clock.clock)
        engine.observations = observations

        coach = CoachController(clock: clock.clock)
        coach.observations = observations
        coach.enabled = true
        coach.cameraRunning = { false }
        coach.present = { _ in true }
        coach.applyEdit = { [unowned self] edit in
            self.edits.append(edit)
            return nil
        }
        actions.coachBoundary = { [unowned self] app in self.coach.noteBoundary(app: app) }
        scroller.sink = { [unowned self] dx, dy in self.wheel.append((dx, dy)) }
        clipboard.postPaste = { [unowned self] in self.stripPastes += 1 }
        clipboard.flash = { [unowned self] text in self.hud.flash(text) }
        draft.observations = observations
        draft.flash = { [unowned self] text in self.hud.flash(text) }
        draft.frontmost = { [unowned self] in
            self.actions.focused.map { DraftController.Destination(pid: $0.pid, name: $0.name, bundleID: nil) }
        }
        draft.writePasteboard = { [unowned self] text in self.pasteboard.append(text) }
        draft.postKey = { [unowned self] key, flags in self.posted.append((key, flags)) }
        draft.readField = { [unowned self] _, _ in self.field }
        draft.selectAll = { _ in true }
        draft.readPasteboard = { [unowned self] in self.pasteboard.last }
        draft.enumerateInputs = { done in done(["Stage Microphone", "Other Microphone"], "Stage Microphone") }
        draft.chooseInput = { [unowned self] name in self.chosenInputs.append(name) }
        draft.playback = PlaybackPause(world: PlaybackPause.World(
            sharedRoute: { [unowned self] _, done in done(self.sharedRoute) },
            pausePlaying: { [unowned self] done in
                let playing = self.playing.sorted()
                self.pausedPlayers.append(contentsOf: playing)
                self.playing = []
                done(playing)
            },
            resumePlayers: { [unowned self] owed, done in
                let played = owed.filter { !self.playing.contains($0) }
                for id in played {
                    self.playedPlayers.append(id)
                    self.playing.insert(id)
                }
                done(played)
            },
            outputRate: { [unowned self] done in done(self.outputRate) },
            watchRate: { [unowned self] onChange in
                self.rateWatcher = onChange
                return { [weak self] in self?.rateWatcher = nil }
            }), clock: clock.clock)

        SurfaceWiring.wire(engine: engine, hud: hud, coach: coach,
                           voices: voices, clock: clock.clock)
    }

    deinit {
        hud.hide()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The keyboard

    /// Right ⌘ as macOS reports it: the command mask plus the device bit
    /// that says which one.
    private static let lodeFlags: CGEventFlags =
        [.maskCommand, CGEventFlags(rawValue: EngineCore.rightCommandBit)]
    private static let rightCommandKeycode: CGKeyCode = 54

    private var lodeHeld = false

    static func keycode(_ name: String) -> CGKeyCode {
        guard let code = Keys.ansi.first(where: { $0.value == name })?.key else {
            preconditionFailure("no ANSI keycode is named \(name)")
        }
        return CGKeyCode(code)
    }

    /// One event, built the way the tap would see it. Hardware origin by
    /// default — no posting process, HID system state — which is the one
    /// thing the coach checks before trusting a navigation.
    private func event(type: CGEventType, keycode: CGKeyCode, flags: CGEventFlags,
                       posted: Bool) -> CGEvent {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: keycode,
                            keyDown: type != .keyUp)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.eventSourceStateID, value: Coach.hidSystemStateID)
        event.setIntegerValueField(.eventSourceUnixProcessID,
                                   value: posted ? Int64(getpid()) : 0)
        return event
    }

    /// Feed one event through the tap's callback; true when it was
    /// swallowed. The main queue is drained afterwards so a deferred
    /// window effect has landed by the time the test looks.
    @discardableResult
    private func send(_ event: CGEvent) -> Bool {
        let verdict = engine.handle(type: event.type, event: event)
        Self.pump()
        return verdict == nil
    }

    /// The lode key goes down (or, held already, shift joins it).
    func hold(shift: Bool = false, posted: Bool = false) {
        lodeHeld = true
        var flags = Self.lodeFlags
        if shift { flags.insert(.maskShift) }
        send(event(type: .flagsChanged, keycode: Self.rightCommandKeycode,
                   flags: flags, posted: posted))
    }

    /// The lode key comes up.
    func release(posted: Bool = false) {
        lodeHeld = false
        send(event(type: .flagsChanged, keycode: Self.rightCommandKeycode,
                   flags: [], posted: posted))
    }

    /// One key, down then up, under whatever lode is doing. Returns whether
    /// the key-down was swallowed.
    @discardableResult
    func press(_ name: String, shift: Bool = false, posted: Bool = false) -> Bool {
        var flags: CGEventFlags = lodeHeld ? Self.lodeFlags : []
        if shift { flags.insert(.maskShift) }
        let code = Self.keycode(name)
        let swallowed = send(event(type: .keyDown, keycode: code, flags: flags, posted: posted))
        send(event(type: .keyUp, keycode: code, flags: flags, posted: posted))
        return swallowed
    }

    /// A key-down repeating, the way a held key does, with lode already up.
    @discardableResult
    func pressRepeat(_ name: String) -> Bool {
        let code = Self.keycode(name)
        let ev = event(type: .keyDown, keycode: code, flags: [], posted: false)
        ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        return send(ev)
    }

    /// A ⌃ chord with lode up: the field chords in the draft's insert mode.
    @discardableResult
    func controlPress(_ name: String) -> Bool {
        let code = Self.keycode(name)
        let swallowed = send(event(type: .keyDown, keycode: code, flags: .maskControl, posted: false))
        send(event(type: .keyUp, keycode: code, flags: .maskControl, posted: false))
        return swallowed
    }

    /// An ⌥ chord with lode up: ⌥⌫ in the draft.
    @discardableResult
    func optionPress(_ name: String) -> Bool {
        let code = Self.keycode(name)
        let swallowed = send(event(type: .keyDown, keycode: code, flags: .maskAlternate, posted: false))
        send(event(type: .keyUp, keycode: code, flags: .maskAlternate, posted: false))
        return swallowed
    }

    /// A key under any modifiers, lode up: ⌥⌘A addresses a card's
    /// actions mid-search.
    @discardableResult
    func chord(_ name: String, _ flags: CGEventFlags) -> Bool {
        let code = Self.keycode(name)
        let swallowed = send(event(type: .keyDown, keycode: code, flags: flags, posted: false))
        send(event(type: .keyUp, keycode: code, flags: flags, posted: false))
        return swallowed
    }

    /// ⇧⌘V: the strip's own trigger, the one that lives outside lode.
    @discardableResult
    func openStrip() -> Bool { chord("v", [.maskShift, .maskCommand]) }

    // MARK: - The clipboard

    /// A text card in the history, its file on disk before the test goes
    /// on: the door reads the file, and the store writes it off the main
    /// thread. Newest first, as copies are.
    @discardableResult
    func seedClip(_ text: String, app: String? = "Example", bundle: String? = "com.example",
                  host: String? = nil, counted: Bool = true) -> Clipboard.Clip {
        let data = Data(text.utf8)
        let id = ClipboardStore.identity(for: data)
        let counts = counted ? Clipboard.counts(of: text) : nil
        clipboard.history.record(id: id, kind: .text,
                                 items: [.init(plain: data, natives: [])],
                                 imageData: nil, preview: Clipboard.preview(of: text),
                                 sourceBundleID: bundle, sourceAppName: app, sourceHost: host,
                                 lines: counts?.lines, characters: counts?.characters)
        clipboard.history.flushIO()
        return clipboard.history.clips.first { $0.id == id }!
    }

    /// The last strip record the store wrote.
    var lastPaste: ObservationEvent? {
        observations.flush()
        return observations.log.recent(days: 30, now: clock.now.addingTimeInterval(1))
            .last { $0.kind == .paste }
    }

    /// A ⌘ chord with lode up — what the draft lets through or takes.
    @discardableResult
    func commandPress(_ name: String) -> Bool {
        let code = Self.keycode(name)
        let swallowed = send(event(type: .keyDown, keycode: code, flags: .maskCommand, posted: false))
        send(event(type: .keyUp, keycode: code, flags: .maskCommand, posted: false))
        return swallowed
    }

    /// A key goes down and stays down — a held direction in scroll mode.
    @discardableResult
    func keyDown(_ name: String, shift: Bool = false) -> Bool {
        var flags: CGEventFlags = lodeHeld ? Self.lodeFlags : []
        if shift { flags.insert(.maskShift) }
        return send(event(type: .keyDown, keycode: Self.keycode(name), flags: flags, posted: false))
    }

    func keyUp(_ name: String, shift: Bool = false) {
        var flags: CGEventFlags = lodeHeld ? Self.lodeFlags : []
        if shift { flags.insert(.maskShift) }
        send(event(type: .keyUp, keycode: Self.keycode(name), flags: flags, posted: false))
    }

    private static let leftShiftKeycode: CGKeyCode = 56

    /// Shift alone goes down or up, lode untouched.
    func shift(_ down: Bool) {
        var flags: CGEventFlags = lodeHeld ? Self.lodeFlags : []
        if down { flags.insert(.maskShift) }
        send(event(type: .flagsChanged, keycode: Self.leftShiftKeycode, flags: flags, posted: false))
    }

    /// Spin the main run loop until `condition` holds or a bounded number
    /// of turns pass — for the real timers a surface owns (scroll's 120Hz
    /// glide) that no virtual clock drives.
    func pump(until condition: () -> Bool, turns: Int = 200) {
        for _ in 0..<turns where !condition() { Self.pump() }
    }

    /// `lode` + key as one gesture: down, letter, up.
    @discardableResult
    func lode(_ name: String, shift: Bool = false, posted: Bool = false) -> Bool {
        hold(shift: shift, posted: posted)
        let swallowed = press(name, shift: shift, posted: posted)
        release(posted: posted)
        return swallowed
    }

    /// Lode down and up with nothing between — shorter than a peek.
    func tapLode(posted: Bool = false) {
        hold(posted: posted)
        clock.advance(by: 0.1)
        release(posted: posted)
    }

    /// The assent gesture: two taps inside the detector's window.
    func doubleTapLode(posted: Bool = false) {
        tapLode(posted: posted)
        clock.advance(by: 0.1)
        tapLode(posted: posted)
    }

    // MARK: - The coach

    /// Put the stage's offer in the slot with its cue wait already over.
    func stand() { coach.stand(Self.offer, since: .distantPast) }

    /// A navigation landed on `app`, exactly as `Actions` would report it.
    func boundary(app: String = "slack") { coach.noteBoundary(app: app) }

    /// Stand the offer, cross a boundary, and let the settle pass, so the
    /// chip is on the glass when the test begins.
    func raiseChip(file: StaticString = #filePath, line: UInt = #line) {
        stand()
        boundary()
        clock.advance(by: Coach.settleSeconds + 0.1)
        XCTAssertEqual(hud.owner, .coach, "the chip should be up", file: file, line: line)
        XCTAssertTrue(coach.chipVisible, "the coach should know it is up", file: file, line: line)
    }

    /// The ledger's line for the stage's offer, once anything has been
    /// written about it.
    /// The last draft record the store wrote, read back off the disk the
    /// way the analysis would read it.
    var lastDraft: ObservationEvent? {
        observations.flush()
        return observations.log.recent(days: 30, now: clock.now.addingTimeInterval(1))
            .last { $0.kind == .draft }
    }

    var eventsFile: URL {
        observations.flush()
        return directory.appendingPathComponent("events.jsonl")
    }

    var ledger: Observations.LedgerEntry? {
        observations.observations.ledger.first {
            $0.id == "\(Self.offer.kind.rawValue):\(Self.offer.target)"
        }
    }

    /// Drain the main queue: the engine hops window work to the next turn.
    static func pump() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
