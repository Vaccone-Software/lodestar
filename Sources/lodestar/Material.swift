import AppKit
import LodestarCore

/// Material (design/04-material.md): matte ceramic, opaque, lit from above.
/// Every surface is one solid colour with a polished rim along its top edge
/// and a hairline around it; depth is a visible side, and it follows role:
/// what you press stands up, a place you put something sinks, the rest is
/// flat. This file holds the numbers and the few things that draw them; the
/// colours are the palette's (design/01-colour.md), resolved in the look of
/// the view that draws them.
extension Ceramic {
    /// How tall a side shows beneath its face, by the size of the thing.
    enum Side {
        /// A key, a button, a popup, a switch's knob.
        static let control: CGFloat = 3
        /// A chosen row, a Keep card.
        static let row: CGFloat = 4
        /// A large key: the peek's numerals.
        static let large: CGFloat = 5
        /// Pressed: the side gives up the rest and the face follows it down.
        static let pressed: CGFloat = 1
    }

    /// The polished rim along a pane's top edge, and the hairline round it.
    enum Edge {
        static let rim: CGFloat = 1.5
        static let line: CGFloat = 0.5
    }

    /// The one shadow a floating pane casts, following its outline: soft by
    /// day, faint at night. `blur` is the contract's number; Core Animation's
    /// radius is half of it.
    enum Shadow {
        static let blur: CGFloat = 24
        static let drop: CGFloat = 8
        static var radius: CGFloat { blur / 2 }
        static let dayShare: CGFloat = 0.14
        static let nightShare: CGFloat = 0.40
        static func share(night: Bool) -> CGFloat { night ? nightShare : dayShare }

        /// The window room a shadow needs on every side: its blur and the
        /// drop, so a window that hosts a pane leaves the margin for it.
        static var reach: CGFloat { blur + drop }
    }

    /// What a thing's depth is: stands up on a side of this height, sinks
    /// into a well, or is flat.
    enum Depth: Equatable {
        case standsUp(side: CGFloat)
        case sinks
        case flat
    }
}

/// A view that says what its depth is, so a test can hold every pressable
/// thing to a side, every well to none, and every flat thing to neither.
protocol CeramicDepth: AnyObject {
    var depth: Ceramic.Depth { get }
    /// The side actually drawn beneath the face, in points; 0 for a well or
    /// a flat thing.
    var drawnSide: CGFloat { get }
}

// MARK: - The colours of the material

extension BarTheme {
    /// A colour of the palette that follows the look of whichever view
    /// draws it: resolved in the view's appearance at the draw, never fixed
    /// when it is made.
    static func dynamic(_ pick: @escaping (Palette.Steps) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in pick(steps(for: appearance)) }
    }

    static func isNight(_ look: Palette.Steps) -> Bool { look == Palette.night }

    /// What a pane is made of.
    static let paneFill = dynamic { $0.pane.color }
    /// A key's face, and the chosen thing's: the look's key step.
    static let faceFill = dynamic { $0.key.color }
    /// The side a face stands on.
    static let sideFill = dynamic { $0.side.color }
    /// A place you put something: the pane one step down, never below the
    /// ground.
    static let wellFill = dynamic { $0.well.color }
    /// The polished rim: clay's key step by day, the ink at 10% by night.
    static let rimFill = dynamic { look in
        isNight(look) ? look.ink.color.withAlphaComponent(Ceramic.nightRimShare) : look.key.color
    }
    /// What the pane's shadow is cast in: clay's quiet ink by day,
    /// espresso's ground by night. Never black.
    static let shadowInk = dynamic { look in isNight(look) ? look.ground.color : look.quietInk.color }
    /// The edge of a key's face by day, where the key step is barely lighter
    /// than the pane it stands on: the same hairline.
    static let faceEdge = dynamic { look in
        isNight(look) ? NSColor.clear : look.ink.color.withAlphaComponent(look.hairlineAlpha)
    }
    /// A lit key's side: the accent darkened toward the palette's darkest
    /// step, as the mark's faces are shaded.
    static var litSideFill: NSColor {
        dynamic { _ in accent.blended(withFraction: 0.44, of: darkest) ?? accent }
    }
    /// A lit key's rim: the accent lifted toward the palette's lightest step.
    static var litRimFill: NSColor {
        dynamic { _ in accent.blended(withFraction: 0.4, of: lightest) ?? accent }
    }

    /// A key's face by what the pointer is doing to it. Under the pointer
    /// it catches a little more light; pressed, a little less. In the night,
    /// and lit, the face catches light (the ink, the lightest step); by day
    /// a key's face is already the lightest step, so it can only darken,
    /// toward its side.
    static func face(lit: Bool, state: Keycaps.CapState) -> NSColor {
        dynamic { look in
            let resting = lit ? accent : look.key.color
            guard state != .resting else { return resting }
            let night = isNight(look)
            let toward: NSColor = night || lit ? (lit ? lightest : look.ink.color) : look.side.color
            let share: CGFloat = state == .pressed ? 0.06 : (night || lit ? 0.12 : 0.05)
            return resting.blended(withFraction: share, of: toward) ?? resting
        }
    }
}

extension Ceramic {
    /// A standing face drawn in a draw pass, in the look it is drawn in: a
    /// side, the face over it, and the rim clipped to the face's top. For a
    /// view that draws its own highlight (a menu's chosen row).
    static func drawStanding(in rect: NSRect, radius: CGFloat, side: CGFloat) {
        let band = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - side))
        BarTheme.sideFill.setFill()
        NSBezierPath(roundedRect: band, xRadius: radius, yRadius: radius).fill()
        let face = NSRect(x: rect.minX, y: rect.minY + side, width: rect.width, height: max(0, rect.height - side))
        BarTheme.faceFill.setFill()
        NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius).fill()
        BarTheme.rimFill.setFill()
        let path = NSBezierPath(cgPath: rimPath(in: face, radius: radius))
        path.fill()
    }

    /// The ink share of the night's rim.
    static let nightRimShare: CGFloat = 0.10
}

// MARK: - The pane

/// One opaque pane: the look's own step, a 1.5-point rim along the top
/// clipped to the corners, and a 0.5-point edge all round, both drawn above
/// the pane's content so a picture that fills the pane does not cover them.
/// The fill is this view, beneath a surface's content, painted in its own
/// draw pass so it repaints in whichever look it is in; the rim and the edge
/// are `PaneEdge`, laid over the content (see there).
///
/// A pane with a `side` is a card you press (Keep's): its face stands on a
/// visible side, inside the frame.
final class CeramicPane: NSView, CeramicDepth {
    /// What the pane is made of: the pane step, or the key step for the one
    /// the hand is on.
    enum Fill { case pane, key }

    var fill: Fill { didSet { if fill != oldValue { needsDisplay = true } } }
    let cornerRadius: CGFloat
    /// The height of the side beneath the face, 0 for a pane that lies flat.
    var side: CGFloat { didSet { if side != oldValue { needsDisplay = true; edge?.needsDisplay = true } } }
    /// The rim and edge laid over the content.
    private(set) weak var edge: PaneEdge?

    init(cornerRadius: CGFloat, fill: Fill = .pane, side: CGFloat = 0) {
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    var depth: Ceramic.Depth { side > 0 ? .standsUp(side: side) : .flat }
    var drawnSide: CGFloat { side }

    /// The face: the pane less the side beneath it.
    var face: NSRect { NSRect(x: 0, y: side, width: bounds.width, height: max(0, bounds.height - side)) }
    var faceRadius: CGFloat { BarTheme.radius(cornerRadius, height: face.height) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The pane's fill and its side, in this view's look.
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if side > 0 {
            BarTheme.sideFill.setFill()
            let band = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - side))
            let radius = BarTheme.radius(cornerRadius, height: band.height)
            NSBezierPath(roundedRect: band, xRadius: radius, yRadius: radius).fill()
        }
        (fill == .key ? BarTheme.faceFill : BarTheme.paneFill).setFill()
        NSBezierPath(roundedRect: face, xRadius: faceRadius, yRadius: faceRadius).fill()
    }

    fileprivate func attach(_ edge: PaneEdge) { self.edge = edge }
}

/// The pane's rim and edge, over everything the surface lays inside it: a
/// view that fills the pane's frame, takes no pointer, and draws the polished
/// rim (1.5 points along the top, clipped to the corners, so it thins into the
/// curve) and the hairline (0.5 point all round) in its own draw pass, in its
/// own look. It stands above its siblings by position in the compositor.
final class PaneEdge: NSView {
    private weak var pane: CeramicPane?

    init(pane: CeramicPane) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = Ceramic.overContent
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The rim as a path, for the tests.
    var rimPath: CGPath? {
        guard let pane else { return nil }
        return Ceramic.rimPath(in: pane.face, radius: pane.faceRadius)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane, bounds.width > 0, bounds.height > 0 else { return }
        BarTheme.rimFill.setFill()
        NSBezierPath(cgPath: Ceramic.rimPath(in: pane.face, radius: pane.faceRadius)).fill()
        let line = Ceramic.Edge.line
        let radius = max(0, pane.faceRadius - line / 2)
        let edge = NSBezierPath(roundedRect: pane.face.insetBy(dx: line / 2, dy: line / 2),
                                xRadius: radius, yRadius: radius)
        edge.lineWidth = line
        BarTheme.hairline.setStroke()
        edge.stroke()
    }

    /// The colours as this view draws them in its own look, for the tests.
    var rimColor: CGColor { Ceramic.resolved(BarTheme.rimFill, in: self) }
    var edgeColor: CGColor { Ceramic.resolved(BarTheme.hairline, in: self) }
    var edgeWidth: CGFloat { Ceramic.Edge.line }
}

extension CeramicPane {
    /// Lay the pane's rim and edge over its siblings.
    fileprivate func makeEdge() -> PaneEdge {
        let edge = PaneEdge(pane: self)
        attach(edge)
        return edge
    }
}

extension Ceramic {
    /// Above everything a surface lays inside it.
    static let overContent: CGFloat = 100

    /// The rim: a strip of `Edge.rim` along the top of a rounded rectangle,
    /// clipped to its corners, so it thins into the curve where the surface
    /// turns away from the light.
    static func rimPath(in rect: CGRect, radius: CGFloat, flipped: Bool = false) -> CGPath {
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let strip = CGRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - Edge.rim,
                           width: rect.width, height: Edge.rim)
        return shape.intersection(CGPath(rect: strip, transform: nil))
    }

    /// Lay a pane under `root`'s content and its rim and edge over it, both
    /// pinned to every edge.
    @discardableResult
    static func installPane(in root: NSView, cornerRadius: CGFloat, fill: CeramicPane.Fill = .pane,
                            side: CGFloat = 0) -> CeramicPane {
        let pane = CeramicPane(cornerRadius: cornerRadius, fill: fill, side: side)
        root.addSubview(pane, positioned: .below, relativeTo: nil)
        let edge = pane.makeEdge()
        root.addSubview(edge)
        for view in [pane, edge] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        return pane
    }

    /// A surface's rim and edge, kept above whatever was added after them.
    /// The compositor orders layers by position; a view-by-view render
    /// (`cacheDisplay`) draws subviews in order, so a harness that renders
    /// that way brings them to the front first.
    static func frontEdges(in view: NSView) {
        for sub in view.subviews { frontEdges(in: sub) }
        for sub in view.subviews where sub is PaneEdge { view.addSubview(sub, positioned: .above, relativeTo: nil) }
    }
}

// MARK: - The well

/// A place you put something: one step below the pane it sits in, a
/// half-point edge, no side and no inner shadow. Painted in the draw pass,
/// so it follows the look it is in.
class WellView: NSView, CeramicDepth {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = BarTheme.controlRadius) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    var depth: Ceramic.Depth { .sinks }
    var drawnSide: CGFloat { 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = BarTheme.radius(cornerRadius, height: bounds.height)
        BarTheme.wellFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let line = Ceramic.Edge.line
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
                                xRadius: max(0, radius - line / 2), yRadius: max(0, radius - line / 2))
        path.lineWidth = line
        BarTheme.hairline.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Standing up

/// A face on a visible side, inside its frame: what you press. A band of
/// the side colour beneath the face, as tall as the thing's size calls for;
/// pressed, the side falls to one point at once and the face follows it
/// down, which is what it gave up. The face wears the polished rim on its
/// top edge clipped to its corners, and at most a hairline. Laid in the
/// layer of the view that stands, beneath its content.
final class Standing {
    /// The side at rest, by size.
    let rest: CGFloat
    private let sideLayer = CALayer()
    private let faceLayer = CALayer()
    private let rim = CAShapeLayer()
    private let edge = CAShapeLayer()
    private var bounds = CGRect.zero
    private var radius: CGFloat = 0
    private var flipped = false

    /// A row not chosen draws nothing: no face, no side, no rim.
    var hidden = false {
        didSet {
            for layer in [sideLayer, faceLayer, rim, edge] { layer.isHidden = hidden }
            if !hidden { layout() }
        }
    }

    /// Collapsed to a point and the face moved down by the rest.
    var pressed = false { didSet { if pressed != oldValue { layout() } } }
    /// The hairline's width: a half point, and more only where a surface says
    /// it is chosen.
    var edgeWidth = Ceramic.Edge.line { didSet { if edgeWidth != oldValue { layout() } } }

    /// A thing lying flat has no side: its face is the whole of it.
    var flat = false { didSet { if flat != oldValue { layout() } } }

    /// A control that draws its own words in its own layer (a button, a
    /// popup) paints its face and side in its draw pass beneath them, since
    /// a sublayer would cover what the layer itself draws; the rim and the
    /// edge, which hold no words, stay layers over it.
    let drawsBody: Bool
    private var faceSource: NSColor?
    private var sideSource: NSColor?

    init(rest: CGFloat, drawsBody: Bool = false) {
        self.rest = rest
        self.drawsBody = drawsBody
        rim.zPosition = Ceramic.overContent - 1
        edge.zPosition = Ceramic.overContent
        edge.fillColor = nil
        edge.lineWidth = Ceramic.Edge.line
    }

    func install(in layer: CALayer) {
        if !drawsBody {
            layer.insertSublayer(sideLayer, at: 0)
            layer.insertSublayer(faceLayer, at: 1)
        }
        layer.addSublayer(rim)
        layer.addSublayer(edge)
    }

    /// The side showing now.
    var side: CGFloat { flat ? 0 : (pressed ? Ceramic.Side.pressed : rest) }

    /// How far the face's middle is above the frame's middle: what a label
    /// on the face moves by to stay on it.
    var lift: CGFloat { side - (flat ? 0 : rest) / 2 }

    /// The face's frame, in the host's unflipped coordinates.
    var faceFrame: CGRect {
        let height = flat ? bounds.height : max(0, bounds.height - rest)
        return CGRect(x: bounds.minX, y: bounds.minY + side, width: bounds.width, height: height)
    }

    /// The part of the side that shows beneath the face.
    var visibleSide: CGFloat { flat || hidden ? 0 : faceFrame.minY - bounds.minY }

    /// Lay the face and its side on a shape of `radius` filling `bounds`.
    /// `flipped` for a host whose layer counts from the top.
    func fit(_ bounds: CGRect, radius: CGFloat, flipped: Bool = false) {
        self.bounds = bounds
        self.radius = radius
        self.flipped = flipped
        layout()
    }

    private func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let face = faceFrame
        let faceRadius = BarTheme.radius(radius, height: face.height)
        // In a flipped layer the same band is measured from the other end.
        func place(_ rect: CGRect) -> CGRect {
            flipped ? CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        faceLayer.frame = place(face)
        faceLayer.cornerRadius = faceRadius
        let band = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: flat ? 0 : max(0, bounds.height - rest))
        sideLayer.frame = place(band)
        sideLayer.cornerRadius = BarTheme.radius(radius, height: band.height)
        sideLayer.isHidden = flat || hidden
        for layer in [rim, edge] { layer.frame = faceLayer.frame }
        let local = CGRect(origin: .zero, size: face.size)
        let line = edgeWidth
        edge.lineWidth = line
        edge.path = CGPath(roundedRect: local.insetBy(dx: line / 2, dy: line / 2),
                           cornerWidth: max(0, faceRadius - line / 2), cornerHeight: max(0, faceRadius - line / 2),
                           transform: nil)
        rim.path = Ceramic.rimPath(in: local, radius: faceRadius, flipped: flipped)
        CATransaction.commit()
    }

    /// The colours, resolved in the look of `view`: a face, the side
    /// beneath it, the rim, and an optional hairline. Nil is not drawn.
    func paint(in view: NSView, face: NSColor?, side: NSColor?, rim: NSColor?, edge: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceSource = face
        sideSource = side
        faceLayer.backgroundColor = face.map { Ceramic.resolved($0, in: view) }
        sideLayer.backgroundColor = side.map { Ceramic.resolved($0, in: view) }
        self.rim.fillColor = rim.map { Ceramic.resolved($0, in: view) }
        self.edge.strokeColor = edge.map { Ceramic.resolved($0, in: view) }
        CATransaction.commit()
    }

    /// The face and side, drawn in the host's draw pass in its own look.
    func drawBody() {
        guard drawsBody, bounds.width > 0 else { return }
        let face = faceFrame
        func place(_ rect: CGRect) -> CGRect {
            flipped ? CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        if !flat, let sideSource {
            let band = place(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                    height: max(0, bounds.height - rest)))
            let r = BarTheme.radius(radius, height: band.height)
            sideSource.setFill()
            NSBezierPath(roundedRect: band, xRadius: r, yRadius: r).fill()
        }
        if let faceSource {
            let r = BarTheme.radius(radius, height: face.height)
            faceSource.setFill()
            NSBezierPath(roundedRect: place(face), xRadius: r, yRadius: r).fill()
        }
    }

    /// What is drawn, for the tests.
    var faceColor: CGColor? { faceLayer.backgroundColor }
    var sideColor: CGColor? { flat ? nil : sideLayer.backgroundColor }
    var rimColor: CGColor? { rim.fillColor }
    var edgeColor: CGColor? { edge.strokeColor }
}

// MARK: - The shadow

/// The one shadow a floating pane casts, following its outline: a layer
/// that holds a path and casts it, `Shadow.drop` down, `Shadow.blur` soft.
final class PaneShadow {
    let layer = CALayer()

    init() {
        layer.shadowOffset = CGSize(width: 0, height: -Ceramic.Shadow.drop)
        layer.shadowRadius = Ceramic.Shadow.radius
        layer.shadowOpacity = 1
    }

    /// Cast `outline`, in the host's coordinates: the layer takes the
    /// outline's frame and its shadow is the rounded shape within it.
    func cast(outline: CGRect, radius: CGFloat) {
        guard outline.width > 0, outline.height > 0 else { return }
        layer.frame = outline
        layer.cornerRadius = radius
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// In the look of `view`: the ink, at the look's share. The caster is
    /// filled with the pane's own colour, so it is something to draw and its
    /// whole shape lies beneath the pane that stands on it, out of sight.
    func paint(in view: NSView) {
        let night = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = Ceramic.resolved(BarTheme.paneFill, in: view)
        layer.shadowColor = Ceramic.resolved(BarTheme.shadowInk, in: view)
        layer.shadowOpacity = Float(Ceramic.Shadow.share(night: night))
        CATransaction.commit()
    }
}

// MARK: - A field you type into

/// A one-line field that is a well: the pane one step down with a hairline,
/// drawn in the field's own draw pass, its words standing a control's
/// padding inside. Where a room asks for a value, this is the place it goes.
final class WellField: NSTextField, CeramicDepth {
    override class var cellClass: AnyClass? {
        get { WellFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: BarTheme.fieldHeight).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    var depth: Ceramic.Depth { .sinks }
    var drawnSide: CGFloat { 0 }

    override func draw(_ dirtyRect: NSRect) {
        let radius = BarTheme.radius(BarTheme.controlRadius, height: bounds.height)
        BarTheme.wellFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let line = Ceramic.Edge.line
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
                                xRadius: max(0, radius - line / 2), yRadius: max(0, radius - line / 2))
        edge.lineWidth = line
        BarTheme.hairline.setStroke()
        edge.stroke()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Words stand `wordPadding` inside the well, in the middle of its height,
/// drawn and edited alike.
final class WellFieldCell: NSTextFieldCell {
    /// The words' rect: padded at the sides, and a line tall in the middle of
    /// the well's height, which a borderless cell does not do of its own.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = rect.insetBy(dx: BarTheme.wordPadding, dy: 0)
        if let font {
            let line = min(rect.height, ceil(font.ascender - font.descender + font.leading))
            inner.origin.y = rect.minY + ((rect.height - line) / 2).rounded()
            inner.size.height = line
        }
        return inner
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
