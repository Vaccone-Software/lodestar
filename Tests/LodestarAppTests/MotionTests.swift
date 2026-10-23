import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/05-motion.md. Lodestar answers at once: nothing it does often
/// moves, nothing fades, and motion is kept for a live level (the draft's
/// voice meter) and a rare change of state (the switch's knob). This holds
/// the rule in the sources, the two allowed motions to their time and
/// curve, and every surface that used to grow or fade to its end state the
/// moment it is asked.
final class MotionTests: XCTestCase {
    private var frameOverride: NSRect?

    override func setUp() {
        super.setUp()
        frameOverride = ActivePolicy.frameOverride
        ActivePolicy.frameOverride = Stage.screen
        Accessibility.reduceMotion = { false }
    }

    override func tearDown() {
        Accessibility.reset()
        ActivePolicy.frameOverride = frameOverride
        super.tearDown()
    }

    // MARK: - Helpers

    /// Every animation attached to any layer under `view`, named by layer
    /// and key; empty means nothing is moving.
    static func animations(in view: NSView?) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer, _ path: String) {
            for key in layer.animationKeys() ?? [] { found.append("\(path).\(key)") }
            for (index, sub) in (layer.sublayers ?? []).enumerated() { walk(sub, "\(path)/\(index)") }
        }
        func visit(_ view: NSView) {
            if let layer = view.layer { walk(layer, String(describing: type(of: view))) }
            view.subviews.forEach(visit)
        }
        if let view { visit(view) }
        return found
    }

    /// Views under `view` that are drawn at less than full strength: a
    /// fade caught part-way, or one that never finished.
    static func dimmed(in view: NSView?) -> [String] {
        var found: [String] = []
        func visit(_ view: NSView) {
            if !view.isHidden, view.alphaValue < 1 { found.append(String(describing: type(of: view))) }
            view.subviews.forEach(visit)
        }
        if let view { visit(view) }
        return found
    }

    private func controlPoints(_ function: CAMediaTimingFunction?) -> [Float] {
        guard let function else { return [] }
        var out: [Float] = []
        for index in 1...2 {
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            out += point
        }
        return out
    }

    /// The run loop turned for a while: a motion that was going to start
    /// or finish late has had its chance to.
    private func spin(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - The sources (rules 1 and 2)

    /// What would move or fade a surface. `CABasicAnimation` is the one
    /// tool of the two allowed motions and is counted per file below.
    private static let forbidden: [(String, String)] = [
        ("an animator proxy", #"\.animator\(\)"#),
        ("an animation group", #"runAnimationGroup"#),
        ("a context duration", #"NSAnimationContext\.current\.duration\s*+=\s*+(?!0(?:\.0+)?\h*+(?:[\n;}]|\z))"#),
        ("a keyframe, spring, group or transition", #"CAKeyframeAnimation|CASpringAnimation|CAAnimationGroup|CATransition"#),
        ("an old-style animation", #"NSViewAnimation|NSAnimation\b"#),
        ("a transaction's animation", #"setAnimationDuration|CATransaction\.setAnimation"#),
        ("an alpha fade", #"alphaValue\s*+=\s*+(?!0\.45\b)"#),
    ]

    /// Where a basic animation may be made, and how many: the meter's fall
    /// (one per stroke end, in one loop) and the knob's slide.
    private static let basicAnimations = ["DraftPanel.swift": 1, "Ceramic.swift": 1]

    private func offenders(in text: String) throws -> [String] {
        var found: [String] = []
        for (what, pattern) in Self.forbidden {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                found.append("\(what): \((text as NSString).substring(with: match.range))")
            }
        }
        return found
    }

    func testNothingMovesOrFadesOutsideTheMeterAndTheKnob() throws {
        var found: [String] = []
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if MaterialTests.isDebugOnly(raw) { continue }
            let text = DesignDriftTests.code(raw)
            let name = file.lastPathComponent
            for hit in try offenders(in: text) { found.append("\(name): \(hit)") }
            let basics = text.components(separatedBy: "CABasicAnimation(").count - 1
            if basics != Self.basicAnimations[name, default: 0] {
                found.append("\(name): \(basics) basic animations, \(Self.basicAnimations[name, default: 0]) allowed")
            }
        }
        XCTAssertEqual(found, [], "instant by default: only the voice meter's fall and the switch's knob may move")
    }

    func testTheGuardCatchesWhatItNames() throws {
        for sample in ["panel.animator().setFrame(frame, display: true)",
                       "NSAnimationContext.runAnimationGroup({ context in", "NSAnimationContext.current.duration = 0.3",
                       "context.timingFunction = x; view.animator().alphaValue = 1",
                       "let t = CATransition()", "CAKeyframeAnimation(keyPath: \"position\")",
                       "CASpringAnimation(keyPath: \"position\")", "CATransaction.setAnimationDuration(0.35)",
                       "columns.alphaValue = 0", "view.alphaValue = shown"] {
            XCTAssertFalse(try offenders(in: sample).isEmpty, "the guard misses: \(sample)")
        }
        for sample in ["NSAnimationContext.current.duration = 0\n", "NSAnimationContext.current.duration = 0.0;",
                       "CATransaction.setDisableActions(true)", "line.alphaValue = 0.45",
                       "panel.setFrame(frame, display: true)"] {
            XCTAssertEqual(try offenders(in: sample), [], "the guard flags what is allowed: \(sample)")
        }
    }

    // MARK: - The two that move (rule 3, the curve)

    func testTheCurveIsTheOneDecelerationAndNothingSprings() {
        XCTAssertEqual(Motion.curvePoints, [0.25, 0.1, 0.25, 1])
        XCTAssertEqual(controlPoints(Motion.curve), [0.25, 0.1, 0.25, 1])
        XCTAssertEqual(Motion.curveText, "cubic-bezier(0.25, 0.1, 0.25, 1)")
        XCTAssertLessThanOrEqual(Motion.curvePoints[3], 1, "no overshoot")
        XCTAssertEqual(Motion.meterFall, 0.15, accuracy: 1e-9)
        XCTAssertEqual(Motion.knobSlide, 0.12, accuracy: 1e-9)
        XCTAssertEqual(Motion.allowed.count, 2, "a live level and a rare change of state, and nothing else")
        for motion in Motion.allowed {
            XCTAssertLessThanOrEqual(motion.seconds, Motion.longest, "\(motion.what) is never longer than 150 ms")
        }
        XCTAssertEqual(Motion.longest, 0.15, accuracy: 1e-9)
    }

    func testTheMeterFallsOver150msOnTheCurveAndTheEndLengthIsSetFirst() {
        let light = VoiceLight(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        light.show(level: 0.9)
        XCTAssertEqual(light.fallingAnimations.count, 0, "a rising level arrives on the next frame")
        let high = light.length
        light.show(level: 0.2)
        XCTAssertLessThan(light.length, high)
        let falls = light.fallingAnimations
        XCTAssertEqual(Set(falls.compactMap(\.keyPath)), ["strokeStart", "strokeEnd"])
        for fall in falls {
            XCTAssertEqual(fall.duration, 0.15, accuracy: 1e-9)
            XCTAssertEqual(controlPoints(fall.timingFunction), [0.25, 0.1, 0.25, 1])
        }
        // The picture is of getting there: the end is already true.
        let end = falls.first { $0.keyPath == "strokeEnd" }?.toValue as? CGFloat
        XCTAssertEqual(end ?? -1, 0.5 + light.length / 2, accuracy: 0.0001)
        light.show(level: 0.95)
        XCTAssertEqual(light.fallingAnimations.count, 0, "rising again, the fall is dropped and the light follows the voice")
    }

    func testAMeterThatGoesOutDoesNotFall() {
        let light = VoiceLight(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        light.show(level: 0.9)
        light.show(level: nil)
        XCTAssertEqual(light.length, 0)
        XCTAssertEqual(light.fallingAnimations.count, 0, "out is out, at once")
    }

    func testReduceMotionHoldsTheMeterStillAtFullLength() {
        Accessibility.reduceMotion = { true }
        let light = VoiceLight(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        light.show(level: 0.9)
        light.show(level: 0.1)
        XCTAssertEqual(light.length, 1, accuracy: 0.0001, "listening, held whole")
        light.show(.waiting)
        XCTAssertEqual(light.fallingAnimations.count, 0, "nothing moves")
    }

    /// A switch on screen, as the settings window holds one.
    private func hosted() -> (NSWindow, AccentSwitch) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let toggle = AccentSwitch(frame: .zero)
        window.contentView?.addSubview(toggle)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, toggle)
    }

    func testTheKnobSlidesOver120msOnTheCurveAndTheTrackChangesAtOnce() throws {
        let (window, toggle) = hosted()
        let track = try XCTUnwrap(toggle.layer?.sublayers?[0])
        let knob = try XCTUnwrap(toggle.layer?.sublayers?[1])
        let before = track.backgroundColor
        _ = toggle.accessibilityPerformPress()
        let slide = try XCTUnwrap(knob.animation(forKey: "slide") as? CABasicAnimation)
        XCTAssertEqual(slide.duration, 0.12, accuracy: 1e-9)
        XCTAssertEqual(controlPoints(slide.timingFunction), [0.25, 0.1, 0.25, 1])
        XCTAssertFalse(slide is CASpringAnimation, "nothing springs")
        // The end state is set first: the knob's model is already across,
        // and the track already wears the new colour, with nothing under it.
        XCTAssertEqual((slide.toValue as? NSValue)?.pointValue, knob.position)
        XCTAssertNotEqual(track.backgroundColor, before)
        XCTAssertNil(track.animationKeys(), "the track's colour does not cross-fade")
        _ = window
    }

    func testReduceMotionMakesTheKnobJump() throws {
        Accessibility.reduceMotion = { true }
        let (window, toggle) = hosted()
        _ = toggle.accessibilityPerformPress()
        XCTAssertNil(toggle.layer?.sublayers?[1].animationKeys(), "it simply arrives")
        XCTAssertNil(toggle.layer?.sublayers?[0].animationKeys())
        XCTAssertEqual(toggle.state, .on)
        _ = window
    }

    // MARK: - Implicit actions on layers the app owns

    /// A layer of our own animates its properties by itself in a window
    /// unless its actions are off: resizing the views that own one leaves
    /// nothing running.
    func testResizingAViewThatOwnsALayerAnimatesNothing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let light = VoiceLight(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        let sheet = SheetView(radius: 6)
        sheet.frame = NSRect(x: 220, y: 20, width: 80, height: 100)
        window.contentView?.addSubview(light)
        window.contentView?.addSubview(sheet)
        light.setFrameSize(NSSize(width: 300, height: 90))
        sheet.setFrameSize(NSSize(width: 120, height: 140))
        sheet.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(Self.animations(in: window.contentView), [])
    }

    // MARK: - Surfaces take their end state at once (rules 1 and 4)

    /// A bar's keys sheet: the window is at its end frame the moment the
    /// keys are asked for, nothing is left running, and it is where it was
    /// when they go.
    private func holdsAKeysSheetAtOnce(_ make: () -> (panel: () -> NSPanel?, toggle: ([CheatSheet.Section]) -> Void,
                                                        shown: () -> Bool),
                                       sections: [CheatSheet.Section], _ name: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let (panelOf, toggle, shown) = make()
        guard let panel = panelOf() else { return XCTFail("\(name) made no panel", file: file, line: line) }
        panel.orderFrontRegardless()
        // Once round first, so the bar stands where it stands for what it
        // holds (a bar is placed the first time it is laid out).
        toggle(sections)
        toggle(sections)
        let closed = panel.frame
        toggle(sections)
        XCTAssertTrue(shown(), "\(name): the keys are up", file: file, line: line)
        let open = panel.frame
        XCTAssertGreaterThan(open.height, closed.height + 40, "\(name): the glass has already taken room for them",
                             file: file, line: line)
        XCTAssertEqual(Self.animations(in: panel.contentView), [], "\(name): nothing is running", file: file, line: line)
        XCTAssertEqual(Self.dimmed(in: panel.contentView), [], "\(name): nothing is part-way faded in",
                       file: file, line: line)
        spin()
        XCTAssertEqual(panel.frame, open, "\(name): and nothing moves later", file: file, line: line)
        toggle(sections)
        XCTAssertFalse(shown(), "\(name): the keys are gone", file: file, line: line)
        XCTAssertEqual(panel.frame.height, closed.height, accuracy: 0.5, "\(name): the room is given back at once",
                       file: file, line: line)
        spin()
        XCTAssertEqual(panel.frame.height, closed.height, accuracy: 0.5, file: file, line: line)
        panel.orderOut(nil)
    }

    func testTheLaunchersKeysSheetIsInstant() throws {
        let world = GalleryWorld()
        var made: SearcherController?
        var panels: [NSWindow] = []
        holdsAKeysSheetAtOnce({
            panels = GalleryHost.windows { made = SearcherController(appIndex: world.appIndex, actions: world.actions, model: world.model) }
            return ({ panels.first { $0 is KeyablePanel } as? NSPanel },
                    { made?.toggleKeys($0) }, { made?.keysShown ?? false })
        }, sections: HotkeyEngine.launcherSections, "the launcher")
        _ = (made, world)
    }

    func testTheCommandsBarsKeysSheetIsInstant() throws {
        var made: CommandsBarController?
        var panels: [NSWindow] = []
        holdsAKeysSheetAtOnce({
            panels = GalleryHost.windows { made = CommandsBarController() }
            return ({ panels.first { $0 is KeyablePanel } as? NSPanel },
                    { made?.toggleKeys($0) }, { made?.keysShown ?? false })
        }, sections: HotkeyEngine.commandsSections, "the commands bar")
        _ = made
    }

    func testTheWebBarsKeysSheetIsInstant() throws {
        var made: WebBarController?
        var panels: [NSWindow] = []
        holdsAKeysSheetAtOnce({
            panels = GalleryHost.windows { made = WebBarController() }
            return ({ panels.first { $0 is KeyablePanel } as? NSPanel },
                    { made?.toggleKeys($0) }, { made?.keysShown ?? false })
        }, sections: HotkeyEngine.askSections, "the web bar")
        _ = made
    }

    func testABarsKeysAreWholeTheMomentTheyAreBuilt() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        let rows = NSStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)
        let keys = BarKeys()
        keys.install(root: root, below: rows)
        let view = keys.show(HotkeyEngine.askSections)
        XCTAssertEqual(view?.alphaValue, 1)
        XCTAssertEqual(Self.animations(in: root), [])
        keys.hide()?.removeFromSuperview()
        XCTAssertFalse(keys.isShown)
    }

    func testTheKeysSheetRunsItsCompletionAtOnce() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        let view = NSView()
        panel.contentView?.addSubview(view)
        var ran: [String] = []
        let bigger = NSRect(x: 10, y: 10, width: 300, height: 260)
        KeysSheet.open(panel, to: bigger) { ran.append("open") }
        XCTAssertEqual(panel.frame, bigger)
        XCTAssertEqual(ran, ["open"], "the completion has run by the time open returns")
        let smaller = NSRect(x: 10, y: 10, width: 300, height: 100)
        KeysSheet.close(panel, to: smaller, removing: view) { ran.append("close") }
        XCTAssertEqual(panel.frame, smaller)
        XCTAssertNil(view.superview, "the keys are removed, not faded")
        XCTAssertEqual(ran, ["open", "close"])
    }

    func testTheDraftsFoldAndKeysTakeTheirEndFrameAtOnce() {
        let draft = DraftPanel()
        defer { draft.hide() }
        func view(expanded: Bool) -> DraftView {
            var buffer = Draft.Buffer(text: Array(repeating: "The quick brown fox jumps over the lazy dog.", count: 40)
                .joined(separator: " "))
            buffer.setCursor(buffer.count)
            var view = DraftView(buffer: buffer, mode: .insert, speech: SpeechState.listening(input: "Mic"),
                                 destination: ("Ghostty", nil), replacing: false)
            view.editor = Vim.Mode.insert
            view.micOn = true
            view.expanded = expanded
            return view
        }
        draft.show(view(expanded: false))
        let folded = draft.frame
        draft.show(view(expanded: true))
        let open = draft.frame
        XCTAssertGreaterThan(open.height, folded.height)
        XCTAssertEqual(SoftShadow.inset(draft.panel.frame), open, "open, the moment show returns")
        XCTAssertEqual(Self.animations(in: draft.panel.contentView), [])
        spin()
        XCTAssertEqual(SoftShadow.inset(draft.panel.frame), open, "and nothing moves later")
        draft.show(view(expanded: false))
        XCTAssertEqual(SoftShadow.inset(draft.panel.frame), folded, "shut, the moment show returns")
        XCTAssertEqual(draft.frame.height, folded.height, accuracy: 0.5)

        let sections = HotkeyEngine.draftSections(editor: .insert, card: false)
        draft.showKeys(sections)
        XCTAssertGreaterThan(draft.keysFrame.height, 0, "the keys are in place")
        XCTAssertGreaterThan(draft.frame.height, folded.height + 100, "and the glass has taken their room")
        XCTAssertEqual(SoftShadow.inset(draft.panel.frame), draft.frame)
        XCTAssertEqual(Self.animations(in: draft.panel.contentView), [])
        XCTAssertEqual(Self.dimmed(in: draft.panel.contentView), [], "whole, not fading in")
        let withKeys = draft.panel.frame
        spin()
        XCTAssertEqual(draft.panel.frame, withKeys)
        draft.hideKeys()
        XCTAssertEqual(draft.keysFrame, .zero, "gone, not merely invisible")
        XCTAssertEqual(draft.frame.height, folded.height, accuracy: 0.5)
    }

    func testThePillsKeysTakeTheirEndFrameAtOnce() {
        let pill = ModePill()
        defer { pill.hide() }
        pill.show(.init(mode: .scroll, app: "Slack", icon: nil, listening: false, text: nil))
        let row = pill.frame
        pill.toggleKeys(HotkeyEngine.launcherSections)
        XCTAssertTrue(pill.keysShown)
        XCTAssertEqual(pill.frame.size, pill.frameForContent().size, "the glass already stands where the keys put it")
        XCTAssertEqual(pill.frame.midX, pill.frameForContent().midX, accuracy: 1)
        XCTAssertGreaterThan(pill.frame.width, row.width)
        let open = pill.frame
        spin()
        XCTAssertEqual(pill.frame, open, "and nothing moves later")
        pill.hideKeys()
        XCTAssertEqual(pill.frame.size, row.size, "the glass is the row's again at once")
    }

    // MARK: - Motion sheet

    func testTheMotionSheetListsWhatTheCodeCanRun() {
        XCTAssertEqual(Motion.allowed.map(\.what), ["the draft's voice meter", "the switch's knob"])
        XCTAssertEqual(Motion.allowed.map(\.seconds), [Motion.meterFall, Motion.knobSlide])
        XCTAssertFalse(Motion.instant.isEmpty)
    }
}
