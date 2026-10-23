import AppKit
import LodestarCore

extension Notification.Name {
    /// The hand pressed a key Lodestar's tap saw. Posted only while a surface
    /// is receded, to bring it back at once.
    static let handKey = Notification.Name("LodestarHandKey")
}

/// Where the hand's last key is written, so a surface that has been left
/// alone can tell it was not: a key pressed anywhere Lodestar listens is
/// attention.
enum Attention {
    private(set) static var lastKey = Date.distantPast

    static func key(at now: Date = Date()) {
        lastKey = now
        if Recess.recededCount > 0 { NotificationCenter.default.post(name: .handKey, object: nil) }
    }
}

/// Receding (design/06-eye-comfort.md): the pill and the meeting's chip stay
/// on screen while the work is elsewhere, and after twenty seconds without
/// attention their ink moves toward their pane, to 7 to 1, and their quiet
/// ink to 4.5 to 1. Attention is a hover, a key, a change of state or the
/// meeting becoming due; it brings them back at once. A lit key never
/// recedes, and with Eye comfort off nothing does. Instant, as the motion
/// contract has it: a change of colour is one repaint, never a fade.
///
/// One clock per surface. It only says whether the surface is receded; the
/// two colours it hands out ask it every time they are drawn, so receding is
/// one redraw when it starts and one when it ends, and the inks themselves
/// come from the palette the theme resolves (`Receding.inks`), at the level
/// in force.
final class Recess {
    /// How many surfaces are receded now, so a key press costs nothing when
    /// none is.
    private(set) static var recededCount = 0

    private(set) var receded = false {
        didSet {
            guard receded != oldValue else { return }
            Recess.recededCount += receded ? 1 : -1
        }
    }
    /// Told after `receded` changes, to draw the surface again.
    var onChange: (() -> Void)?
    /// A surface asking for the hand (a lit countdown) never recedes.
    var mayRecede: () -> Bool = { true }
    /// How long it is left alone before it recedes.
    var idle: TimeInterval = Receding.idleSeconds

    private var timer: Timer?
    private var standing = false
    private var touchedAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        // The switch turning off puts the ink back at once, turning on starts
        // the count for a surface already up, and a key brings it back.
        observers.append(NotificationCenter.default.addObserver(
            forName: .eyeComfortDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.settingsChanged() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .handKey, object: nil, queue: .main
        ) { [weak self] _ in self?.touchIfStanding() })
    }

    deinit {
        timer?.invalidate()
        if receded { Recess.recededCount -= 1 }
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    /// Whether receding is allowed at all: Eye comfort is on, and the Mac has
    /// not been asked for more contrast.
    private var allowed: Bool { EyeComfortState.shared.enabled && !Accessibility.increaseContrast() }

    /// The surface was shown, hovered or changed state: full ink now, and the
    /// count begins again.
    func touch() {
        standing = true
        touchedAt = Date()
        // A pointer moving over the surface touches it a hundred times a
        // second: the count already running reads the time of the last touch
        // when it fires, so only a surface that was quiet starts a new one.
        let wasReceded = receded
        restore()
        if wasReceded || timer == nil { arm(after: idle) }
    }

    private func touchIfStanding() {
        guard standing else { return }
        touch()
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

    private func arm(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = nil
        guard standing, allowed else { return }
        let fire = Timer(timeInterval: max(0.01, seconds), repeats: false) { [weak self] _ in self?.idled() }
        fire.tolerance = min(1, seconds / 10)
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }

    /// Left alone for the whole window: recede, unless the surface is asking
    /// for the hand or a key was pressed meanwhile.
    func idled() {
        timer = nil
        guard standing, allowed, mayRecede(), !receded else { return }
        let last = max(touchedAt, Attention.lastKey)
        let waited = Date().timeIntervalSince(last)
        if waited < idle - 0.001 {
            arm(after: idle - waited)
            return
        }
        receded = true
        onChange?()
    }

    private func settingsChanged() {
        if !allowed {
            timer?.invalidate()
            timer = nil
            restore()
        } else if standing, timer == nil, !receded {
            arm(after: idle)
        }
    }

    // MARK: - The two colours

    /// The ink, in the look of the view that draws it: the palette's ink, or
    /// the receded ink while the surface is quiet. Asked at every draw.
    var ink: NSColor {
        NSColor(name: nil) { [weak self] appearance in
            let look = BarTheme.steps(for: appearance)
            guard let self, self.receded, self.allowed else { return look.ink.color }
            return Receding.inks(of: look).ink.color
        }
    }

    /// The quiet ink, likewise: the ink itself when the Mac has been asked
    /// for more contrast, as the theme's own quiet ink is.
    var quietInk: NSColor {
        NSColor(name: nil) { [weak self] appearance in
            let look = BarTheme.steps(for: appearance)
            if Accessibility.increaseContrast() { return look.ink.color }
            guard let self, self.receded, self.allowed else { return look.quietInk.color }
            return Receding.inks(of: look).quietInk.color
        }
    }
}

/// Watches a surface for the pointer: coming onto it, or moving over it, is
/// using it. Held by the surface (a tracking area's owner is not kept alive
/// by the area).
final class RecessHover: NSObject {
    private let recess: Recess

    init(_ view: NSView, recess: Recess) {
        self.recess = recess
        super.init()
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @objc func mouseEntered(with event: NSEvent) { recess.touch() }
    @objc func mouseMoved(with event: NSEvent) { recess.touch() }
}

extension NSView {
    /// This view and everything in it, drawn again where it stands: for a
    /// colour that is asked for at every draw and has changed.
    func redrawAll() {
        needsDisplay = true
        for sub in subviews { sub.redrawAll() }
    }
}
