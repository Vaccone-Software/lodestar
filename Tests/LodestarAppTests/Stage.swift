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
        scroller = ScrollController(model: model)
        engine = HotkeyEngine(config: config, actions: actions, hud: hud,
                              searcher: searcher, webBar: webBar, commandsBar: commandsBar,
                              scroller: scroller,
                              select: SelectController(model: model),
                              clipboard: clipboard, clock: clock.clock)
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
