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

    private(set) var appName = ""
    var step: CGFloat = 60
    var smooth = true
    var speed: CGFloat = 900

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

    /// Enter immediately — warp to the window center now; pane discovery
    /// runs off the main thread and refines Tab targets when it lands.
    func enter() -> Bool {
        guard let focused = model.focusedWindow, focused.isAlive else { return false }
        appName = focused.appName
        windowFrame = focused.frame
        panes = []
        areaIndex = 0
        pendingG = false
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let element = focused.element
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = ScrollAreas.panes(of: element)
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            if found.count > 6 { found = Array(found.prefix(6)) }
            DispatchQueue.main.async {
                guard let self, self.discoveryGeneration == generation else { return }
                self.panes = found
                self.onPanesDiscovered?()
            }
        }
        let natural = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication
        ) as? Bool ?? true
        sign = natural ? 1 : -1
        warpToCurrent()
        return true
    }

    func exit() {
        pendingG = false
        discoveryGeneration += 1 // invalidate in-flight discovery
        cancelGlide()
        heldKeys.removeAll()
        stopSmoothTimer()
    }

    // MARK: - Smooth scrolling (constant velocity while held, instant stop)

    /// A direction key went down (repeats included; the set makes them
    /// no-ops). Smooth off falls back to one step per event — the classic
    /// key-repeat feel.
    func directionKeyDown(_ key: String) {
        cancelGlide()
        guard smooth else {
            switch key {
            case "j": postVertical(Int32(step))
            case "k": postVertical(-Int32(step))
            case "h": postHorizontal(-Int32(step))
            case "l": postHorizontal(Int32(step))
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

    private func startSmoothTimerIfNeeded() {
        guard smoothTimer == nil else { return }
        verticalRemainder = 0
        horizontalRemainder = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
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

        let perTick = Double(speed) / 120.0
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
            post(dx: sign * dx, dy: sign * dy)
        }
    }

    var paneDescription: String? {
        panes.count > 1 ? "pane \(areaIndex + 1)/\(panes.count)" : nil
    }

    private var currentPaneFrame: CGRect {
        panes.indices.contains(areaIndex) ? panes[areaIndex].frame : windowFrame
    }

    // MARK: - Verbs (positive = toward the end of the document / rightward)

    func halfPage(down: Bool) {
        cancelGlide()
        let half = Int32(currentPaneFrame.height / 2)
        postVertical(down ? half : -half)
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
        let target = currentPaneFrame
        CGWarpMouseCursorPosition(CGPoint(x: target.midX, y: target.midY))
    }

    private func postVertical(_ down: Int32) {
        post(dy: sign * down)
    }

    private func postHorizontal(_ right: Int32) {
        post(dx: sign * right)
    }

    private func post(dx: Int32 = 0, dy: Int32 = 0) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
