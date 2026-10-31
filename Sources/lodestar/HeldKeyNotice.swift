import AppKit
import LodestarCore

/// Secure input left on, drawn as what it took: the `lode` key, quiet
/// because no press of it can arrive, beside one line naming the app that
/// holds it. One surface at the guide's home; when secure input ends the
/// key is lit and the line says the keys are back.
///
/// Its own window and not the shared glass: it stands for as long as the
/// condition does, and nothing the hand does can take it down, since no
/// key arrives while it stands. The pointer does, so a click answers
/// `onClick`, which brings the holder forward.
final class HeldKeyNotice {
    /// The pill's height, the one height of a line on the glass. The key
    /// is a standard key: the large size is for figures, and "lode" at that
    /// size outgrew its face.
    static let height = BarTheme.pillHeight
    /// Round the key, so it sits centred at the surface's start.
    static let inset = (height - KeySize.standard.height) / 2
    /// The surface's corner is the key's, grown by the inset round it, so
    /// the key sits concentric in it.
    static let radius = BarTheme.controlRadius + inset
    static let keyGap = Grid.part

    private let panel = Ceramic.makePanel(level: .floating, takesKeys: false)
    private let root = NSView()
    private lazy var gate = PointerGate(panel: panel)
    private let clock: Clock
    private var onClick: (() -> Void)?
    private var leave: DispatchWorkItem?

    /// What is drawn now, for the tests: the line, and the key's state.
    private(set) var words: String?
    private(set) var key: Key?

    init(clock: Clock = .live) {
        self.clock = clock
        root.wantsLayer = true
        panel.contentView = root
        root.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(click)))
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.button)
    }

    var isUp: Bool { panel.isVisible }
    /// Standing for a holder, as against saying the keys are back.
    var standing: Bool { isUp && onClick != nil }

    /// The holder at the back: the quiet key, and the line naming it.
    func show(_ holder: SecureInputNotice.Holder, onClick: @escaping () -> Void) {
        cancelLeave()
        self.onClick = onClick
        let sentence = SecureInputNotice.sentence(holder)
        draw(lit: false, sentence: sentence)
        root.setAccessibilityLabel(sentence + ". " + SecureInputNotice.way(holder))
        gate.enabled = true
    }

    /// Secure input ended: the key is lit, the line says so, and the row
    /// leaves when that has been read.
    func keysBack() {
        cancelLeave()
        onClick = nil
        gate.enabled = false
        let sentence = SecureInputNotice.keysBack
        draw(lit: true, sentence: sentence)
        root.setAccessibilityLabel(sentence)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        leave = work
        clock.after(Readability.flashSeconds(for: sentence), work)
    }

    func hide() {
        cancelLeave()
        onClick = nil
        gate.enabled = false
        words = nil
        key = nil
        panel.orderOut(nil)
    }

    /// A click on the row while it stands; the tests call it directly.
    @objc func click() {
        guard standing else { return }
        onClick?()
    }

    private func cancelLeave() {
        leave?.cancel()
        leave = nil
    }

    private func draw(lit: Bool, sentence: String) {
        root.subviews.forEach { $0.removeFromSuperview() }
        let height = Self.height
        let surface = SoftShadow.object(radius: Self.radius)
        Ceramic.installPane(in: surface, cornerRadius: Self.radius)

        let cap = Key("lode", state: lit ? .lit : .quiet)
        cap.translatesAutoresizingMaskIntoConstraints = true
        cap.frame = NSRect(x: Self.inset, y: Self.inset, width: cap.width, height: KeySize.standard.height)
        surface.addSubview(cap)
        key = cap
        let x = cap.frame.maxX + Self.keyGap

        let line = BarTheme.label(sentence, role: .body)
        let lineSize = line.fittingSize
        line.frame = NSRect(x: x, y: ((height - lineSize.height) / 2).rounded(),
                            width: ceil(lineSize.width), height: lineSize.height)
        surface.addSubview(line)
        words = sentence

        let width = line.frame.maxX + Grid.group
        surface.frame = NSRect(x: SoftShadow.margin, y: SoftShadow.margin, width: width, height: height)
        root.addSubview(surface)
        Ceramic.frontEdges(in: surface)

        let visible = ActivePolicy.presentationFrame
        let row = NSRect(x: (visible.midX - width / 2).rounded(), y: visible.minY + ModePill.rise,
                         width: width, height: height)
        panel.setFrame(SoftShadow.outset(row), display: true)
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.orderFrontRegardless()
        gate.update()
    }
}
