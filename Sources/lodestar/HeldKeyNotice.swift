import AppKit
import LodestarCore

/// Secure input left on, drawn as what it took: the `lode` key, quiet
/// because no press of it can arrive, beside the app holding it, with one
/// line saying so. Three objects in a row at the guide's home, each on its
/// own shadow; when secure input ends the holder goes, the key is lit, and
/// the line says the keys are back.
///
/// Its own window and not the shared glass: it stands for as long as the
/// condition does, and nothing the hand does can take it down, since no
/// key arrives while it stands. The pointer does, so a click answers
/// `onClick`, which brings the holder forward.
final class HeldKeyNotice {
    /// Every object in the row is the pill's height, the one height of a
    /// line on the glass. The key is a standard key: the large size is for
    /// figures, and "lode" at that size outgrew its face.
    static let height = BarTheme.pillHeight
    /// Round the key, so it sits centred in its object.
    static let inset = (height - KeySize.standard.height) / 2
    /// Each object's corner is the key's, grown by the inset round it, so
    /// the key sits concentric in its object.
    static let radius = BarTheme.controlRadius + inset
    static let iconSize = height - Grid.close * 2

    private let panel = Ceramic.makePanel(level: .floating, takesKeys: false)
    private let root = NSView()
    private lazy var gate = PointerGate(panel: panel)
    private let clock: Clock
    private var onClick: (() -> Void)?
    private var leave: DispatchWorkItem?

    /// What is drawn now, for the tests: the line, and the key's state.
    private(set) var words: String?
    private(set) var key: Key?
    private(set) var holderShown = false

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

    /// The holder at the back: its icon, the quiet key, the line.
    func show(_ holder: SecureInputNotice.Holder, icon: NSImage?, onClick: @escaping () -> Void) {
        cancelLeave()
        self.onClick = onClick
        let sentence = SecureInputNotice.sentence(holder)
        draw(icon: icon, lit: false, sentence: sentence)
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
        draw(icon: nil, lit: true, sentence: sentence)
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
        holderShown = false
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

    private func draw(icon: NSImage?, lit: Bool, sentence: String) {
        root.subviews.forEach { $0.removeFromSuperview() }
        let margin = SoftShadow.margin
        let height = Self.height
        var x = margin
        var objects: [NSView] = []

        func object(width: CGFloat) -> ObjectSurface {
            let made = SoftShadow.object(radius: Self.radius)
            Ceramic.installPane(in: made, cornerRadius: Self.radius)
            made.frame = NSRect(x: x, y: margin, width: width, height: height)
            x += width + Grid.close
            objects.append(made)
            return made
        }

        holderShown = icon != nil
        if let icon {
            let tile = object(width: height)
            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.frame = NSRect(x: (height - Self.iconSize) / 2, y: (height - Self.iconSize) / 2,
                                 width: Self.iconSize, height: Self.iconSize)
            tile.addSubview(image)
        }

        let cap = Key("lode", state: lit ? .lit : .quiet)
        let well = object(width: cap.width + Self.inset * 2)
        cap.translatesAutoresizingMaskIntoConstraints = true
        cap.frame = NSRect(x: Self.inset, y: Self.inset, width: cap.width, height: KeySize.standard.height)
        well.addSubview(cap)
        key = cap

        let line = BarTheme.label(sentence, role: .body)
        let lineSize = line.fittingSize
        let slip = object(width: ceil(lineSize.width) + Grid.group * 2)
        line.frame = NSRect(x: Grid.group, y: ((height - lineSize.height) / 2).rounded(),
                            width: ceil(lineSize.width), height: lineSize.height)
        slip.addSubview(line)
        words = sentence

        for view in objects {
            root.addSubview(view)
            Ceramic.frontEdges(in: view)
        }
        let width = x - Grid.close - margin
        let visible = ActivePolicy.presentationFrame
        let row = NSRect(x: (visible.midX - width / 2).rounded(), y: visible.minY + ModePill.rise,
                         width: width, height: height)
        panel.setFrame(SoftShadow.outset(row), display: true)
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.orderFrontRegardless()
        gate.update()
    }
}
