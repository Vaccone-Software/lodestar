import AppKit
import CoreGraphics
import LodestarCore

/// Scroll mode's hands: pointer warping, pane cycling, and synthesized
/// pixel-scroll events. The engine owns the mode; this owns the physics.
///
/// Scroll events land on whatever sits under the pointer, so entering the
/// mode always warps to the primary pane's center — the same gesture scrolls
/// the same thing every time. Tab warps between discovered panes.
final class ScrollController {
    private let model: WindowModel
    private var panes: [ScrollAreas.Pane] = []
    private var areaIndex = 0
    private var windowFrame: CGRect = .zero
    private var pendingG = false
    /// Wheel-delta polarity follows the system natural-scrolling preference
    /// (measured empirically: natural ON means positive wheel1 = content
    /// down). Read at entry so a changed preference is picked up.
    private var sign: Int32 = 1
    /// The horizontal axis answers backwards (measured the same way:
    /// natural ON, where positive wheel1 moves the viewport toward the
    /// document's end, positive wheel2 moves it toward the LEFT edge —
    /// the start). One shared sign put h and l in each other's hands.
    private var horizontalSign: Int32 { -sign }

    private(set) var appName = ""
    var step: CGFloat = 60
    var smooth = true
    var speed: CGFloat = 900
    /// Shift's multiplier on a direction key: fixed, not a knob. One
    /// modifier the hand already owns, one meaning, so the pair stays a
    /// gesture rather than a decision.
    static let fastMultiplier: CGFloat = 3
    /// Shift is down. Latched from the key that entered the hold and
    /// updated live by flags-changed, so a shift pressed or released
    /// mid-glide changes the velocity on the next tick.
    private(set) var fast = false

    private var heldKeys: Set<String> = []
    private var lastKeyDown: [String: Date] = [:]
    private var smoothTimer: DispatchSourceTimer?
    private var verticalRemainder: Double = 0
    private var horizontalRemainder: Double = 0

    init(model: WindowModel) {
        self.model = model
    }

    private var discoveryGeneration = 0

    /// Called when async pane discovery lands (for guide refreshes).
    var onPanesDiscovered: (() -> Void)?

    /// The instrument observing itself: a warmup's name and its seconds.
    var latency: ((String, TimeInterval) -> Void)?

    /// Where wheel deltas go when a stage is catching them instead of
    /// the window server. Set, it also stops the pointer warp: a stage
    /// has no pointer to move.
    var sink: ((_ dx: Int32, _ dy: Int32) -> Void)?

    /// Enter immediately — warp to the window center now; pane discovery
    /// runs off the main thread and refines Tab targets when it lands.
    ///
    /// The model being cold is not a refusal. Wheel events land on
    /// whatever sits under the pointer regardless, so on a window the
    /// model has not discovered yet (a big Brave window can take seconds)
    /// the mode enters against the frontmost app, scrolls immediately at
    /// the pointer, and keeps asking the model until the window turns up
    /// — at which point panes and the guide refine. The old behavior
    /// returned false, the engine stayed idle, and the j the hand had
    /// already committed fell through to the graph as "j is not on the
    /// graph": a keystroke landing in the wrong register, over a mode the
    /// user had validly entered. That is the trust bug this closes.
    func enter() -> Bool {
        panes = []
        areaIndex = 0
        pendingG = false
        discoveryGeneration += 1
        let natural = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication
        ) as? Bool ?? true
        sign = natural ? 1 : -1
        if let focused = model.focusedWindow, focused.isAlive {
            appName = focused.appName
            windowFrame = focused.frame
            discoverPanes(of: focused.element, began: Date())
            warpToCurrent()
            return true
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        appName = front.localizedName ?? "…"
        windowFrame = .zero
        retryDiscovery(generation: discoveryGeneration, began: Date(), attempts: 0)
        return true
    }

    /// Ask the model again until the focused window exists, then discover
    /// its panes. The keys never waited: this refines aim, it does not
    /// gate the mode.
    private func retryDiscovery(generation: Int, began: Date, attempts: Int) {
        guard discoveryGeneration == generation, attempts < 16 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.discoveryGeneration == generation else { return }
            guard let focused = self.model.focusedWindow, focused.isAlive else {
                self.retryDiscovery(generation: generation, began: began,
                                    attempts: attempts + 1)
                return
            }
            self.appName = focused.appName
            self.windowFrame = focused.frame
            self.discoverPanes(of: focused.element, began: began)
            self.onPanesDiscovered?()
        }
    }

    private func discoverPanes(of element: AXUIElement, began: Date) {
        let generation = discoveryGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = ScrollAreas.panes(of: element)
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            if found.count > 6 { found = Array(found.prefix(6)) }
            DispatchQueue.main.async {
                guard let self, self.discoveryGeneration == generation else { return }
                self.panes = found
                self.latency?("scroll-panes", Date().timeIntervalSince(began))
                self.onPanesDiscovered?()
            }
        }
    }

    func exit() {
        pendingG = false
        discoveryGeneration += 1 // invalidate in-flight discovery and retries
        cancelGlide()
        heldKeys.removeAll()
        stopSmoothTimer()
    }

    // MARK: - Smooth scrolling (constant velocity while held, instant stop)

    /// A direction key went down (repeats included; the set makes them
    /// no-ops). Smooth off falls back to one step per event — the classic
    /// key-repeat feel.
    func directionKeyDown(_ key: String, fast: Bool = false) {
        cancelGlide()
        self.fast = fast
        guard smooth else {
            let distance = Int32(step * (fast ? Self.fastMultiplier : 1))
            switch key {
            case "j": postVertical(distance)
            case "k": postVertical(-distance)
            case "h": postHorizontal(-distance)
            case "l": postHorizontal(distance)
            default: break
            }
            return
        }
        lastKeyDown[key] = Date()
        heldKeys.insert(key)
        if HotkeyEngine.traceTap { Log.info("smooth: down \(key) held=\(heldKeys.sorted())") }
        startSmoothTimerIfNeeded()
    }

    func directionKeyUp(_ key: String) {
        heldKeys.remove(key)
        if heldKeys.isEmpty { stopSmoothTimer() }
    }

    /// The modifier moved while the mode is on. Only a held glide reads
    /// it; a later key-down brings its own flag.
    func shiftChanged(_ down: Bool) {
        fast = down
    }

    private func startSmoothTimerIfNeeded() {
        guard smoothTimer == nil else { return }
        verticalRemainder = 0
        horizontalRemainder = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Two milliseconds of leeway: invisible at 120Hz, and it lets the
        // kernel coalesce the timer with the tap's own run-loop work
        // instead of contending with it tick by tick.
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.smoothTick() }
        timer.resume()
        smoothTimer = timer
    }

    private func stopSmoothTimer() {
        smoothTimer?.cancel()
        smoothTimer = nil
    }

    private func smoothTick() {
        // Dead-man's guard: if a key-up was lost (tap hiccup), the physical
        // key state goes false while no fresh key-downs arrive — stop
        // rather than scroll forever.
        for key in heldKeys {
            if let code = Keys.codes[key],
               !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)),
               Date().timeIntervalSince(lastKeyDown[key] ?? .distantPast) > 0.8 {
                heldKeys.remove(key)
            }
        }
        guard !heldKeys.isEmpty else {
            stopSmoothTimer()
            return
        }

        let perTick = Double(speed * (fast ? Self.fastMultiplier : 1)) / 120.0
        var vertical: Double = 0
        var horizontal: Double = 0
        if heldKeys.contains("j") { vertical += perTick }
        if heldKeys.contains("k") { vertical -= perTick }
        if heldKeys.contains("l") { horizontal += perTick }
        if heldKeys.contains("h") { horizontal -= perTick }

        verticalRemainder += vertical
        horizontalRemainder += horizontal
        let dy = Int32(verticalRemainder)
        let dx = Int32(horizontalRemainder)
        verticalRemainder -= Double(dy)
        horizontalRemainder -= Double(dx)
        if dy != 0 || dx != 0 {
            if HotkeyEngine.traceTap { Log.info("smooth: tick dy=\(dy) dx=\(dx) held=\(heldKeys.sorted())") }
            post(dx: horizontalSign * dx, dy: sign * dy)
        }
    }

    var paneDescription: String? {
        panes.count > 1 ? "pane \(areaIndex + 1)/\(panes.count)" : nil
    }

    private var currentPaneFrame: CGRect {
        if panes.indices.contains(areaIndex) { return panes[areaIndex].frame }
        if windowFrame.height > 10 { return windowFrame }
        // Cold entry, window still unknown: the screen under the pointer
        // is the honest stand-in, so half-page verbs still mean something.
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            return screen.visibleFrame
        }
        return windowFrame
    }

    // MARK: - Verbs (positive = toward the end of the document / rightward)

    /// d/u move half the pane; under shift, the whole of it.
    func page(down: Bool, fraction: CGFloat) {
        cancelGlide()
        let distance = Int32(currentPaneFrame.height * fraction)
        postVertical(down ? distance : -distance)
    }

    func toEnd(bottom: Bool) {
        // Cancelling stays here: it is a local array and stopping a glide the
        // instant the key lands is the whole point of the key.
        cancelGlide()
        // Setting a scrollbar is an accessibility write into the focused app,
        // and this verb arrives through the event tap — a wedged app would
        // hold every key on the machine for the messaging timeout. The
        // generation is the scroll session's own token: `exit` bumps it, so
        // leaving the mode before this runs cancels it.
        let expected = discoveryGeneration
        OffTap.run { [weak self] in
            guard let self, self.discoveryGeneration == expected else { return }
            // First choice: set the scrollbar's value directly — deterministic,
            // instant, immune to the wheel pipeline entirely. Synthetic wheel
            // deltas pass through acceleration curves, drop-heuristics, and
            // coalescing that make large jumps land unpredictably (measured:
            // -500 scrolled, -2000 was dropped, -8000 page-jumped).
            if self.panes.indices.contains(self.areaIndex),
               ScrollAreas.jumpToEnd(self.panes[self.areaIndex].element, bottom: bottom) {
                return
            }
            // Fallback for panes without a settable scrollbar: a glide of small
            // deltas — safely inside the small-delta regime — spread over time.
            let chunk: Int32 = bottom ? 800 : -800
            for i in 0..<150 {
                let work = DispatchWorkItem { [weak self] in self?.postVertical(chunk) }
                self.glideWork.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.012, execute: work)
            }
        }
    }

    private var glideWork: [DispatchWorkItem] = []

    private func cancelGlide() {
        glideWork.forEach { $0.cancel() }
        glideWork.removeAll()
    }

    /// vim gg: the first tap arms, the second jumps to the top.
    @discardableResult
    func tapG() -> Bool {
        if pendingG {
            pendingG = false
            toEnd(bottom: false)
            return true
        }
        pendingG = true
        return false
    }

    func cancelPendingG() {
        pendingG = false
    }

    func cyclePane() {
        guard panes.count > 1 else { return }
        areaIndex = (areaIndex + 1) % panes.count
        warpToCurrent()
    }

    // MARK: - Physics

    private func warpToCurrent() {
        guard sink == nil else { return }
        let target = currentPaneFrame
        CGWarpMouseCursorPosition(CGPoint(x: target.midX, y: target.midY))
    }

    private func postVertical(_ down: Int32) {
        post(dy: sign * down)
    }

    private func postHorizontal(_ right: Int32) {
        post(dx: horizontalSign * right)
    }

    private func post(dx: Int32 = 0, dy: Int32 = 0) {
        if let sink {
            sink(dx, dy)
            return
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
