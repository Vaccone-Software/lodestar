import AppKit
import LodestarCore

/// The slab (design/11-slab.md): the chosen thing, a face of the other look's
/// ground standing on a side, with everything inside it drawn in the other
/// look. Each look is the other's selection.
///
/// The slab's look is an appearance. A chosen view takes the opposite of its
/// host's (`Slab.inside`), and every colour in it, its words, its keys, its
/// dots, its chips and its rules, resolves in that look when it is drawn, so
/// nothing in it is baked and nothing in it can keep the look around it. The
/// slab's own face is the host look's slab step, which seen from inside is the
/// other look's: `BarTheme.slabFill` asks for it there.
///
/// Eye comfort needs nothing here. A slab in a day window is the day's slab
/// step, which is dark and not dimmed, holding the night's ink, which the
/// night's rule dims (to 80% of its luminance at bedtime, never past 7 : 1);
/// a slab in a night window is the night's slab step, dimmed with the
/// night's bright things, holding clay's inks, which clay's rule deepens as
/// far as its floors take. Each side of the slab keeps its own look's rule at
/// the one level, and the floors are measured on the slab itself (the slab
/// tests do, at evening and at bedtime).
enum Slab {
    /// The side a slab stands on, inside its frame: a row's.
    static let side = Ceramic.Side.row

    static func isNight(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The look inside a slab that stands in `host`'s look: the other one.
    /// The same flip takes a view inside a slab back to the look around it.
    static func inside(_ host: NSAppearance) -> NSAppearance {
        NSAppearance(named: isNight(host) ? .aqua : .darkAqua) ?? host
    }

    /// Whether `view` stands inside a chosen slab.
    static func encloses(_ view: NSView) -> Bool {
        var up = view.superview
        while let ancestor = up {
            if let surface = ancestor as? SlabSurface, surface.isSlab { return true }
            up = ancestor.superview
        }
        return false
    }

    /// Holds a view in the look the other side of its superview's, while it
    /// is active, and follows its superview when that changes look: a slab
    /// in a window the Mac turns from light to dark turns with it. Inactive,
    /// the view takes the look it is in.
    final class Flip {
        private weak var view: NSView?
        private var observation: NSKeyValueObservation?
        private weak var watching: NSView?
        var active: Bool { didSet { if active != oldValue { settle() } } }

        init(_ view: NSView, active: Bool = false) {
            self.view = view
            self.active = active
            if active { settle() }
        }

        /// Set the look again: when the view has moved, or its host's look has.
        func settle() {
            guard let view else { return }
            let host = view.superview
            if watching !== host || (observation == nil) == active {
                observation = nil
                watching = host
                if active {
                    // A view not yet in a hierarchy follows the application's
                    // look, which every window of Lodestar's follows.
                    observation = host.map {
                        $0.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in self?.settle() }
                    } ?? NSApplication.shared.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
                        self?.settle()
                    }
                }
            }
            let wanted: NSAppearance? = active
                ? Slab.inside(host?.effectiveAppearance ?? view.window?.effectiveAppearance
                              ?? NSApplication.shared.effectiveAppearance)
                : nil
            if view.appearance?.name != wanted?.name { view.appearance = wanted }
        }
    }
}

extension NSView {
    /// Words laid out by frame to fit in the look around a slab grow when the
    /// look inside it sets them heavier (the night's weight is a step above
    /// the day's): a single line that was cut to its words' width is given the
    /// room its words now need, from the edge it stands on, and no more than
    /// `padding` and its neighbour allow. Words laid out by constraints are
    /// left to them.
    func remeasureWords(padding: CGFloat) {
        let fields = subviews.compactMap { $0 as? NSTextField }
            .filter { $0.translatesAutoresizingMaskIntoConstraints && $0.maximumNumberOfLines <= 1
                && !($0.cell?.wraps ?? false) && !$0.stringValue.isEmpty }
        func natural(_ field: NSTextField) -> CGFloat? {
            guard let style = field.typeStyle else { return nil }
            // The field's own cell stands the text a few points in from its edges.
            let cell = NSTextFieldCell(textCell: "")
            cell.attributedStringValue = NSAttributedString(
                string: field.stringValue,
                attributes: BarTheme.attributes(style.role, tabular: style.tabular, in: field.effectiveAppearance))
            return ceil(cell.cellSize.width)
        }
        var rightEdge: [NSTextField: CGFloat] = [:]
        for field in fields where field.frame.maxX >= bounds.width - padding - 1 {
            guard let width = natural(field), width > field.frame.width else { continue }
            field.frame = NSRect(x: field.frame.maxX - width, y: field.frame.minY, width: width, height: field.frame.height)
            rightEdge[field] = field.frame.minX
        }
        for field in fields where rightEdge[field] == nil {
            guard let width = natural(field), width > field.frame.width else { continue }
            var limit = bounds.width - padding - field.frame.minX
            for (other, minX) in rightEdge where other.frame.intersects(field.frame.insetBy(dx: -bounds.width, dy: 0)) {
                limit = min(limit, minX - Grid.close - field.frame.minX)
            }
            field.frame.size.width = max(field.frame.width, min(width, limit))
        }
    }
}

/// A view that may be a chosen slab, so what stands inside it can tell.
protocol SlabSurface: AnyObject {
    var isSlab: Bool { get }
}

extension BarTheme {
    /// The slab's face, resolved from inside the slab: the look around it has
    /// the slab step that is the other look's ground, and the slab's own look
    /// is the other one, so this asks the opposite look for it.
    static let slabFill = NSColor(name: "LodestarSlab") { appearance in
        steps(for: Slab.inside(appearance)).slab.color
    }
    /// The side the slab stands on, resolved the same way.
    static let slabSideFill = NSColor(name: "LodestarSlabSide") { appearance in
        steps(for: Slab.inside(appearance)).slabSide.color
    }
}

/// A row that is the slab when it is chosen: the other look's face on a
/// four-point side inside its own frame, its rim and hairline the other
/// look's, and everything the row holds drawn in the other look. The bars'
/// rows share it, so the launcher, Ask and the commands bar choose a row the
/// same way. The row's frame holds the side, and its content is centred on
/// the face, half a side above the frame's middle.
///
/// Choosing is instant: nothing slides or fades. Pressing a chosen row
/// collapses its side to a point and lowers the face and what is on it by
/// what the side gave up.
class SlabRow: NSView, CeramicDepth, SlabSurface {
    static let side = Slab.side
    private let standing = Standing(rest: Slab.side)
    private lazy var flip = Slab.Flip(self)
    private(set) var chosen = false
    private var ready = false
    /// Held down: the side is one point, at once.
    private(set) var pressed = false
    /// Whether the row takes the look inside a slab itself. A step laid behind
    /// a row built by someone else (Settings') leaves it to the row.
    var flipsLook = true { didSet { flip.active = flipsLook && chosen } }
    var isSlab: Bool { chosen }
    /// Where the row's corners are, before a row too short for it becomes
    /// a stadium. A row stands one pane-inset inside its pane, so it
    /// rounds at the pane's radius less that inset and its corners keep an
    /// even gap from the pane's; a row set deeper says its own.
    var radius = BarTheme.paneRowRadius {
        didSet { if radius != oldValue { needsLayout = true } }
    }

    func setupSlab() {
        wantsLayer = true
        layer?.cornerRadius = BarTheme.paneRowRadius
        layer?.masksToBounds = false
        if let layer { standing.install(in: layer) }
        choose(false)
    }

    var depth: Ceramic.Depth { chosen ? .standsUp(side: standing.side) : .flat }
    var drawnSide: CGFloat { chosen ? standing.visibleSide : 0 }
    /// The face as it stands now, in this row's coordinates, for the tests.
    var face: CGRect { standing.faceFrame.offsetBy(dx: 0, dy: standing.lift) }
    var faceColor: CGColor? { standing.faceColor }
    var sideColor: CGColor? { standing.sideColor }
    var rimColor: CGColor? { standing.rimColor }
    var edgeColor: CGColor? { standing.edgeColor }

    /// Choose the row, or let it go: the slab is there at once and gone at
    /// once.
    func choose(_ on: Bool) {
        if on == chosen, ready { return }
        ready = true
        chosen = on
        if !on { pressed = false; standing.pressed = false }
        flip.active = flipsLook && on
        paintSlab()
        refit()
    }

    /// Hold the row down or let it up: only a chosen row is pressed.
    func press(_ down: Bool) {
        guard chosen, down != pressed else { return }
        pressed = down
        standing.pressed = down
        refit()
    }

    override func mouseDown(with event: NSEvent) {
        if chosen { press(true) } else { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if pressed { press(false) } else { super.mouseUp(with: event) }
    }

    override func layout() {
        super.layout()
        refit()
    }

    /// The face and side on the frame, and the content on the face: the
    /// row's layers rise by what the face rose, and the face and side are
    /// laid lower by the same, so they stay where the frame says.
    private func refit() {
        let lift = standing.lift
        layer?.sublayerTransform = CATransform3DMakeTranslation(0, lift, 0)
        let corner = BarTheme.radius(radius, height: bounds.height)
        layer?.cornerRadius = corner
        standing.fit(bounds.offsetBy(dx: 0, dy: -lift), radius: corner)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        flip.settle()
        paintSlab()
        if chosen { remeasureWords(padding: Grid.part) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        flip.settle()
        paintSlab()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintSlab()
        if chosen { remeasureWords(padding: Grid.part) }
    }

    /// The face, the side, the rim and the hairline, in this row's look,
    /// which is the other look while it is chosen.
    private func paintSlab() {
        standing.hidden = !chosen
        standing.paint(in: self, face: BarTheme.slabFill, side: BarTheme.slabSideFill, rim: BarTheme.rimFill,
                       edge: BarTheme.hairline)
    }
}
