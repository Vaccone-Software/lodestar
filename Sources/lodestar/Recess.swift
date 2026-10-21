import AppKit
import LodestarCore

/// Receding (DESIGN, "Eye comfort"): a surface that stays on screen while
/// the work is elsewhere lowers its ink toward its pane once it has been
/// left alone, and returns the instant it is used. One clock per such
/// surface: the pill and the meeting's chip.
///
/// The clock only says whether the surface is receded. The ink is a dynamic
/// colour that asks (`BarTheme.ink(recedingWith:)`), so receding is one
/// repaint at the moment it starts and another at the moment it ends, with
/// no fade, as every change of a surface that is looked at is. It never goes
/// below the floor for text (`Receding`), and it is off whenever Eye comfort
/// is off.
final class RecessClock {
    private(set) var receded = false
    /// Told after `receded` changes, to repaint the surface.
    var onChange: (() -> Void)?
    /// A surface that is asking for the hand (a meeting that is lit) never
    /// recedes.
    var mayRecede: () -> Bool = { true }
    /// How long it is left alone before it recedes.
    var idle: TimeInterval = Receding.idleSeconds

    private var timer: Timer?
    private var standing = false
    private var observer: NSObjectProtocol?

    init() {
        // The switch turning off puts the ink back at once; turning on starts
        // the count for a surface that is already up.
        observer = NotificationCenter.default.addObserver(
            forName: .eyeComfortDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.settingsChanged() }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The surface was used, shown, or changed state: full ink now, and the
    /// count begins again.
    func touch() {
        standing = true
        restore()
        // A pointer moving over the surface touches it a hundred times a
        // second: push the count back rather than making a timer each time.
        if let timer, timer.isValid { timer.fireDate = Date(timeIntervalSinceNow: idle) } else { arm() }
    }

    /// The surface is gone: full ink for the next time it stands, no count.
    func stop() {
        standing = false
        timer?.invalidate()
        timer = nil
        restore()
    }

    private func restore() {
        guard receded else { return }
        receded = false
        onChange?()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard standing, EyeComfortState.shared.enabled else { return }
        let fire = Timer(timeInterval: idle, repeats: false) { [weak self] _ in self?.idled() }
        fire.tolerance = 1
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }

    /// Left alone for the whole window: recede, unless the surface is
    /// asking for the hand.
    func idled() {
        timer = nil
        guard standing, EyeComfortState.shared.enabled, mayRecede(), !receded else { return }
        receded = true
        onChange?()
    }

    private func settingsChanged() {
        if !EyeComfortState.shared.enabled {
            timer?.invalidate()
            timer = nil
            restore()
        } else if standing, timer == nil, !receded {
            arm()
        }
    }
}

/// Watches a surface for the pointer: coming onto it, or moving over it, is
/// using it. Held by the surface (a tracking area's owner is not kept alive
/// by the area).
final class RecessHover: NSObject {
    private let clock: RecessClock

    init(_ view: NSView, clock: RecessClock) {
        self.clock = clock
        super.init()
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @objc func mouseEntered(with event: NSEvent) { clock.touch() }
    @objc func mouseMoved(with event: NSEvent) { clock.touch() }
}
