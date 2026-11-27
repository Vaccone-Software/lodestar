import AppKit
import LodestarCore

/// `probe border`: can a faint outline sit on the focused window using public
/// calls only? It follows the frontmost app's focused window, draws a thin
/// stroke inside its edge (tiles abut, so outside would land on the
/// neighbour), hides the stroke while the window moves and shows it again
/// once the frame has been quiet, and checks the window server's stacking
/// four times a second: is the outline directly above its window, or has
/// something come between them, or has the window risen over it?
///
/// `--level normal` (the default) orders the outline relative to the target
/// window's number, the public `order(_:relativeTo:)`, which is the question;
/// `--level floating` puts it above every normal window, for comparison.
@MainActor
func runBorder(_ args: inout [String]) {
    requireTrust()
    setvbuf(stdout, nil, _IOLBF, 0)
    let seconds = value(of: "--seconds", in: &args).flatMap(Double.init) ?? 60
    let settle = value(of: "--settle-ms", in: &args).flatMap(Double.init).map { $0 / 1000 } ?? 0.12
    let radius = value(of: "--radius", in: &args).flatMap(Double.init).map { CGFloat($0) } ?? 12
    let width = value(of: "--width", in: &args).flatMap(Double.init).map { CGFloat($0) } ?? 2
    let floating = value(of: "--level", in: &args) == "floating"

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let prober = BorderProber(settle: settle, radius: radius, width: width, floating: floating)
    prober.start()
    print("border: following the focused window for \(Int(seconds))s "
        + "(level \(floating ? "floating" : "normal, ordered relative"), settle \(Int(settle * 1000)) ms)")
    print("try: switch apps, click inside the bordered window, drag it, resize it, "
        + "open a dialog or a palette over it, go full screen")
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
        MainActor.assumeIsolated {
            prober.summary()
            exit(0)
        }
    }
    app.run()
}

@MainActor
final class BorderProber {
    let settle: TimeInterval
    let radius: CGFloat
    let width: CGFloat
    let floating: Bool

    let panel: NSPanel
    let shape = CAShapeLayer()
    var observer: AppObserver?
    var observedPid: pid_t?
    var target: (pid: pid_t, element: AXUIElement, id: CGWindowID)?
    var moving = false
    var lastMove = ContinuousClock.now
    var burstStart = ContinuousClock.now
    var burstEvents = 0
    let began = ContinuousClock.now

    // The tallies the summary reports.
    var focusChanges = 0
    var orderChecks = 0
    var directlyAbove = 0
    var coveredBy: [String: Int] = [:]
    var sankBelow = 0
    var sankBelowAfter: [String: Int] = [:]
    var lastEvent = "start"
    var bursts: [(events: Int, seconds: Double)] = []
    var adoptedAt = ContinuousClock.now
    var closeWatchUntil = ContinuousClock.now
    var riseDelays: [Double] = []

    init(settle: TimeInterval, radius: CGFloat, width: CGFloat, floating: Bool) {
        self.settle = settle
        self.radius = radius
        self.width = width
        self.floating = floating
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = floating ? .floating : .normal
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        shape.lineWidth = width
        view.layer?.addSublayer(shape)
        panel.contentView = view
    }

    func stamp() -> String { String(format: "[%6.2fs]", began.secondsElapsed) }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followFrontmost(reason: "app activated") }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOrder() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleIfQuiet()
                if ContinuousClock.now < self.closeWatchUntil { self.checkOrder() }
            }
        }
        followFrontmost(reason: "start")
    }

    // MARK: Following

    func followFrontmost(reason: String) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        lastEvent = reason
        if observedPid != pid {
            observer?.invalidate()
            observedPid = pid
            observer = AppObserver(pid: pid) { [weak self] notification, element in
                MainActor.assumeIsolated { self?.handle(notification, element: element) }
            }
            observer?.watch(kAXFocusedWindowChangedNotification, on: AXUIElementCreateApplication(pid))
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute) else {
            drop(reason: "\(front.localizedName ?? "?") has no focused window")
            return
        }
        adopt(window, pid: pid, reason: reason)
    }

    func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification:
            if let pid = observedPid { adopt(element, pid: pid, reason: "focus changed") }
        case kAXMovedNotification, kAXResizedNotification:
            let now = ContinuousClock.now
            if !moving {
                moving = true
                burstStart = now
                burstEvents = 0
                panel.orderOut(nil)
            }
            burstEvents += 1
            lastMove = now
        case kAXUIElementDestroyedNotification:
            drop(reason: "window closed")
        default:
            break
        }
    }

    func adopt(_ element: AXUIElement, pid: pid_t, reason: String) {
        guard let window = AXWindow(element: element) else {
            drop(reason: "focused element has no window id")
            return
        }
        if let old = target, old.id == window.id {
            place()
            return
        }
        if let old = target {
            for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                observer?.unwatch(name, on: old.element)
            }
        }
        target = (pid, element, window.id)
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
            observer?.watch(name, on: element)
        }
        focusChanges += 1
        lastEvent = reason
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("\(stamp()) FOCUS  id=\(window.id) \(appName) '\(String((window.title ?? "").prefix(40)))' (\(reason))")
        moving = false
        adoptedAt = ContinuousClock.now
        // Watch the stacking closely for half a second: the activation's own
        // raise lands after the focus notice, and this measures when.
        closeWatchUntil = adoptedAt + .milliseconds(500)
        place()
    }

    func drop(reason: String) {
        target = nil
        panel.orderOut(nil)
        print("\(stamp()) NONE   \(reason)")
    }

    func settleIfQuiet() {
        guard moving, lastMove.secondsElapsed >= settle else { return }
        moving = false
        let span = Double((lastMove - burstStart).components.attoseconds) / 1e18 + Double((lastMove - burstStart).components.seconds)
        bursts.append((burstEvents, span))
        print("\(stamp()) SETTLE \(burstEvents) move/resize notices over \(Int(span * 1000)) ms, outline back")
        lastEvent = "settle after move"
        place()
    }

    // MARK: Drawing and ordering

    func place() {
        guard let target, !moving, let frame = AXWindow(element: target.element)?.frame else { return }
        guard let primary = NSScreen.screens.first?.frame else { return }
        // AX frames are top-left global; Cocoa's are bottom-left.
        let cocoa = CGRect(x: frame.minX, y: primary.maxY - frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(cocoa, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = CGRect(origin: .zero, size: frame.size).insetBy(dx: width / 2, dy: width / 2)
        shape.frame = CGRect(origin: .zero, size: frame.size)
        shape.path = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        if floating {
            panel.orderFrontRegardless()
        } else {
            panel.order(.above, relativeTo: Int(target.id))
        }
        checkOrder()
    }

    /// Where the outline stands in the window server's front-to-back list,
    /// relative to its window. Only windows that overlap the target count as
    /// "between": a menu bar extra across the screen does not cover anything.
    func checkOrder() {
        guard let target, !moving, panel.isVisible else { return }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let ours = CGWindowID(panel.windowNumber)
        func id(_ info: [String: Any]) -> CGWindowID? { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        func bounds(_ info: [String: Any]) -> CGRect? {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        guard let panelIndex = list.firstIndex(where: { id($0) == ours }),
              let targetIndex = list.firstIndex(where: { id($0) == target.id }),
              let targetBounds = bounds(list[targetIndex]) else { return }
        orderChecks += 1
        if targetIndex < panelIndex {
            sankBelow += 1
            sankBelowAfter[lastEvent, default: 0] += 1
            let delay = adoptedAt.secondsElapsed
            riseDelays.append(delay)
            print("\(stamp()) BELOW  the window rose over its outline \(Int(delay * 1000)) ms after focus (after: \(lastEvent)); reordering")
            lastEvent = "reorder after sinking"
            if !floating { panel.order(.above, relativeTo: Int(target.id)) }
            return
        }
        let between = list[(panelIndex + 1)..<targetIndex].filter { info in
            guard let b = bounds(info), b.intersects(targetBounds) else { return false }
            return (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        if between.isEmpty {
            directlyAbove += 1
        } else {
            for info in between {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                coveredBy["\(owner) layer \(layer)", default: 0] += 1
            }
        }
        // Windows the outline draws OVER that are not its own window: the
        // floating level's cost, and what ordering relative avoids.
        if floating {
            let over = list[(panelIndex + 1)..<targetIndex].filter { bounds($0)?.intersects(targetBounds) ?? false }
            for info in over {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                coveredBy["(drawn over) \(owner)", default: 0] += 1
            }
        }
    }

    func summary() {
        print("")
        print("--- border summary ---")
        print("focus changes followed       : \(focusChanges)")
        print("stacking checks              : \(orderChecks)")
        print("outline directly over window : \(directlyAbove)")
        print("window rose over the outline : \(sankBelow)")
        for (event, count) in sankBelowAfter.sorted(by: { $0.value > $1.value }) {
            print("    after \(event): \(count)")
        }
        print("something between them       : \(coveredBy.values.reduce(0, +)) checks")
        for (who, count) in coveredBy.sorted(by: { $0.value > $1.value }) {
            print("    \(who): \(count)")
        }
        if !riseDelays.isEmpty {
            let sorted = riseDelays.sorted()
            print("rise after focus, ms         : " + sorted.map { String(Int($0 * 1000)) }.joined(separator: " "))
        }
        if !bursts.isEmpty {
            let events = bursts.map(\.events).reduce(0, +)
            let longest = bursts.map(\.seconds).max() ?? 0
            print("move bursts                  : \(bursts.count) (\(events) notices, longest \(Int(longest * 1000)) ms)")
        }
    }
}
